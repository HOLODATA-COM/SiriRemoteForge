//
//  SiriRemoteApp.swift
//  HyperVibe
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreBluetooth
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
    private var appWheel: AppWheelController?
    private var dragIndicator: DragIndicator?
    private var touchMonitor: TouchMonitorWindowController?
    private var focusFollower: FocusFollowsCursor?
    private var holdHUD: HoldProgressHUD?
    /// Last connection state the HUD reflected — nil until the first callback, so the initial
    /// connect still announces itself. Guards against one physical connect showing several cards.
    private var lastConnectedState: Bool?
    private var gattDiagnostics: GATTDiagnostics?
    /// Feeds the built-in mic into the "Siri Remote Mic" device when Siri isn't held (Phase 2b).
    private var builtinMicFeeder: BuiltinMicFeeder?
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

        // `--enable-login-item` / `--disable-login-item`: apply and exit, before anything is wired
        // up or the remote is seized. Registration has to come from the app bundle itself, so this
        // is the only way to script it.
        LaunchAtLogin.handleCommandLineIfNeeded()

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

        // Headless visual QC: `--test-connect-hud` shows the connect/disconnect HUDs so they can be
        // screenshotted, then exits — without seizing the remote or wiring up the rest of the app.
        if CommandLine.arguments.contains("--test-connect-hud") {
            NSApp.setActivationPolicy(.accessory)
            let hud = LayerHUD()
            layerHUD = hud
            hud.showRemoteConnected()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { hud.showRemoteDisconnected() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { exit(0) }
            return
        }

        // Headless visual QC: `--test-hold-hud` runs a hold from 0 through every stage so the
        // progress card can be screenshotted, then exits — without seizing the remote. Uses real
        // actions so the icon resolution (app icons vs SF Symbols) is exercised too.
        if CommandLine.arguments.contains("--test-hold-hud") {
            NSApp.setActivationPolicy(.accessory)
            let hud = HoldProgressHUD()
            holdHUD = hud
            // Covers all three presentations: a shell `open -a` (real app icon), a `launch`
            // (real app icon), and a command given an explicit label + symbol in config.
            let demo: [(TimeInterval, Action, Config.Presentation?)] = [
                // Stretched well past the real thresholds: each stage has to stay put long enough
                // to be screenshotted, and app launch latency makes short windows unhittable.
                (2.0, .shell(command: "open -a 'Mission Control'"), nil),
                (3.5, .launch(app: "Music", url: nil), nil),
                (5.0, .shell(command: "pmset sleepnow"),
                      Config.Presentation(label: "Sleep", icon: "moon.fill")),
            ]
            func face(_ a: Action, _ p: Config.Presentation?) -> HoldProgressHUD.Face {
                let v = ActionVisual.resolve(a, p)
                return .init(label: v.label, image: v.image, iconOnly: v.iconOnly)
            }
            // Unlabelled AppleScript aimed at an app — should show Music's real icon, WITH a label.
            var demoStages = demo.map { HoldProgressHUD.Stage(threshold: $0.0, face: face($0.1, $0.2)) }
            // The escape hatch, exactly as the real path appends it.
            var cancelFace = face(.mouse(op: "click"),
                                  Config.Presentation(label: "Cancel", icon: "arrow.uturn.backward"))
            cancelFace.isCancel = true
            demoStages.append(.init(threshold: 6.0, face: cancelFace))
            hud.begin(base: face(.applescript(script: "tell application \"Music\" to playpause"),
                                 Config.Presentation(label: "Play / Pause", icon: "playpause.fill")),
                      stages: demoStages)
            DispatchQueue.main.asyncAfter(deadline: .now() + 7.0) { hud.end(firedIndex: 4) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.0) { exit(0) }
            return
        }





        // Headless visual QC: `--test-drag-badge` pins the drag badge beside the pointer for a few
        // seconds so it can be screenshotted, then exits — without seizing the remote.
        if CommandLine.arguments.contains("--test-drag-badge") {
            NSApp.setActivationPolicy(.accessory)
            let badge = DragIndicator()
            dragIndicator = badge
            badge.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { badge.hide() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { exit(0) }
            return
        }

        // Headless visual QC: `--test-app-wheel` shows the launcher with a sector highlighted so
        // it can be screenshotted, then exits — without seizing the remote or launching anything.
        if CommandLine.arguments.contains("--test-app-wheel") {
            NSApp.setActivationPolicy(.accessory)
            let wheel = AppWheelController()
            appWheel = wheel
            wheel.configure(apps: ["WeChat", "Google Chrome", "Music", "Warp"])
            wheel.open()
            // Nudge the pointer off-centre so a sector is actually highlighted: the follow timer
            // recomputes from the live cursor every frame, so setting `highlighted` by hand would
            // just be overwritten.
            // Walk the pointer round the ring so the glide between sectors can be watched, and
            // screenshotted mid-flight.
            let centre = CGEvent(source: nil)?.location ?? .zero
            for (i, angle) in [0.0, 90.0, 180.0, 270.0, 0.0].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 1.1) {
                    let r = 120.0, a = angle * .pi / 180
                    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                            mouseCursorPosition: CGPoint(x: centre.x + r * cos(a),
                                                         y: centre.y - r * sin(a)),
                            mouseButton: .left)?.post(tap: .cghidEventTap)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { exit(0) }
            return
        }

        // Read-only CoreBluetooth inventory. Keep this path headless and separate from the normal
        // IOHID detector so it cannot seize the remote while GATT services are being mapped.
        if let idx = CommandLine.arguments.firstIndex(of: "--dump-gatt"),
           idx + 1 < CommandLine.arguments.count {
            NSApp.setActivationPolicy(.accessory)
            let diagnostic = GATTDiagnostics(targetName: CommandLine.arguments[idx + 1])
            gattDiagnostics = diagnostic
            diagnostic.start()
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

        // The launcher is summoned by an ordinary `.appWheel` hold binding, so it arrives here as an
        // action like any other — and inherits the progress card that every hold gets.
        let actionExecutor = MacActionExecutor()
        let engineController = Controller(
            engine: MappingEngine(config: config),
            executor: actionExecutor
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
            self?.appWheel?.configure(apps: reloaded.settings.appWheel)   // and the launcher's app list
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

        // Release-to-select needs to be visible: a track that fills while a button is held, with a
        // tick per bound stage and the name of the action that runs if it is released right now.
        let progress = HoldProgressHUD()
        holdHUD = progress
        remoteInputHandler?.onHoldBegan = { base, stages in
            func face(_ action: Action, _ p: Config.Presentation?) -> HoldProgressHUD.Face {
                let v = ActionVisual.resolve(action, p)
                return .init(label: v.label, image: v.image, iconOnly: v.iconOnly)
            }
            progress.begin(base: base.map { face($0.action, $0.presentation) },
                           stages: stages.map {
                               var f = face($0.action, $0.presentation)
                               f.isCancel = $0.isCancel
                               return .init(threshold: $0.threshold, face: f)
                           })
        }
        remoteInputHandler?.onHoldEnded = { firedIndex in progress.end(firedIndex: firedIndex) }

        let dragBadge = DragIndicator()
        dragIndicator = dragBadge
        remoteInputHandler?.onStickyDrag = { on in on ? dragBadge.show() : dragBadge.hide() }

        // `--touch-monitor`: open the live view alongside normal operation, so the remote keeps
        // working while its raw data is on screen. Read-only; it only observes.
        if CommandLine.arguments.contains("--touch-monitor") {
            let monitor = TouchMonitorWindowController()
            touchMonitor = monitor
            if let size = touchHandler?.surfaceDimensions { monitor.model.surface = size }
            touchHandler?.onRawTouch = { [weak monitor] snaps in monitor?.model.ingest(snaps) }
            DispatchQueue.main.async { monitor.show() }
        }

        // Radial app launcher. Modal while open: the handler routes every button here, Select
        // launching what is highlighted and anything else cancelling.
        let wheel = AppWheelController()
        appWheel = wheel
        wheel.configure(apps: config.settings.appWheel)
        actionExecutor.onAppWheel = { [weak wheel] in
            guard let wheel = wheel else { return }
            wheel.open()
            RemoteInputHandler.isAppWheelOpen = wheel.isOpen
        }
        remoteInputHandler?.onAppWheelButton = { [weak wheel] button in
            guard let wheel = wheel else { return }
            if button == "select" { wheel.commit() } else { wheel.cancel() }
            RemoteInputHandler.isAppWheelOpen = wheel.isOpen
        }

        cursorHighlighter = CursorHighlighter()
        touchHandler?.onShake = { [weak self] in
            guard let self = self, self.findCursorEnabled else { return }
            self.cursorHighlighter?.flash()
        }
        touchHandler?.start()
        // Focus-follows-cursor, restricted to fullscreen windows. Created before applyTune so the
        // config's value is what switches it on — it starts disabled and never self-enables.
        focusFollower = FocusFollowsCursor()
        applyTune(model.tune)   // touchHandler + remoteInputHandler now exist — push the tuning
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] device in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let connected = (device != nil)
                self.remoteInputHandler?.setRemoteDevice(device)
                self.menuBarManager.updateConnectionStatus(connected: connected)
                self.settingsModel?.connected = connected

                // HUD only on an actual transition. The remote publishes several HID interfaces and
                // this callback can run more than once per physical connect, which would otherwise
                // stack up identical "Connected" cards.
                if self.lastConnectedState != connected {
                    self.lastConnectedState = connected
                    connected ? self.layerHUD?.showRemoteConnected()
                              : self.layerHUD?.showRemoteDisconnected()

                    // Reconnecting is itself a wake signal: the remote sleeps after a few minutes
                    // idle, so a screen dimmed with the Power button is typically found the next
                    // morning with the remote asleep. Restoring here means picking the remote up is
                    // enough — it does not depend on a specific button or touch arriving first, and
                    // it covers the case where the trackpad has not re-attached yet.
                    if connected { Brightness.restoreIfDimmed() }
                }
            }
        }
        remoteDetector?.startDetection()

        if CommandLine.arguments.contains("--native-ptt") {
            // Let all seven IOHID raw-report callbacks attach before the Apple driver starts its
            // native push-to-talk path. The continuously running process then captures any audio.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NativePushToTalk.setEnabled(true)
            }
        }

        if CommandLine.arguments.contains("--direct-ptt") {
            // Wait for all seven virtual interfaces to enumerate, then hold the remote's hidden
            // one-byte PTT Feature report for a bounded 20-second capture window. The ambient audio
            // test can run unattended; cleanup also sends the release byte if the app exits early.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.remoteInputHandler?.setDirectPushToTalk(true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 22.0) { [weak self] in
                self?.remoteInputHandler?.setDirectPushToTalk(false)
            }
        }
        
        // Request Input Monitoring so media key tap works in both CLI and .app
        if #available(macOS 10.15, *) {
            if !CGPreflightListenEventAccess() {
                CGRequestListenEventAccess()
            }
        }
        
        // Virtual-mic fallback (Phase 2b): keep the "Siri Remote Mic" device fed with the
        // Mac's BUILT-IN microphone whenever the Siri button isn't held. Demand-gated on the
        // plug-in's consumers notification — the mic is only hot while some app actually has
        // the virtual device open. See BuiltinMicFeeder.swift for the feedback-avoidance rules.
        builtinMicFeeder = BuiltinMicFeeder()
        builtinMicFeeder?.start()

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
        remoteInputHandler?.holdCancelGrace = t.holdCancelGrace
        remoteInputHandler?.doubleTapWindow = t.doubleTapWindow
        remoteInputHandler?.spacesModeWindow = t.spacesModeWindow
        findCursorEnabled = t.findCursorEnabled
        focusFollower?.enabled = t.focusFollowsCursor
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
            s.holdCancelGrace = t.holdCancelGrace
            s.doubleTapWindow = t.doubleTapWindow
            s.spacesModeWindow = t.spacesModeWindow
            s.findCursorEnabled = t.findCursorEnabled
            s.focusFollowsCursor = t.focusFollowsCursor
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
        // The dim was made with real hardware key events, so it outlives this process. Nothing else
        // restores it — the usual restore paths are remote activity, and there is no remote left.
        Brightness.restoreIfDimmed()

        // Quitting must not leave the left mouse button held down. Sticky drag survives the button
        // and the finger by design, so the process ending is otherwise no reason for it to stop.
        // Synchronously, not through `stopDetection`'s device callback: that reaches
        // `releaseAllHeldKeys` via `DispatchQueue.main.async`, which may never run during
        // termination. Anything system-visible has to be undone on this thread, now.
        remoteInputHandler?.setRemoteDevice(nil)
        remoteInputHandler?.endStickyDrag()

        // Flush a debounced tune write instead of letting it die with the process. config.jsonc is
        // the single source of truth and tuning re-seeds from it at launch, so a slider moved within
        // 0.4s of quitting was genuinely lost — it applied live, looked saved, and reverted on the
        // next start.
        if let pending = tunePersistWork, !pending.isCancelled {
            pending.cancel()
            tunePersistWork = nil
            persistTuneToConfig()
        }

        if CommandLine.arguments.contains("--native-ptt") {
            NativePushToTalk.setEnabled(false)
        }
        if CommandLine.arguments.contains("--direct-ptt") {
            remoteInputHandler?.setDirectPushToTalk(false)
        }
        touchHandler?.stop()
        remoteDetector?.stopDetection()
        mediaKeyInterceptor?.stop()
        // Drop producerActive in the shm ring so a consumer never waits on a dead producer
        // (stop() is idempotent — cleanup runs on both termination paths).
        builtinMicFeeder?.stop()
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
        let bound = [base, base + ".double", base + ".triple",
                     base + ".hold", base + ".hold2", base + ".hold3"]
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
            // Already booted out — almost certainly by a previous run of this app that died before
            // restoring it. ADOPT that suspension rather than shrugging: leaving `suspended` false
            // meant even a clean quit later would no-op, so one crash disabled rcd for the entire
            // login session and only `launchctl bootstrap` or re-login brought it back.
            print("ℹ️ com.apple.rcd already not loaded — adopting, so this run restores it on quit")
            suspended = true
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
