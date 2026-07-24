//
//  WindowControl.swift
//  HyperVibe
//
//  Window-state changes on the frontmost window: full screen, minimise.
//
//  NOT by synthesizing the menu shortcut. Ctrl+Cmd+F is the shortcut every app carries for full
//  screen, and it looks like it should work, but a synthesized chord does not take effect — the
//  same wall the Space-switching hotkeys hit. What does work is the Accessibility API: a standard
//  window exposes writable `AXFullScreen` and `AXMinimized` attributes, and setting them performs
//  the real transition, animation included. Cmd+M would probably work where Ctrl+Cmd+F did not,
//  but there is no way to know which menu shortcuts are honoured without testing each one, and the
//  AX route needs no such luck.
//
//  Requires the Accessibility permission the app already needs to synthesize input at all.
//

import AppKit
import ApplicationServices

enum WindowControl {

    /// Toggle the frontmost window in or out of full screen. Logs why it could not, rather than
    /// failing quietly — an unsupported window is a normal outcome worth seeing.
    static func toggle() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            rmDebug("🖥 fullscreen: no frontmost application"); return
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focused: CFTypeRef?
        let got = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused)
        guard got == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            rmDebug("🖥 fullscreen: no focused window for \(app.localizedName ?? "?") (AX \(got.rawValue))")
            return
        }
        let window = raw as! AXUIElement

        // Not every window can go full screen — a panel or a settings sheet has no such attribute.
        var settable: DarwinBoolean = false
        let can = AXUIElementIsAttributeSettable(window, attribute, &settable)
        guard can == .success, settable.boolValue else {
            rmDebug("🖥 fullscreen: \(app.localizedName ?? "?") window does not support it")
            return
        }

        var current: CFTypeRef?
        let isFull = AXUIElementCopyAttributeValue(window, attribute, &current) == .success
            && (current as? Bool ?? false)

        let result = AXUIElementSetAttributeValue(window, attribute, (!isFull) as CFBoolean)
        rmDebug("🖥 fullscreen: \(app.localizedName ?? "?") \(isFull ? "exit" : "enter")"
              + (result == .success ? "" : " FAILED (AX \(result.rawValue))"))
    }

    /// Minimise the frontmost window to the Dock.
    static func minimize() {
        guard let (app, window) = focusedWindow() else { return }
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(window, minimizedAttribute, &settable) == .success,
              settable.boolValue else {
            rmDebug("🖥 minimize: \(app.localizedName ?? "?") window cannot be minimised")
            return
        }
        let result = AXUIElementSetAttributeValue(window, minimizedAttribute, true as CFBoolean)
        rmDebug("🖥 minimize: \(app.localizedName ?? "?")"
              + (result == .success ? "" : " FAILED (AX \(result.rawValue))"))
    }

    /// Close the frontmost WINDOW — literally pressing its red button, not sending Cmd+W.
    ///
    /// The difference matters in anything tabbed: Cmd+W closes the active TAB, while the red button
    /// closes the whole window. Pressing the real control is also the only way to be sure which of
    /// the two you get, since an app is free to bind Cmd+W however it likes.
    static func close() {
        guard let (app, window) = focusedWindow() else { return }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString,
                                            &button) == .success,
              let raw = button, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            rmDebug("🖥 close: \(app.localizedName ?? "?") window has no close button")
            return
        }
        let result = AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString)
        rmDebug("🖥 close: \(app.localizedName ?? "?")"
              + (result == .success ? "" : " FAILED (AX \(result.rawValue))"))
    }

    /// The frontmost app and its focused window, or nil with a reason logged.
    private static func focusedWindow() -> (NSRunningApplication, AXUIElement)? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            rmDebug("🖥 window: no frontmost application"); return nil
        }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        let got = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focused)
        guard got == .success, let raw = focused, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            rmDebug("🖥 window: no focused window for \(app.localizedName ?? "?") (AX \(got.rawValue))")
            return nil
        }
        return (app, (raw as! AXUIElement))
    }

    /// Neither is exposed as a public constant by ApplicationServices; both are documented names.
    private static let attribute = "AXFullScreen" as CFString
    private static let minimizedAttribute = "AXMinimized" as CFString
}
