//
//  SiriRemoteApp.swift
//  HyperVibe
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var statusItem: NSStatusItem!
    private var menuBarManager: MenuBarManager!
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?
    private var cursorHighlighter: CursorHighlighter?
    private var layerHUD: LayerHUD?
    /// Mirror of the tune flag — the shake→highlight path is gated on this (see `applyTune`).
    private var findCursorEnabled = true

    // Config engine (SiriRemoteCore)
    private var controller: Controller?
    private var appWatcher: AppWatcher?
    private var configWatcher: ConfigFileWatcher?

    // Settings UI
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    /// Debounces persisting Tuning-tab slider changes back into config.jsonc.
    private var tunePersistWork: DispatchWorkItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 HyperVibe starting...")

        // Headless self-QC: `--snapshot-layout <path>` renders the Layout settings view to a PNG
        // and exits, without seizing the remote or opening a window.
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-layout"),
           idx + 1 < CommandLine.arguments.count {
            LayoutSnapshot.renderAndExit(to: CommandLine.arguments[idx + 1])
            return
        }

        // Headless visual QC: `--test-highlight` shows the find-my-cursor highlight pinned at the
        // main screen's center for ~4s (so it can be screenshotted), then exits — without seizing
        // the remote, suspending rcd, or wiring up the rest of the app.
        if CommandLine.arguments.contains("--test-highlight") {
            NSApp.setActivationPolicy(.accessory)
            let hl = CursorHighlighter()
            cursorHighlighter = hl
            hl.duration = 5.0   // outlast the 4s window so it stays fully lit for the screenshot
            if let screen = NSScreen.main {
                hl.flash(at: CGPoint(x: screen.frame.midX, y: screen.frame.midY))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { exit(0) }
            return
        }

        // Headless visual QC: `--test-layer-hud` shows the layer HUD (on, then off) so it can be
        // screenshotted, then exits — without seizing the remote or wiring up the rest of the app.
        if CommandLine.arguments.contains("--test-layer-hud") {
            NSApp.setActivationPolicy(.accessory)
            let hud = LayerHUD()
            layerHUD = hud
            hud.showOn("L1")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { hud.showOff("L1") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { exit(0) }
            return
        }

        // Bluetooth AVRCP play/pause signals bypass cghidEventTap and reach com.apple.rcd
        // directly, which launches Music.app. Suspend rcd for this session; restored on exit.
        RCDControl.suspend()

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem else {
            NSApp.terminate(nil)
            return
        }
        statusItem.isVisible = true
        
        // Initialize menu bar manager
        menuBarManager = MenuBarManager(statusItem: statusItem)
        
        // Check accessibility permissions
        checkAccessibilityPermissions()
        
        // Initialize controllers
        let cursorController = CursorController()

        remoteInputHandler = RemoteInputHandler(
            cursorController: cursorController,
            menuBarManager: menuBarManager
        )

        // --- Config engine (SiriRemoteCore): config bindings override native button behavior;
        //     unbound buttons fall through to HyperVibe's native mapping. ---
        let config = ConfigStore.loadConfig()

        // Tuning: config.jsonc's `settings` block is the source of truth — always seed from it (a
        // stale saved tune no longer shadows config edits), and re-seed on every hot-reload below.
        let model = SettingsModel(initial: TuneSettings(seed: config.settings))
        model.onApply = { [weak self] tune in
            self?.applyTune(tune)
            self?.scheduleTunePersist()   // write slider values back into config.jsonc (debounced)
        }
        model.config = config   // publish the live config to the Settings "Layout" tab
        settingsModel = model
        let settingsWin = SettingsWindowController(model: model)
        settingsWindow = settingsWin
        menuBarManager.onOpenSettings = { [weak settingsWin] in settingsWin?.show() }
        // Convenience: `./HyperVibe --settings` pops the window open immediately.
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { settingsWin.show() }
        }

        let engineController = Controller(
            engine: MappingEngine(config: config),
            executor: MacActionExecutor()
        )
        controller = engineController
        remoteInputHandler?.controller = engineController
        appWatcher = AppWatcher { [weak engineController] bundleID in
            rmDebug("🎯 frontmost app → \(bundleID)")
            engineController?.frontmostAppChanged(bundleID: bundleID)
        }
        configWatcher = ConfigFileWatcher(url: ConfigStore.path) { [weak self] in
            let reloaded = ConfigStore.loadConfig()
            // If a sticky layer's mode was deleted/renamed in the edit, clear it — otherwise every
            // key would resolve against a missing layer (→ nil → all bindings dead) with no way to
            // pop it. Do this BEFORE reload so the pop lands on the old engine cleanly.
            if let layer = self?.controller?.currentLayer, reloaded.modes[layer] == nil {
                self?.remoteInputHandler?.clearStickyLayer()
            }
            self?.controller?.reload(config: reloaded)
            // reload() resets the engine to the default mode; re-apply the current frontmost app so
            // per-app bindings (e.g. terminal repeat-Delete) don't silently drop to global until the
            // next app switch. (AppWatcher only fires on activation *changes*.)
            if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                self?.controller?.frontmostAppChanged(bundleID: bid)
            }
            self?.settingsModel?.config = reloaded   // keep the Layout tab in sync on hot-reload
            // Live-tune: re-seed tuning from the config's `settings` so editing config.jsonc updates
            // cursor feel / thresholds immediately. The @Published didSet applies it (→ applyTune)
            // only when the values actually changed, so mapping-only edits don't churn.
            self?.settingsModel?.tune = TuneSettings(seed: reloaded.settings)
            print("♻️ siriRemote config reloaded")
        }
        print("🧩 siriRemote config engine active — \(ConfigStore.path.path)")

        // Start touch handler for trackpad (before remote detection so we can wire the callback)
        touchHandler = TouchHandler(cursorController: cursorController)
        touchHandler?.scrollScale = menuBarManager.scrollSpeed.scale
        touchHandler?.onSwipe = { [weak self] direction in
            // Swipes are config-driven only. An unbound swipe does nothing — no native fallback,
            // so HyperVibe's Claude-Code default swipe keys (e.g. right = Shift+Tab) no longer
            // fire and cause the system beep. Bind swipe.<dir> in the config to use them.
            self?.remoteInputHandler?.noteLayerUsedByOtherInput()   // swipe while holding a layer = use
            let key = "swipe.\(direction.rawValue)"
            if self?.controller?.handle(InputEvent(key: key)) == true {
                print("👆 \(key) (config)")
            }
        }
        touchHandler?.onTwoFingerTap = { [weak self] in
            // Config-driven only: unbound two-finger tap does nothing. Bind tap.two to use it.
            self?.remoteInputHandler?.noteLayerUsedByOtherInput()
            if self?.controller?.handle(InputEvent(key: "tap.two")) == true {
                print("👐 tap.two (config)")
            }
        }
        // Find-my-cursor: a cursor shake flashes a highlight. Gated on the enabled setting
        // (`findCursorEnabled`, kept in sync by applyTune) so it can be toggled live.
        // Layer HUD: show a macOS-style overlay when a sticky layer toggles on/off.
        let hud = LayerHUD()
        layerHUD = hud
        remoteInputHandler?.onLayerToggle = { on, name in
            on ? hud.showOn(name) : hud.showOff(name)
        }

        cursorHighlighter = CursorHighlighter()
        touchHandler?.onShake = { [weak self] in
            guard let self = self, self.findCursorEnabled else { return }
            self.cursorHighlighter?.flash()
        }
        touchHandler?.start()
        applyTune(model.tune)   // touchHandler + remoteInputHandler now exist — push the tuning
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] device in
            DispatchQueue.main.async {
                self?.remoteInputHandler?.setRemoteDevice(device)
                self?.menuBarManager.updateConnectionStatus(connected: device != nil)
                self?.settingsModel?.connected = (device != nil)
            }
        }
        remoteDetector?.startDetection()
        
        // Request Input Monitoring so media key tap works in both CLI and .app
        if #available(macOS 10.15, *) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }
        
        // Start media key interceptor
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType)
        }
        mediaKeyInterceptor?.start()
    }
    
    /// Push cursor-feel settings from config into the touch handler (also called on hot reload).
    /// Push UI tuning values into the running touch handler (initial + on every settings change).
    private func applyTune(_ t: TuneSettings) {
        touchHandler?.cursorSpeed = CGFloat(t.cursorSpeed)
        touchHandler?.cursorDeadzone = CGFloat(t.cursorDeadzone)
        touchHandler?.accelMin = CGFloat(t.accelMin)
        touchHandler?.accelMax = CGFloat(t.accelMax)
        touchHandler?.accelLowSpeed = CGFloat(t.accelLowSpeed)
        touchHandler?.accelHighSpeed = CGFloat(t.accelHighSpeed)
        touchHandler?.clickRiseThreshold = t.clickRiseThreshold
        touchHandler?.pressMoveMax = t.pressMoveMax
        touchHandler?.circularConfig = t.circularConfig
        remoteInputHandler?.holdThreshold = t.holdThreshold
        remoteInputHandler?.holdThreshold2 = t.holdThreshold2
        remoteInputHandler?.holdThreshold3 = t.holdThreshold3
        remoteInputHandler?.doubleTapWindow = t.doubleTapWindow
        remoteInputHandler?.spacesModeWindow = t.spacesModeWindow
        findCursorEnabled = t.findCursorEnabled
    }

    /// Persist Tuning-tab changes back into config.jsonc so config stays the single source of truth
    /// (a stale UserDefaults tune can no longer shadow it, and Layout-tab saves no longer revert
    /// tuning). Debounced — a slider drag fires `onApply` continuously; we only write ~0.4s after the
    /// last change to avoid a file write + engine reload per tick.
    private func scheduleTunePersist() {
        tunePersistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.persistTuneToConfig() }
        tunePersistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func persistTuneToConfig() {
        guard let model = settingsModel, let base = model.config else { return }
        let t = model.tune
        let merged = base.withSettingsUpdated { s in
            s.cursorSpeed = t.cursorSpeed
            s.cursorDeadzone = t.cursorDeadzone
            s.accelMin = t.accelMin
            s.accelMax = t.accelMax
            s.accelLowSpeed = t.accelLowSpeed
            s.accelHighSpeed = t.accelHighSpeed
            s.clickRiseThreshold = t.clickRiseThreshold
            s.pressMoveMax = t.pressMoveMax
            s.holdThreshold = t.holdThreshold
            s.holdThreshold2 = t.holdThreshold2
            s.holdThreshold3 = t.holdThreshold3
            s.doubleTapWindow = t.doubleTapWindow
            s.spacesModeWindow = t.spacesModeWindow
            s.findCursorEnabled = t.findCursorEnabled
            s.circularScroll = t.circularConfig
        }
        // No change (e.g. this fire came from a hot-reload re-seed) → don't churn the file.
        guard merged != base else { return }
        do { try ConfigStore.save(merged) }
        catch { NSLog("[siriRemote] tune persist failed: \(error)") }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Re-opening the app (double-clicking HyperVibe.app while it's already running, or clicking it
    /// in the Dock) opens the Settings window. This is the reliable way to reach the UI when the
    /// menu-bar icon is hidden — e.g. squeezed behind the notch on a crowded menu bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return true
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanup()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    private func cleanup() {
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
        RCDControl.restore()
    }
    
    // MARK: - Media Key Handling

    /// Convert mach_absolute_time() delta to seconds (machine ticks vary; use timebase).
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    private static func machDeltaToSeconds(from start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let now = mach_absolute_time()
        let delta = now >= start ? (now - start) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func handleInterceptedMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType) -> Bool {
        let buttonName: String
        switch keyType {
        case .playPause:  buttonName = "playPause"
        case .next:       buttonName = "nextTrack"
        case .previous:   buttonName = "prevTrack"
        case .volumeUp:   buttonName = "volumeUp"
        case .volumeDown: buttonName = "volumeDown"
        case .mute:       buttonName = "mute"
        }

        // Consume a media key ONLY when it's the remote's own AND the config binds it — the HID
        // path already ran the bound action, so we suppress this duplicate. Unbound remote media
        // keys (e.g. volume, which is left native) pass through so the system does its native thing
        // (change volume, play/pause). Keyboard/other-device media keys (fromRemote=false) also
        // pass through. (true = consume, false = pass through.)
        let fromRemote = RemoteInputHandler.lastProcessedButton == buttonName
            && Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime) < 0.3
        // Bound if ANY variant is mapped — tap, double, or a hold stage. A hold-only binding still
        // means the HID path owns this button, so the native media key must be suppressed too
        // (otherwise every press double-fires: native media key + our hold action on long-press).
        let base = "button.\(buttonName)"
        let bound = [base, base + ".double", base + ".hold", base + ".hold2", base + ".hold3"]
            .contains { controller?.hasBinding(for: $0) ?? false }
        return fromRemote && bound
    }
    
    // MARK: - Permissions
    
    private func checkAccessibilityPermissions() {
        // macOS will show its own prompt when needed
        // No need for redundant custom alert
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Suspends `com.apple.rcd` (Remote Control Daemon) for the user's GUI launchd domain while
/// HyperVibe is running. rcd is what reacts to Bluetooth AVRCP play signals by launching
/// Music.app — a channel that bypasses HID seize and the cghidEventTap entirely. `bootout`
/// only affects this login session; restored on clean exit, and on next login either way.
enum RCDControl {
    private static let plistPath = "/System/Library/LaunchAgents/com.apple.rcd.plist"
    private static var suspended = false

    static func suspend() {
        let domain = "gui/\(getuid())"
        let service = "\(domain)/com.apple.rcd"
        guard isLoaded(service: service) else {
            print("ℹ️ com.apple.rcd not loaded; skipping suspend")
            return
        }
        let (status, err) = run(["bootout", service])
        if status == 0 {
            suspended = true
            print("🔇 com.apple.rcd suspended (Music won't auto-launch from BT remote)")
        } else {
            print("⚠️ Could not suspend com.apple.rcd (launchctl exit=\(status)): \(err)")
        }
    }

    static func restore() {
        guard suspended else { return }
        let domain = "gui/\(getuid())"
        let (status, err) = run(["bootstrap", domain, plistPath])
        if status == 0 {
            print("🔊 com.apple.rcd restored")
        } else {
            print("⚠️ Could not restore com.apple.rcd (launchctl exit=\(status)): \(err) — next login will re-register it")
        }
        suspended = false
    }

    private static func isLoaded(service: String) -> Bool {
        let (status, _) = run(["print", service], captureStderr: false)
        return status == 0
    }

    private static func run(_ args: [String], captureStderr: Bool = true) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardOutput = Pipe()
        proc.standardError = captureStderr ? errPipe : Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let errData = captureStderr ? errPipe.fileHandleForReading.readDataToEndOfFile() : Data()
            let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (proc.terminationStatus, errStr)
        } catch {
            return (-1, "\(error)")
        }
    }
}
