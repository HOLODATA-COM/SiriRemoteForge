use serde::Deserialize;

#[derive(Deserialize)]
pub struct Target {
    pub pid: u32,
    pub handle: usize,
    pub application: String,
    pub secure: bool,
    pub selection: String,
    pub replaceable: bool,
}

#[cfg(target_os = "macos")]
mod imp {
    use super::Target;
    use std::ffi::{c_char, CStr, CString};
    extern "C" {
        fn vi_capture(selection: bool) -> *mut c_char;
        fn vi_free(value: *mut c_char);
        fn vi_release(handle: usize);
        fn vi_valid(pid: i32, handle: usize) -> bool;
        fn vi_selection_matches(handle: usize, original: *const c_char) -> bool;
        fn vi_replace(handle: usize, original: *const c_char, replacement: *const c_char) -> bool;
        fn vi_trusted(prompt: bool) -> bool;
    }
    pub fn capture(selection: bool) -> Result<Target, String> {
        unsafe {
            let raw = vi_capture(selection);
            if raw.is_null() {
                return Err("无法读取当前应用".into());
            }
            let parsed =
                serde_json::from_slice(CStr::from_ptr(raw).to_bytes()).map_err(|e| e.to_string());
            vi_free(raw);
            parsed
        }
    }
    pub fn valid(t: &Target) -> bool {
        unsafe { vi_valid(t.pid as i32, t.handle) }
    }
    pub fn selection_matches(t: &Target) -> bool {
        let Ok(text) = CString::new(t.selection.as_str()) else {
            return false;
        };
        unsafe { vi_selection_matches(t.handle, text.as_ptr()) }
    }
    pub fn replace(t: &Target, text: &str) -> bool {
        if !t.replaceable || !valid(t) {
            return false;
        }
        let (Ok(original), Ok(replacement)) =
            (CString::new(t.selection.as_str()), CString::new(text))
        else {
            return false;
        };
        unsafe { vi_replace(t.handle, original.as_ptr(), replacement.as_ptr()) }
    }
    pub fn release(t: &Target) {
        unsafe {
            vi_release(t.handle);
        }
    }
    pub fn trusted(prompt: bool) -> bool {
        unsafe { vi_trusted(prompt) }
    }
}

#[cfg(windows)]
mod imp {
    use super::Target;
    use windows::{
        core::{Interface, PWSTR},
        Win32::{
            Foundation::CloseHandle,
            System::{Com::*, Threading::*},
            UI::{Accessibility::*, WindowsAndMessaging::*},
        },
    };
    struct Apartment(bool);
    impl Apartment {
        fn enter() -> Self {
            Self(unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).is_ok() })
        }
    }
    impl Drop for Apartment {
        fn drop(&mut self) {
            if self.0 {
                unsafe {
                    CoUninitialize();
                }
            }
        }
    }
    unsafe fn automation() -> windows::core::Result<IUIAutomation> {
        CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER)
    }
    unsafe fn selected(element: &IUIAutomationElement) -> String {
        let Ok(pattern) =
            element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
        else {
            return String::new();
        };
        let Ok(ranges) = pattern.GetSelection() else {
            return String::new();
        };
        if ranges.Length().unwrap_or(0) != 1 {
            return String::new();
        }
        ranges
            .GetElement(0)
            .and_then(|r| r.GetText(20_000))
            .map(|s| s.to_string())
            .unwrap_or_default()
    }
    unsafe fn application_name(pid: u32) -> String {
        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return format!("windows-pid-{pid}");
        };
        let mut buffer = vec![0u16; 32768];
        let mut len = buffer.len() as u32;
        let result = QueryFullProcessImageNameW(
            process,
            PROCESS_NAME_WIN32,
            PWSTR(buffer.as_mut_ptr()),
            &mut len,
        );
        let _ = CloseHandle(process);
        if result.is_err() {
            return format!("windows-pid-{pid}");
        }
        let path = String::from_utf16_lossy(&buffer[..len as usize]);
        path.rsplit('\\').next().unwrap_or(&path).to_lowercase()
    }
    pub fn capture(selection: bool) -> Result<Target, String> {
        let _apartment = Apartment::enter();
        unsafe {
            let foreground = GetForegroundWindow();
            let mut pid = 0;
            GetWindowThreadProcessId(foreground, Some(&mut pid));
            let ui = automation().map_err(|_| "无法读取 Windows 辅助功能")?;
            let element = ui.GetFocusedElement().map_err(|_| "无法读取当前输入区域")?;
            let secure = element
                .CurrentIsPassword()
                .map(|v| v.as_bool())
                .unwrap_or(true);
            let selected = if selection && !secure {
                selected(&element)
            } else {
                String::new()
            };
            let replaceable = element
                .CurrentControlType()
                .map(|t| t == UIA_EditControlTypeId)
                .unwrap_or(false)
                || element
                    .GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId)
                    .and_then(|v| v.CurrentIsReadOnly())
                    .map(|v| !v.as_bool())
                    .unwrap_or(false);
            // UI Automation elements are marshalled by the UIA service; retain one COM reference
            // across the turn, and compare actual elements rather than just window titles.
            Ok(Target {
                pid,
                handle: element.into_raw() as usize,
                application: application_name(pid),
                secure,
                selection: selected,
                replaceable,
            })
        }
    }
    pub fn valid(t: &Target) -> bool {
        let _apartment = Apartment::enter();
        unsafe {
            let mut pid = 0;
            GetWindowThreadProcessId(GetForegroundWindow(), Some(&mut pid));
            if pid != t.pid {
                return false;
            }
            let Ok(ui) = automation() else {
                return false;
            };
            let Ok(current) = ui.GetFocusedElement() else {
                return false;
            };
            let raw = t.handle as *mut std::ffi::c_void;
            let Some(original) = IUIAutomationElement::from_raw_borrowed(&raw) else {
                return false;
            };
            !current
                .CurrentIsPassword()
                .map(|v| v.as_bool())
                .unwrap_or(true)
                && ui
                    .CompareElements(original, &current)
                    .map(|v| v.as_bool())
                    .unwrap_or(false)
        }
    }
    pub fn selection_matches(t: &Target) -> bool {
        let _apartment = Apartment::enter();
        unsafe {
            let raw = t.handle as *mut std::ffi::c_void;
            IUIAutomationElement::from_raw_borrowed(&raw)
                .is_some_and(|e| selected(e) == t.selection)
        }
    }
    pub fn replace(_t: &Target, _text: &str) -> bool {
        false
    } // Validated selection uses Ctrl-V.
    pub fn release(t: &Target) {
        let _apartment = Apartment::enter();
        unsafe {
            drop(IUIAutomationElement::from_raw(
                t.handle as *mut std::ffi::c_void,
            ));
        }
    }
    pub fn trusted(_prompt: bool) -> bool {
        true
    }
}
#[cfg(not(any(target_os = "macos", windows)))]
compile_error!("VoiceInk currently supports macOS and Windows only");

pub use imp::{capture, trusted};
impl Drop for Target {
    fn drop(&mut self) {
        imp::release(self);
    }
}
pub fn copy(text: &str) -> Result<(), String> {
    arboard::Clipboard::new()
        .and_then(|mut c| c.set_text(text))
        .map_err(|_| "无法写入剪贴板；文字已保留在结果中".into())
}
pub fn deliver(target: &Target, text: &str, auto_insert: bool) -> Result<String, String> {
    copy(text)?;
    if !auto_insert || target.pid == std::process::id() || !imp::valid(target) {
        return Ok("copied".into());
    }
    if !target.selection.is_empty() {
        if !target.replaceable || !imp::selection_matches(target) {
            return Ok("copied".into());
        }
        if imp::replace(target, text) {
            return Ok("replaced".into());
        }
    }
    use enigo::{Direction, Enigo, Key, Keyboard, Settings};
    let mut enigo = Enigo::new(&Settings::default())
        .map_err(|_| "请授予辅助功能权限；文字已复制".to_string())?;
    // Check again after initialization; it may have displayed an OS permission dialog.
    if !imp::valid(target) || (!target.selection.is_empty() && !imp::selection_matches(target)) {
        return Ok("copied".into());
    }
    #[cfg(target_os = "macos")]
    let modifier = Key::Meta;
    #[cfg(windows)]
    let modifier = Key::Control;
    enigo
        .key(modifier, Direction::Press)
        .map_err(|_| "无法发送粘贴；文字已复制")?;
    let result = enigo.key(Key::Unicode('v'), Direction::Click);
    let release = enigo.key(modifier, Direction::Release);
    result
        .and(release)
        .map_err(|_| "无法发送粘贴；文字已复制")?;
    Ok(if target.selection.is_empty() {
        "inserted"
    } else {
        "replaced"
    }
    .into())
}
