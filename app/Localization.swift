//
//  Localization.swift
//  HyperVibe
//
//  Lightweight, runtime-switchable localization. The app is built with `swiftc` (see build.sh) and
//  ships no `.lproj` bundle, so NSLocalizedString/.strings is not wired and could not switch live.
//  Instead every user-facing literal is wrapped in `L("English source")`, and a single English→中文
//  table supplies the translation. Missing entries fall back to the English source, so a partially
//  translated string is always readable rather than a raw key.
//
//  Switching language is instant: SwiftUI settings observe `Loc.shared` and re-`.id()` on change;
//  AppKit surfaces (menu bar, HUDs, the status widget) rebuild on `Loc.didChange`.
//

import Foundation
import Combine

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"

    var id: String { rawValue }

    /// Shown in its OWN language so the picker is legible whatever the current UI language is.
    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

final class Loc: ObservableObject {
    static let shared = Loc()
    static let didChange = Notification.Name("com.hypervibe.languageChanged")

    private static let defaultsKey = "app.language"

    /// Default is English. Changing this persists and broadcasts so every surface relocalizes.
    @Published var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            NotificationCenter.default.post(name: Loc.didChange, object: nil)
        }
    }

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let stored = AppLanguage(rawValue: raw) {
            language = stored
        } else {
            language = .english
        }
    }

    /// Whether the user has ever explicitly picked a language. `false` on a fresh install (the key is
    /// absent and `language` fell back to English), which is what triggers the first-run chooser.
    var hasChosenLanguage: Bool {
        UserDefaults.standard.string(forKey: Self.defaultsKey) != nil
    }

    /// Record a deliberate choice. Persists even when the pick equals the current default (English),
    /// so the first-run chooser is never shown twice.
    func choose(_ newLanguage: AppLanguage) {
        if language != newLanguage {
            language = newLanguage            // didSet persists + posts didChange
        } else {
            UserDefaults.standard.set(newLanguage.rawValue, forKey: Self.defaultsKey)
        }
    }

    func string(_ english: String) -> String {
        guard language == .chinese else { return english }
        return Self.zh[english] ?? english
    }

    func format(_ english: String, _ arguments: [CVarArg]) -> String {
        String(format: string(english), arguments: arguments)
    }
}

/// Global shorthand. `L("Quit")` → "Quit" in English, "退出" in Chinese (English if untranslated).
func L(_ english: String) -> String { Loc.shared.string(english) }

/// Formatted variant for strings with interpolation, e.g. `L("Layer %d", ordinal)`. The English
/// source must use printf specifiers (`%d`, `%@`) and the table entry must mirror them.
func L(_ english: String, _ arguments: CVarArg...) -> String {
    Loc.shared.format(english, arguments)
}

extension Loc {
    /// English source → 中文. Keys are the exact English literals passed to `L(...)`.
    /// Grouped by surface. Brand names (siriRemote, Siri Remote, HyperVibe) are intentionally
    /// left untranslated and are not wrapped at their call sites.
    static let zh: [String: String] = [
        // MARK: Menu bar
        "Status: Connected ✓": "状态:已连接 ✓",
        "Status: Disconnected": "状态:未连接",
        "Settings…": "设置…",
        "Quit": "退出",

        // MARK: Status widget & HUD
        "Active App": "当前应用",
        "Current Layer": "当前层",
        "Keep holding": "继续按住",
        "Hold for %@": "按住 · %@",
        "Release to cancel": "松手取消",
        "Release to choose": "松手选择",
        "Cancelled": "已取消",
        "Completed": "已完成",
        "Listening · speak now": "聆听中 · 请说话",
        "Layer active": "层已激活",
        "Connected": "已连接",
        "Disconnected": "已断开",
        "Waiting": "等待中",

        // MARK: Gesture labels
        "Tap + hold · stage 3": "轻点 + 按住 · 第 3 段",
        "Tap + hold · stage 2": "轻点 + 按住 · 第 2 段",
        "Tap + hold": "轻点 + 按住",
        "Long hold · stage 3": "长按 · 第 3 段",
        "Long hold · stage 2": "长按 · 第 2 段",
        "Long hold": "长按",
        "Triple tap": "三击",
        "Double tap": "双击",
        "Tap": "轻点",
        "Swipe": "滑动",
        "Ring": "圆环",
        "Action": "动作",

        // MARK: Layer names
        "Layer %d": "第 %d 层",
        "Layer 1": "第 1 层",

        // MARK: App wheel
        "%@ is not installed": "『%@』未安装",
        "Move in a direction": "移到某个方向",
        "Voice Input": "语音输入",
        "Two-finger tap": "双指轻点",

        // MARK: Action display labels (Action.displayLabel, resolved via ActionVisual)
        "Full Screen": "全屏",
        "Minimise": "最小化",
        "Close Window": "关闭窗口",
        "App Wheel": "应用轮盘",
        "Next Layer": "下一层",
        "Launch": "打开",
        "Play / Pause": "播放 / 暂停",
        "Next": "下一曲",
        "Previous": "上一曲",
        "Volume +": "音量 +",
        "Volume −": "音量 −",
        "Mute": "静音",
        "Click": "点击",
        "Right-click": "右键点击",
        "Move": "移动",
        "Scroll": "滚动",

        // MARK: Settings — language
        "Language": "语言",
        "Interface language": "界面语言",
        "The whole app switches immediately — no relaunch needed.": "整个 App 立即切换,无需重启。",

        // MARK: Settings — Tuning tab (SettingsView)
        "Loading config…": "正在加载配置…",
        "Acceleration Curves": "加速曲线",
        "Pointer and ring share the same curve shape.": "指针与圆环共用同一条曲线形状。",
        "Pointer and ring are tuned independently.": "指针与圆环各自独立调校。",
        "Each graph is a complete editor. Drag either endpoint to set its slow and fast range; drag the middle point to shape the acceleration.": "每张图都是完整的编辑器。拖动任一端点可设定慢速与快速范围;拖动中间点可塑造加速曲线。",
        "Pointer Movement": "指针移动",
        "Finger velocity → pointer gain": "手指速度 → 指针增益",
        "Base speed": "基础速度",
        "Steadiness": "稳定度",
        "Slow-move gain": "慢速增益",
        "Fast-move gain": "快速增益",
        "Slow threshold": "慢速阈值",
        "Fast threshold": "快速阈值",
        "Curve shape": "曲线形状",
        "Find cursor on shake": "晃动寻找光标",
        "Focus app under cursor": "聚焦光标下的应用",
        "Pointer fine tuning": "指针微调",
        "Only these controls affect pointer movement. Changes apply live while you drag the graph or a slider.": "仅这些控件影响指针移动。拖动曲线或滑块时更改会实时生效。",
        "Enable ring scrolling": "启用环形滚动",
        "Ring Scrolling": "环形滚动",
        "Ring rotation → scroll gain": "圆环转动 → 滚动增益",
        "Outer ring only": "仅外环",
        "Start resistance": "起始阻力",
        "Base scroll speed": "基础滚动速度",
        "Smoothness": "平滑度",
        "Slow-scroll gain": "慢速滚动增益",
        "Fast-scroll gain": "快速滚动增益",
        "Reverse direction": "反转方向",
        "Ring fine tuning": "环形微调",
        "Only these controls affect rotation around the outer ring. Pointer movement keeps its own independent curve above.": "仅这些控件影响绕外环的转动。指针移动在上方保留其独立的曲线。",
        "General Settings": "通用设置",
        "Click, button timing, on-screen feedback, startup and device information.": "点击、按钮时序、屏幕反馈、启动与设备信息。",
        "POINTER": "指针",
        "SCROLL": "滚动",
        "slow pointer": "慢速指针",
        "fast pointer": "快速指针",
        "slow scroll": "慢速滚动",
        "fast scroll": "快速滚动",
        "Tuning": "调校",
        "Layout": "布局",
        "Touch & gesture tuning": "触控与手势调校",
        "Battery": "电量",
        "Firmware": "固件",
        "Bluetooth address": "蓝牙地址",
        "Serial": "序列号",
        "Vendor / Product": "厂商 / 产品",
        "in %d · feat %d": "输入 %d · 特性 %d",
        "HID interfaces (%d)": "HID 接口 (%d)",
        "Remote not connected": "遥控器未连接",
        "Device": "设备",
        "Refresh device information": "刷新设备信息",
        "The remote's microphone is not readable on macOS — see %@": "遥控器的麦克风在 macOS 上无法读取 — 参见 %@",
        "Battery and firmware come from the system Bluetooth stack. The microphone is not readable on macOS.": "电量与固件来自系统蓝牙栈。麦克风在 macOS 上无法读取。",
        "Press sensitivity": "按压灵敏度",
        "Move tolerance": "移动容差",
        "Pressing to click freezes the cursor so it doesn't drift. Lower sensitivity freezes more readily; higher move tolerance keeps it from feeling stuck.": "按压点击时会冻结光标以防其漂移。灵敏度越低越容易冻结;移动容差越高越不会感觉卡顿。",
        "Long-press time": "长按时长",
        "Double-tap speed": "双击速度",
        "Spaces Mode timeout": "桌面模式超时",
        "Buttons": "按钮",
        "Long-press time: how long to hold a button before its “.hold” fires. Double-tap speed: the window for a second tap to trigger a “.double” binding instead of a second single press. Spaces Mode timeout: after long-pressing ring-up to arm desktop switching, how long without a left/right switch before it disarms.": "长按时长:按住按钮多久后触发其「.hold」。双击速度:第二次轻点触发「.double」绑定(而非第二次单击)的时间窗口。桌面模式超时:长按环形上键以启用桌面切换后,多久无左/右切换则解除。",
        "Locked": "锁定",
        "Independent": "独立",
        "Pointer and scroll use the same normalised curve shape. Click to edit independently.": "指针与滚动使用相同的归一化曲线形状。点击可独立编辑。",
        "Click to lock both normalised curve shapes. Numeric speed and gain ranges stay independent.": "点击可锁定两条归一化曲线形状。数值速度与增益范围保持独立。",
        "Start at login": "登录时启动",
        "Startup": "启动",
        "Couldn't change it: %@": "无法更改:%@",
        "Runs HyperVibe automatically after you log in. Also listed under System Settings → General → Login Items.": "登录后自动运行 HyperVibe。也会列在「系统设置 → 通用 → 登录项」中。",
        "Always-on status widget": "常驻状态浮窗",
        "Long-press progress HUD": "长按进度 HUD",
        "On-screen Status": "屏幕状态",
        "The compact widget stays above every app, shows the current Layer at rest, and follows a hold until release. The larger progress HUD visualises release-to-select stages. They can be enabled independently.": "紧凑浮窗始终位于所有应用之上,静止时显示当前层,并跟随长按直至松手。较大的进度 HUD 可视化「松手选择」的各阶段。二者可独立启用。",
        "Reset to defaults": "恢复默认",
        "Button, ring, and swipe mappings live in %@": "按钮、圆环与滑动映射保存在 %@",

        // MARK: Settings — Layout tab (LayoutView)
        "APP": "应用",
        "Added to the end of settings.layers and inherited from Global. %d/10 layers used.": "添加到 settings.layers 末尾,并从全局继承。已使用 %d/10 层。",
        "Add…": "添加…",
        "Aluminum Siri Remote (3rd gen). Click an input to edit it.": "铝制 Siri Remote(第 3 代)。点击某个输入即可编辑。",
        "App bundle id (e.g. com.apple.Notes)": "应用 bundle id(例如 com.apple.Notes)",
        "App name (e.g. Safari)": "应用名称(例如 Safari)",
        "App profile": "应用配置",
        "AppleScript source": "AppleScript 源码",
        "Apps & web": "应用与网页",
        "Back": "返回",
        "Cancel": "取消",
        "Choose": "选择",
        "Choose an app — its bundle id is filled in automatically": "选择一个应用 — 会自动填入其 bundle id",
        "Click any input to edit its Tap / Double-tap / Hold actions — changes save to config.jsonc and apply live.": "点击任意输入即可编辑其轻点 / 双击 / 长按操作 — 更改会保存到 config.jsonc 并即时生效。",
        "Colour (e.g. orange or #FF9500)": "颜色(例如 orange 或 #FF9500)",
        "Control Center": "控制中心",
        "Create": "创建",
        "Custom": "自定义",
        "Custom in this app": "此应用自定义",
        "Display name (e.g. Editing)": "显示名称(例如 Editing)",
        "Double-tap": "双击",
        "EDIT": "编辑",
        "Editing": "编辑中",
        "Global": "全局",
        "Global / Inherited": "全局 / 继承",
        "Hold": "长按",
        "Hold ··": "长按 ··",
        "Hold ···": "长按 ···",
        "Inherited": "继承",
        "Internal id (e.g. L3)": "内部 id(例如 L3)",
        "Keys & media": "按键与媒体",
        "LAYOUT": "布局",
        "Layer": "层",
        "Modes & layers": "模式与层",
        "Move · Scroll · Swipe": "移动 · 滚动 · 滑动",
        "Pick an app from the hub. Anything not set for that app falls back to Global, then to the remote's native behavior.": "从应用栏中选择一个应用。未为该应用设置的项会回退到全局,再回退到遥控器的原生行为。",
        "Scripting": "脚本",
        "Sleep / Wake": "睡眠 / 唤醒",
        "System": "系统",
        "System / native": "系统 / 原生",
        "This input is handled natively and isn't remappable here.": "此输入由系统原生处理,无法在此重新映射。",
        "Triple-tap": "三击",
        "What every button does": "每个按钮的功能",
        "cycles settings.layers in order": "按顺序循环 settings.layers",
        "does nothing": "无操作",
        "fires on press AND on release": "按下和松开时都会触发",
        "for %@": "用于 %@",
        "in %@": "在 %@",
        "minimises the frontmost window": "最小化最前面的窗口",
        "opens the radial launcher (settings.appWheel)": "打开轮盘启动器(settings.appWheel)",
        "presses the window's red close button": "点击窗口的红色关闭按钮",
        "shell command": "shell 命令",
        "tap = toggle · hold = momentary": "轻点 = 切换 · 长按 = 临时",
        "toggles the frontmost window": "切换最前面窗口的全屏",
        "uses mode": "使用模式",
        "· layer %@": "· 层 %@",
        "→ what %@ does in %@": "→ %@ 在 %@ 中的功能",
        "Clickpad": "触控板",
        "Gestures": "手势",
        "Ring ↑": "环 ↑",
        "Ring ↑ · hold": "环 ↑ · 长按",
        "Ring ↓": "环 ↓",
        "Ring ←": "环 ←",
        "Ring →": "环 →",
        "Center click": "中央点击",
        "Touch surface": "触摸表面",
        "Siri / voice": "Siri / 语音",
        "TV": "电视",
        "Power": "电源",
        "Swipe ↑": "滑动 ↑",
        "Swipe ↓": "滑动 ↓",
        "Swipe ←": "滑动 ←",
        "Swipe →": "滑动 →",
        "None": "无",
        "Keystroke": "按键",
        "Push to talk": "按住说话",
        "Repeat key": "重复按键",
        "Media": "媒体",
        "Mouse": "鼠标",
        "Brightness": "亮度",
        "Launch app": "打开应用",
        "Open URL": "打开网址",
        "Mode": "模式",
        "Layer cycle": "层循环",
        "Switch space": "切换桌面",

        // MARK: Setup wizard
        "Setup Guide": "设置向导",
        "Control your Mac": "控制你的 Mac",
        "siriRemote moves the pointer and presses keys for you. macOS requires Accessibility permission to allow this.": "siriRemote 会替你移动指针、按下按键。macOS 需要「辅助功能」权限才能允许这些操作。",
        "Without this, clicks and keystrokes won't work.": "没有它,点击和按键将无法工作。",
        "Open Accessibility Settings": "打开辅助功能设置",
        "Read your remote": "读取你的遥控器",
        "To receive button presses and the trackpad from the Siri Remote, macOS requires Input Monitoring permission.": "要接收 Siri Remote 的按键和触控板,macOS 需要「输入监控」权限。",
        "Without this, the remote's buttons and trackpad can't be read.": "没有它,遥控器的按键和触控板将无法读取。",
        "Open Input Monitoring Settings": "打开输入监控设置",
        "Connect your Siri Remote": "连接你的 Siri Remote",
        "Pair the aluminium Siri Remote (3rd gen) over Bluetooth. It will appear here once connected.": "通过蓝牙配对铝制 Siri Remote(第 3 代)。连接后会显示在这里。",
        "Searching…": "搜索中…",
        "Open Bluetooth Settings": "打开蓝牙设置",
        "Start automatically": "自动启动",
        "Launch siriRemote whenever you log in, so your remote just works.": "每次登录时启动 siriRemote,让遥控器开箱即用。",
        "You're all set": "全部就绪",
        "siriRemote is ready. Open Settings any time from the menu bar to customise buttons, gestures and more.": "siriRemote 已准备就绪。随时可从菜单栏打开设置,自定义按钮、手势等。",
        "Tip: the remote's microphone needs an extra one-time setup — see the docs.": "提示:遥控器的麦克风需要一次额外的设置 — 参见文档。",
        "Required": "必需",
        "Granted": "已授权",
        "Not granted yet": "尚未授权",
        "Step %d of %d": "第 %d 步,共 %d 步",
        "Continue": "继续",
        "Done": "完成",
    ]
}
