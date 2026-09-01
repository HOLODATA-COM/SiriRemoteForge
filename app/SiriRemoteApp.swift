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
    private var updateManager: UpdateManager?
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var touchHandler: TouchHandler?
    private var cursorHighlighter: CursorHighlighter?
    private var layerHUD: LayerHUD?
    private var statusWidget: StatusWidgetController?
    /// Temporary native-Voice capsule. Independent from the always-on Layer widget so users who
    /// hide persistent status still see capture and Final-pipeline progress.
    private var voicePipelineHUD: VoicePipelineHUDController?
    private var holdAnimationGallery: HoldAnimationGalleryController?
    private var appWheel: AppWheelController?
    private var dragIndicator: DragIndicator?
    private var touchMonitor: TouchMonitorWindowController?
    private var demoModeWindow: DemoModeWindowController?
    private var focusFollower: FocusFollowsCursor?
    private var holdHUD: HoldProgressHUD?
    /// Last connection state the HUD reflected — nil until the first callback, so the initial
    /// connect still announces itself. Guards against one physical connect showing several cards.
    private var lastConnectedState: Bool?
    private var gattDiagnostics: GATTDiagnostics?
    /// Feeds the built-in mic into the "Siri Remote Mic" device when Siri isn't held (Phase 2b).
    private var builtinMicFeeder: BuiltinMicFeeder?
    /// App-native low-latency speech-to-text. Separate from the legacy external PTT hotkey route.
    private var voiceDictation: VoiceDictationCoordinator?
    /// Pre-rendered, paired native-Voice edge sounds. The existing Layer 1 external workflow keeps
    /// owning its own feedback, so HyperVibe plays these only for native Layer 2/3 sessions.
    private var voiceFeedbackSound: VoiceFeedbackSound?
    private var preparedVoiceDictionary: [Config.DictationTerm]?
    /// Mirror of the tune flag — the shake→highlight path is gated on this (see `applyTune`).
    private var findCursorEnabled = true
    /// Independent from the compact status widget: users may keep the always-on Layer card while
    /// disabling the larger release-to-select progress HUD (or vice versa).
    private var holdHUDEnabled = true
    private var layerHUDEnabled = true
    private var dragIndicatorEnabled = true
    /// Avoid asking SMAppService to re-apply the same JSON request for every unrelated slider tick.
    private var lastLaunchAtLoginRequest: Bool?

    // Config engine (SiriRemoteCore)
    private var controller: Controller?
    private var appWatcher: AppWatcher?
    private var configWatcher: ConfigFileWatcher?

    // Settings UI
    private var settingsModel: SettingsModel?
    private var settingsWindow: SettingsWindowController?
    private var setupWizard: SetupWizardController?
    /// Passive permission health monitoring. It updates the menu and reattaches only the subsystem
    /// whose permission changed; it never triggers a TCC prompt by itself.
    private var permissionHealthTimer: Timer?
    private var permissionActivationObserver: NSObjectProtocol?
    private var openSystemCheckObserver: NSObjectProtocol?
    private var previousAccessibilityGranted: Bool?
    private var previousInputMonitoringGranted: Bool?
    /// Debounces persisting Tuning-tab slider changes back into config.jsonc.
    private var tunePersistWork: DispatchWorkItem?
    /// Session-affecting Voice text fields publish on every keystroke. Keep those edits live and
    /// auto-saving while reconnecting only once after the user pauses, not twice per character.
    private var voiceConfigureWork: DispatchWorkItem?
    
    /// Show (or re-show) the first-run setup guide. Used both by the first-launch trigger and the
    /// menu bar's "Setup Guide" item.
    func showSetupWizard() {
        let wizard = setupWizard ?? SetupWizardController(
            onFinished: { [weak self] in self?.setupWizard = nil },
            onLanguageChosen: { [weak self] language in
                self?.settingsModel?.tune.interfaceLanguage = language.rawValue
            },
            onLaunchAtLoginChanged: { [weak self] enabled in
                self?.settingsModel?.tune.launchAtLoginEnabled = enabled
            },
            onPermissionStateChanged: { [weak self] in
                self?.refreshPermissionHealth()
            }
        )
        setupWizard = wizard
        wizard.show()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 HyperVibe starting...")

        // `--enable-login-item` / `--disable-login-item`: apply and exit, before anything is wired
        // up or the remote is seized. Registration has to come from the app bundle itself, so this
        // is the only way to script it.
        LaunchAtLogin.handleCommandLineIfNeeded()

        // Headless AppKit bridge verification: consumes synthetic local NSEvents only, never opens
        // the remote or posts a system keyboard event.
        if CommandLine.arguments.contains("--test-shortcut-recorder") {
            exit(ShortcutRecorderSelfTest.run() ? 0 : 1)
        }

        // Headless self-QC: `--snapshot-layout <path>` renders the Layout settings view to a PNG
        // and exits, without seizing the remote or opening a window.
        if let idx = CommandLine.arguments.firstIndex(of: "--snapshot-layout"),
           idx + 1 < CommandLine.arguments.count {
            LayoutSnapshot.renderAndExit(to: CommandLine.arguments[idx + 1])
            return
        }

        // Isolated motion-design lab: nine long-press candidates run against the same timeline in a
        // comparison window. It deliberately returns before remote/HID/audio setup, so designers
        // can leave it open beside the production app without affecting input or rcd.
        if CommandLine.arguments.contains("--preview-hold-animations") {
            // The isolated motion lab is a real foreground design surface. Production continues
            // to use accessory mode; only this explicit preview command receives a Dock/window
            // presence so macOS always moves it onto the user's active Space.
            NSApp.setActivationPolicy(.regular)
            let gallery = HoldAnimationGalleryController()
            holdAnimationGallery = gallery
            gallery.show()
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

        // Headless visual QC: `--test-layer-hud` walks the complete three-layer cycle while the card
        // stays visible, exercising tint morphing and in-place transitions without seizing remote IO.
        if CommandLine.arguments.contains("--test-layer-hud")
            || CommandLine.arguments.contains("--test-layer-hud-long") {
            NSApp.setActivationPolicy(.accessory)
            let interval: TimeInterval = CommandLine.arguments.contains("--test-layer-hud-long")
                ? 8.0 : 0.65
            let previewConfig = ConfigStore.loadConfig()
            let hud = LayerHUD(layers: previewConfig.settings.layers,
                               icons: previewConfig.settings.icons,
                               holdDuration: interval + 0.55)
            layerHUD = hud
            hud.showOff("L2")
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { hud.showOn("L1") }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 2) { hud.showOn("L2") }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 3) { hud.showOff("L2") }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 4 + 0.9) { exit(0) }
            return
        }

        // Deterministic lifecycle regression for the reported External -> Final failure. Begin a
        // real listening presentation while Final's selector card is already inside its delayed
        // CRT fade; the new waveform must cancel that exit and remain fully visible.
        if CommandLine.arguments.contains("--test-voice-mode-return-to-final") {
            NSApp.setActivationPolicy(.accessory)
            let config = ConfigStore.loadConfig()
            let hud = VoicePipelineHUDController(layers: config.settings.layers,
                                                 icons: config.settings.icons, enabled: true)
            voicePipelineHUD = hud
            hud.showVoiceModeSwitch(.external)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                hud.showVoiceModeSwitch(.final)
            }
            // Final preview starts its fade at roughly 1.291 s. This intentionally lands inside
            // the 52 ms window-alpha animation rather than testing only an easy idle transition.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.31) {
                hud.beginListening()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.56) {
                let passed = hud.listeningPresentationIsVisibleForTesting()
                print("VOICE_MODE_RETURN_TO_FINAL_TEST \(passed ? "PASS" : "FAIL")")
                exit(passed ? 0 : 1)
            }
            return
        }

        // Isolated visual QC for the global Mute+Side selector. It deliberately visits External
        // twice so a missing third-state preview or an interrupted return animation is obvious.
        // No remote, microphone, input hook or network resource is opened.
        if CommandLine.arguments.contains("--test-voice-mode-hud")
            || CommandLine.arguments.contains("--test-voice-mode-hud-long") {
            NSApp.setActivationPolicy(.accessory)
            let config = ConfigStore.loadConfig()
            let hud = VoicePipelineHUDController(layers: config.settings.layers,
                                                 icons: config.settings.icons, enabled: true)
            voicePipelineHUD = hud
            let modes: [Config.DictationMode] = [.external, .final, .streaming, .external]
            let long = CommandLine.arguments.contains("--test-voice-mode-hud-long")
            let count = long ? 24 : modes.count
            let interval: TimeInterval = long ? 0.72 : 0.54
            for index in 0..<count {
                let mode = modes[index % modes.count]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22 + Double(index) * interval) {
                    hud.showVoiceModeSwitch(mode)
                }
            }
            let exitAfter = 0.22 + Double(count) * interval + 1.1
            DispatchQueue.main.asyncAfter(deadline: .now() + exitAfter) { exit(0) }
            return
        }

        // Exact production rendering snapshots for the three Mute+Side selector destinations.
        // This opens only the temporary HUD and writes its transparent 112×98 surface to PNG.
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot-voice-mode-hud"),
           index + 2 < CommandLine.arguments.count {
            NSApp.setActivationPolicy(.prohibited)
            let config = ConfigStore.loadConfig()
            let hud = VoicePipelineHUDController(layers: config.settings.layers,
                                                 icons: config.settings.icons, enabled: true)
            voicePipelineHUD = hud
            let rawMode = CommandLine.arguments[index + 1]
            let mode: Config.DictationMode
            switch rawMode.lowercased() {
            case "external": mode = .external
            case "final": mode = .final
            case "streaming", "live": mode = .streaming
            default:
                print("VOICE_MODE_SNAPSHOT FAIL expected external|final|streaming")
                exit(2)
            }
            let destination = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            hud.showVoiceModeSwitch(mode)
            // An optional fourth argument selects an exact animation time for visual QC. The
            // default captures the settled symbol inside the production 980 ms dwell.
            let captureAfter = index + 3 < CommandLine.arguments.count
                ? (Double(CommandLine.arguments[index + 3]) ?? 0.68) : 0.68
            DispatchQueue.main.asyncAfter(deadline: .now() + captureAfter) {
                let passed = hud.writeSnapshotForTesting(to: destination)
                print("VOICE_MODE_SNAPSHOT \(passed ? "PASS" : "FAIL") \(rawMode)")
                exit(passed ? 0 : 1)
            }
            return
        }

        // Sample the real panel in the middle of its 160 ms exit. The same particle pose must
        // remain a mode symbol until orderOut; snapping it back to a sphere makes this fail.
        if CommandLine.arguments.contains("--test-voice-mode-icon-exit") {
            NSApp.setActivationPolicy(.prohibited)
            let config = ConfigStore.loadConfig()
            let hud = VoicePipelineHUDController(layers: config.settings.layers,
                                                 icons: config.settings.icons, enabled: true)
            voicePipelineHUD = hud
            hud.showVoiceModeSwitch(.final)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.04) {
                let passed = hud.modePreviewExitIsCleanForTesting()
                print("VOICE_MODE_ICON_EXIT_TEST \(passed ? "PASS" : "FAIL")")
                exit(passed ? 0 : 1)
            }
            return
        }

        // Isolated terminal-state visual QC. Keeping Copied/Error on screen long enough for a
        // pixel-level screenshot avoids relying on the production sub-second dwell, while still
        // rendering the exact same controller and presentation vocabulary. No remote, microphone,
        // network, or text-delivery target is opened.
        if let stateIndex = CommandLine.arguments.firstIndex(of: "--test-voice-pipeline-hud-state"),
           stateIndex + 1 < CommandLine.arguments.count {
            NSApp.setActivationPolicy(.accessory)
            let config = ConfigStore.loadConfig()
            let hud = VoicePipelineHUDController(layers: config.settings.layers,
                                                 icons: config.settings.icons, enabled: true)
            voicePipelineHUD = hud
            switch CommandLine.arguments[stateIndex + 1].lowercased() {
            case "copied":
                hud.showNativeDictationPhase(
                    .copied, message: L("Insertion was unavailable · copied instead")
                )
            case "error":
                hud.showNativeDictationPhase(.error, message: L("Text could not be delivered"))
            default:
                print("VOICE_PIPELINE_HUD_STATE_TEST FAIL expected copied|error")
                exit(2)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) { exit(0) }
            return
        }

        // Isolated visual QC for the temporary native-Voice capsule. It uses deterministic
        // acoustic features and every Final stage, but opens no microphone/HID/network resource.
        if CommandLine.arguments.contains("--test-voice-pipeline-hud")
            || CommandLine.arguments.contains("--test-voice-pipeline-hud-long")
            || CommandLine.arguments.contains("--test-voice-pipeline-hud-interrupt")
            || CommandLine.arguments.contains("--test-voice-pipeline-hud-interrupt-long") {
            NSApp.setActivationPolicy(.accessory)
            let config = ConfigStore.loadConfig()
            let hud = VoicePipelineHUDController(layers: config.settings.layers,
                                                 icons: config.settings.icons, enabled: true)
            voicePipelineHUD = hud
            let long = CommandLine.arguments.contains("--test-voice-pipeline-hud-long")
            let interruptLong = CommandLine.arguments.contains(
                "--test-voice-pipeline-hud-interrupt-long"
            )
            let interrupt = interruptLong
                || CommandLine.arguments.contains("--test-voice-pipeline-hud-interrupt")
            if interrupt {
                // Stress the compositor with transitions faster than their authored 220–280 ms
                // lifetime, an exit interrupted by a new capture, and Streaming's direct release.
                // This preview is deterministic and never opens a real microphone or input target.
                func beginMeteredVoice(at offset: TimeInterval, duration: TimeInterval,
                                       finish: @escaping () -> Void) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                        hud.beginListening()
                        let started = CACurrentMediaTime()
                        Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                             repeats: true) { timer in
                            let elapsed = CACurrentMediaTime() - started
                            guard elapsed < duration else {
                                timer.invalidate()
                                hud.endListening()
                                finish()
                                return
                            }
                            hud.updateVoiceMeter(.init(
                                level: Float(0.12 + 0.66 * max(0, sin(elapsed * 7.1))),
                                pitchHz: Float(178 * pow(2, 4.5 * sin(elapsed * 1.1) / 12)),
                                pitchConfidence: 0.93,
                                brightness: Float(0.22 + 0.64 * max(0, sin(elapsed * 2.6)))
                            ))
                        }
                    }
                }
                func stressCycle(at offset: TimeInterval) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                        beginMeteredVoice(at: 0.35, duration: 0.82) {
                            hud.showNativeDictationPhase(.transcribing,
                                                         message: L("Finishing transcript…"))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                                hud.showNativeDictationPhase(.polishing,
                                                             message: L("Polishing transcript…"))
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                                hud.showNativeDictationPhase(.inserting,
                                                             message: L("Delivering text…"))
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                                hud.showNativeDictationPhase(.inserted,
                                                             message: L("Dictation inserted"))
                            }
                            // Interrupt the terminal card before it has finished folding out.
                            beginMeteredVoice(at: 0.36, duration: 0.62) {
                                hud.showNativeDictationPhase(.idle, message: "")
                                // Interrupt Streaming's release collapse with a third capture.
                                beginMeteredVoice(at: 0.09, duration: 0.55) {
                                    hud.showNativeDictationPhase(
                                        .transcribing, message: L("Finishing transcript…")
                                    )
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                                        hud.showNativeDictationPhase(
                                            .error, message: L("Text could not be delivered")
                                        )
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.72) {
                                        hud.showNativeDictationPhase(.idle, message: "")
                                    }
                                }
                            }
                        }
                    }
                }
                stressCycle(at: 0)
                if interruptLong {
                    for offset in stride(from: 4.25, through: 29.75, by: 4.25) {
                        stressCycle(at: offset)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 34.0) { exit(0) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.7) { exit(0) }
                }
                return
            }
            let cycle: (TimeInterval) -> Void = { offset in
                DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                    hud.beginListening()
                    let started = CACurrentMediaTime()
                    Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                         repeats: true) { timer in
                        let elapsed = CACurrentMediaTime() - started
                        guard elapsed < 1.9 else {
                            timer.invalidate()
                            hud.endListening()
                            hud.showNativeDictationPhase(.transcribing,
                                                         message: L("Finishing transcript…"))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
                                hud.showNativeDictationPhase(.polishing,
                                                             message: L("Polishing transcript…"))
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.04) {
                                hud.showNativeDictationPhase(.inserting,
                                                             message: L("Delivering text…"))
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.56) {
                                hud.showNativeDictationPhase(.inserted,
                                                             message: L("Dictation inserted"))
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.60) {
                                hud.showNativeDictationPhase(.idle, message: "")
                            }
                            return
                        }
                        let syllable = max(0, sin(elapsed * 5.4))
                        let semitones = 5.0 * sin(elapsed * 0.90)
                        hud.updateVoiceMeter(.init(
                            level: Float(0.10 + 0.68 * syllable),
                            pitchHz: Float(170.0 * pow(2.0, semitones / 12.0)),
                            pitchConfidence: 0.94,
                            brightness: Float(0.18 + 0.70 * max(0, sin(elapsed * 2.2)))
                        ))
                    }
                }
            }
            cycle(0.6)
            if long {
                for offset in stride(from: 6.8, through: 48.0, by: 6.2) { cycle(offset) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 55) { exit(0) }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.4) { exit(0) }
            }
            return
        }

        // Isolated browser/editor delivery QC. The caller must deliberately focus a disposable
        // text field before launching this flag. It opens no microphone, network or remote input;
        // it only sends a fixed non-secret probe through the exact Final delivery chain and prints
        // the route outcome. Production never reaches this branch.
        if CommandLine.arguments.contains("--test-voice-final-delivery") {
            NSApp.setActivationPolicy(.accessory)
            let deliverer = VoiceTextDeliverer()
            let settings = ConfigStore.loadConfig().settings.dictation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                guard let seed = deliverer.captureTargetSeed() else {
                    print("VOICE_FINAL_DELIVERY_TEST FAIL no-target")
                    exit(1)
                }
                Task {
                    let target = await Task.detached(priority: .userInitiated) {
                        VoiceTextDeliverer.resolveTarget(seed)
                    }.value
                    let outcome = await deliverer.deliverFinal(
                        "HyperVibe browser delivery test", to: target, settings: settings
                    )
                    print("VOICE_FINAL_DELIVERY_TEST \(outcome.wasDelivered ? "PASS" : "FAIL") "
                          + "app=\(target.bundleIdentifier ?? "unknown") outcome=\(outcome)")
                    // Clipboard restoration is deliberately asynchronous and must finish before
                    // the test process exits.
                    try? await Task.sleep(nanoseconds: 650_000_000)
                    exit(outcome == .inserted ? 0 : 1)
                }
            }
            return
        }

        // Headless visual QC for the optional persistent status surface. It cycles through the
        // resting Layer, a real Music app icon, a track action, and another Layer without touching
        // the remote, rcd, Accessibility, or any input device.
        if CommandLine.arguments.contains("--test-status-widget") {
            NSApp.setActivationPolicy(.accessory)
            let config = ConfigStore.loadConfig()
            let widget = StatusWidgetController(layers: config.settings.layers,
                                                icons: config.settings.icons, enabled: true)
            statusWidget = widget
            widget.setLayer(nil, animated: false)
            widget.setConnected(true, animated: false)
            let slowVisualQC = CommandLine.arguments.contains("--test-status-widget-long")
            let beat: TimeInterval = slowVisualQC ? 10.0 : 3.0
            // Pin one requested face for deterministic pixel inspection. This exists because
            // screenshot permission round-trips can outlast the production sub-second dwell.
            if let stateIndex = CommandLine.arguments.firstIndex(of: "--test-status-widget-state"),
               stateIndex + 1 < CommandLine.arguments.count {
                let requestedState = CommandLine.arguments[stateIndex + 1].lowercased()
                let dwell: TimeInterval = slowVisualQC
                    ? (requestedState == "back-hold" ? 260.0 : 55.0)
                    : 12.0
                switch requestedState {
                case "music":
                    widget.showApplication(bundleID: "com.apple.Music", duration: dwell)
                case "next":
                    widget.showAction(.init(key: "button.nextTrack.double",
                                            action: .media(key: "next"),
                                            presentation: .init(label: "Next Track", icon: nil)),
                                      durationOverride: dwell)
                case "voice":
                    let action = Controller.HandledAction(
                        key: "button.siri.hold2",
                        action: .pushToTalk(keys: "rctrl+rcmd+ropt"),
                        presentation: .init(label: "Voice Input", icon: "waveform")
                    )
                    widget.beginContinuousAction(action)
                    let voiceStartedAt = CACurrentMediaTime()
                    Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                         repeats: true) { timer in
                        let elapsed = CACurrentMediaTime() - voiceStartedAt
                        guard elapsed < dwell else {
                            timer.invalidate()
                            widget.endContinuousAction(key: action.key)
                            return
                        }
                        // Deterministic design-QC signal: changing amplitude, a five-semitone
                        // intonation arc, brief unvoiced consonants, and independent brightness.
                        // Production always supplies these values from real PCM analysis.
                        let syllable = max(0, sin(elapsed * 5.2))
                        let level = Float(0.10 + 0.68 * syllable)
                        let semitones = 5.0 * sin(elapsed * 0.92)
                        let pitch = Float(170.0 * pow(2.0, semitones / 12.0))
                        let consonant = sin(elapsed * 3.1) > 0.78
                        widget.updateVoiceMeter(.init(
                            level: level,
                            pitchHz: consonant ? 0 : pitch,
                            pitchConfidence: consonant ? 0.18 : 0.94,
                            brightness: Float(0.16 + 0.72 * max(0, sin(elapsed * 2.3)))
                        ))
                    }
                case "voice-transition":
                    // Two complete idle ↔ Voice hand-offs with deterministic audio features.
                    // The one-second lead-in makes entry, release and re-entry easy to capture as
                    // video without enabling HID discovery, microphone capture or input emission.
                    let action = Controller.HandledAction(
                        key: "button.siri.hold2",
                        action: .pushToTalk(keys: "rctrl+rcmd+ropt"),
                        presentation: .init(label: "Voice Input", icon: "waveform")
                    )
                    let runVoice: (TimeInterval) -> Void = { offset in
                        DispatchQueue.main.asyncAfter(deadline: .now() + offset) {
                            widget.beginContinuousAction(action)
                            let voiceStartedAt = CACurrentMediaTime()
                            Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                                 repeats: true) { timer in
                                let elapsed = CACurrentMediaTime() - voiceStartedAt
                                guard elapsed < 2.2 else {
                                    timer.invalidate()
                                    widget.endContinuousAction(key: action.key)
                                    return
                                }
                                let syllable = max(0, sin(elapsed * 5.2))
                                let semitones = 5.0 * sin(elapsed * 0.92)
                                widget.updateVoiceMeter(.init(
                                    level: Float(0.10 + 0.68 * syllable),
                                    pitchHz: Float(170.0 * pow(2.0, semitones / 12.0)),
                                    pitchConfidence: 0.94,
                                    brightness: Float(0.16 + 0.72
                                        * max(0, sin(elapsed * 2.3)))
                                ))
                            }
                        }
                    }
                    runVoice(15.0)
                    runVoice(30.0)
                case "voice-pipeline":
                    // Complete Final-mode hand-off: the last real waveform becomes Transcribing
                    // directly, then every semantic stage advances through the same compact card.
                    let action = Controller.HandledAction(
                        key: "button.siri.hold2",
                        action: .pushToTalk(keys: "rctrl+rcmd+ropt"),
                        presentation: .init(label: "Voice Input", icon: "waveform")
                    )
                    widget.beginContinuousAction(action)
                    let started = CACurrentMediaTime()
                    Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0,
                                         repeats: true) { timer in
                        let elapsed = CACurrentMediaTime() - started
                        guard elapsed < 1.8 else {
                            timer.invalidate()
                            widget.endNativeContinuousAction(key: action.key)
                            widget.showNativeDictationPhase(
                                .transcribing, message: L("Finishing transcript…")
                            )
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                                widget.showNativeDictationPhase(
                                    .polishing, message: L("Polishing transcript…")
                                )
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.10) {
                                widget.showNativeDictationPhase(
                                    .inserting, message: L("Delivering text…")
                                )
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.65) {
                                widget.showNativeDictationPhase(
                                    .inserted, message: L("Dictation inserted")
                                )
                            }
                            return
                        }
                        let syllable = max(0, sin(elapsed * 5.2))
                        let semitones = 5.0 * sin(elapsed * 0.92)
                        widget.updateVoiceMeter(.init(
                            level: Float(0.10 + 0.68 * syllable),
                            pitchHz: Float(170.0 * pow(2.0, semitones / 12.0)),
                            pitchConfidence: 0.94,
                            brightness: Float(0.16 + 0.72 * max(0, sin(elapsed * 2.3)))
                        ))
                    }
                case "hold":
                    let startedAt = CACurrentMediaTime()
                    widget.beginHold(
                        startedAt: startedAt,
                        base: (key: "button.nextTrack",
                               action: .media(key: "next"),
                               presentation: .init(label: "Next Track", icon: nil)),
                        stages: [
                            (threshold: 0.8, key: "button.siri.hold",
                             action: .pushToTalk(keys: "rctrl+rcmd+ropt"),
                             presentation: .init(label: "Voice Input", icon: "waveform"),
                            isCancel: false)
                        ]
                    )
                case "back-hold":
                    // The production Back ladder: visual lead-in at 0.18 s, then Close, Quit and
                    // the implicit cancellation escape hatch. It exercises every optical hand-off
                    // without starting HID discovery or sending any action to the foreground app.
                    let runBackHold = {
                        let startedAt = CACurrentMediaTime()
                        widget.beginHold(
                            startedAt: startedAt,
                            base: (key: "button.menu", action: .keystroke(keys: "delete"),
                                   presentation: .init(label: "Delete", icon: "delete.left.fill")),
                            stages: [
                                (threshold: 0.5, key: "button.menu.taphold",
                                 action: .keystroke(keys: "cmd+w"),
                                 presentation: .init(label: "Close Window",
                                                     icon: "xmark.circle.fill"),
                                 isCancel: false),
                                (threshold: 1.2, key: "button.menu.taphold2",
                                 action: .keystroke(keys: "cmd+q"),
                                 presentation: .init(label: "Quit App", icon: "power"),
                                 isCancel: false),
                                (threshold: 2.2, key: "button.menu.taphold.cancel",
                                 action: .mouse(op: "click"),
                                 presentation: .init(
                                    label: "Cancel",
                                    icon: "arrow.uturn.backward.circle.fill"
                                 ),
                                 isCancel: true),
                            ]
                        )
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.75) {
                            widget.endHold(firedIndex: 3)
                        }
                    }
                    let startOffsets: [TimeInterval] = slowVisualQC
                        ? Array(stride(from: 6.0, through: 240.0, by: 6.0))
                        : [0]
                    for offset in startOffsets {
                        DispatchQueue.main.asyncAfter(deadline: .now() + offset,
                                                      execute: runBackHold)
                    }
                case "tap":
                    let startedAt = CACurrentMediaTime()
                    widget.beginHold(
                        startedAt: startedAt,
                        base: (key: "button.playPause",
                               action: .media(key: "playpause"), presentation: nil),
                        stages: [
                            (threshold: 0.8, key: "button.playPause.hold",
                             action: .media(key: "next"), presentation: nil, isCancel: false)
                        ]
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        widget.endHold(firedIndex: 0)
                    }
                case "layer-tap":
                    let startedAt = CACurrentMediaTime()
                    widget.beginHold(
                        startedAt: startedAt,
                        base: (key: "button.tv", action: .layerCycle, presentation: nil),
                        stages: [
                            (threshold: 0.8, key: "button.tv.hold",
                             action: .appWheel, presentation: nil, isCancel: false)
                        ]
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        // Same order as the production layer release: state changes first, then the
                        // hold lifecycle ends. The status face must be Layer 2, never “Next Layer”.
                        widget.setLayer("L1")
                        widget.endHold(firedIndex: 0)
                    }
                case "select-hold":
                    let startedAt = CACurrentMediaTime()
                    widget.beginHold(
                        startedAt: startedAt,
                        base: (key: "button.select", action: .mouse(op: "click"),
                               presentation: .init(label: "Click", icon: "cursorarrow.click")),
                        stages: [
                            (threshold: 0.5, key: "button.select.hold",
                             action: .mouse(op: "click"),
                             presentation: .init(label: "Drag", icon: "hand.draw.fill"),
                             isCancel: false)
                        ]
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.68) {
                        widget.endHold(firedIndex: 1)
                    }
                case "select-preview":
                    // Release after the 0.18 s visual lead-in but before sticky drag's unchanged
                    // 0.5 s input threshold. The vessel must be partially filled and the result
                    // must still resolve to Click, never Drag.
                    let startedAt = CACurrentMediaTime()
                    widget.beginHold(
                        startedAt: startedAt,
                        base: (key: "button.select", action: .mouse(op: "click"),
                               presentation: .init(label: "Click", icon: "cursorarrow.click")),
                        stages: [
                            (threshold: 0.5, key: "button.select.hold",
                             action: .mouse(op: "click"),
                             presentation: .init(label: "Drag", icon: "hand.draw.fill"),
                             isCancel: false)
                        ]
                    )
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                        widget.endHold(firedIndex: 0)
                    }
                case "layer2":
                    widget.setLayer("L1")
                case "layer-cycle":
                    // Repeated, input-free cycle for recording the complete BASE → L1 → L2 →
                    // BASE carousel. It never starts HID discovery or emits a system event.
                    let layerIDs: [String?] = ["L1", "L2", nil]
                    let interval: TimeInterval = slowVisualQC ? 1.25 : 0.85
                    let transitions = max(1, Int((dwell - 0.6) / interval))
                    for index in 0..<transitions {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6
                                                      + Double(index) * interval) {
                            widget.setLayer(layerIDs[index % layerIDs.count])
                        }
                    }
                case "semantic-cycle":
                    // Every icon grammar in a stable, repeated order: App recognition, then
                    // single/double/triple direct feedback, then a two-stage hold reveal.
                    let cycleLength: TimeInterval = 6.2
                    let cycles = max(1, Int(dwell / cycleLength))
                    for cycle in 0..<cycles {
                        let start = 0.6 + Double(cycle) * cycleLength
                        DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                            widget.showApplication(bundleID: "com.apple.Music", duration: 0.72)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + start + 1.05) {
                            widget.showAction(.init(key: "button.playPause",
                                                    action: .media(key: "playpause"),
                                                    presentation: nil))
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + start + 2.10) {
                            widget.showAction(.init(key: "button.nextTrack.double",
                                                    action: .media(key: "next"),
                                                    presentation: .init(label: "Next Track",
                                                                        icon: nil)))
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + start + 3.15) {
                            widget.showAction(.init(key: "button.menu.triple",
                                                    action: .keystroke(keys: "delete"),
                                                    presentation: .init(label: "Delete",
                                                                        icon: "delete.left.fill")))
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + start + 4.20) {
                            let began = CACurrentMediaTime()
                            widget.beginHold(
                                startedAt: began,
                                base: (key: "button.playPause",
                                       action: .media(key: "playpause"), presentation: nil),
                                stages: [
                                    (threshold: 0.5, key: "button.playPause.hold",
                                     action: .media(key: "next"),
                                     presentation: .init(label: "Next Track", icon: nil),
                                     isCancel: false),
                                    (threshold: 0.95, key: "button.playPause.hold2",
                                     action: .launch(app: "Music", url: nil),
                                     presentation: nil, isCancel: false),
                                ]
                            )
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.12) {
                                widget.endHold(firedIndex: 2)
                            }
                        }
                    }
                case "symbol-effects":
                    // Input-free full action-symbol audit. The list intentionally covers every
                    // semantic family used by the shipped/default config rather than treating
                    // volume and brightness as special demos. Nothing here emits a system action.
                    let events: [(key: String, action: Action)] = [
                        ("button.volumeUp", .media(key: "volup")),
                        ("button.volumeDown", .media(key: "voldown")),
                        ("button.mute", .media(key: "mute")),
                        ("button.brightnessUp", .brightnessStep(direction: 1)),
                        ("button.brightnessDown", .brightnessStep(direction: -1)),
                        ("button.nextTrack", .media(key: "next")),
                        ("button.previousTrack", .media(key: "previous")),
                        ("button.playPause", .media(key: "playpause")),
                        ("button.menu", .keystroke(keys: "delete")),
                        ("ring.left", .keystroke(keys: "left")),
                        ("ring.right", .keystroke(keys: "right")),
                        ("ring.up", .keystroke(keys: "up")),
                        ("ring.down", .keystroke(keys: "down")),
                        ("copy", .keystroke(keys: "cmd+c")),
                        ("paste", .keystroke(keys: "cmd+v")),
                        ("cut", .keystroke(keys: "cmd+x")),
                        ("spotlight", .keystroke(keys: "cmd+space")),
                        ("fullscreen", .fullscreen),
                        ("minimise", .minimize),
                        ("pointer", .mouse(op: "move")),
                        ("click", .mouse(op: "click")),
                        ("scroll", .mouse(op: "scroll")),
                        ("sleep", .shell(command: "pmset sleepnow")),
                        ("appWheel", .appWheel),
                        ("close", .closeWindow),
                    ]
                    let interval: TimeInterval = slowVisualQC ? 1.10 : 0.44
                    let transitions = max(1, Int((dwell - 0.6) / interval))
                    for index in 0..<transitions {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6
                                                      + Double(index) * interval) {
                            if index > 0, index % (events.count + 1) == events.count {
                                let layerBeat = index / (events.count + 1)
                                widget.setLayer(layerBeat.isMultiple(of: 2) ? "L1" : nil)
                            } else {
                                let event = events[index % events.count]
                                widget.showAction(.init(key: event.key,
                                                        action: event.action,
                                                        presentation: nil),
                                                  durationOverride: slowVisualQC ? 1.0 : 0.56)
                            }
                        }
                    }
                case "app-wheel-wave":
                    // Production-faithful TV hold: progress starts at 180 ms, while App Wheel
                    // becomes the selected release action at the real 500 ms threshold. This
                    // exercises `presentHold`, not a synthetic direct icon replacement.
                    let interval: TimeInterval = slowVisualQC ? 1.8 : 1.35
                    let cycles = max(1, Int((dwell - 0.5) / interval))
                    for cycle in 0..<cycles {
                        let start = 0.45 + Double(cycle) * interval
                        DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                            let began = CACurrentMediaTime()
                            widget.beginHold(
                                startedAt: began,
                                base: (key: "button.tv", action: .layerCycle,
                                       presentation: nil),
                                stages: [
                                    (threshold: 0.5, key: "button.tv.hold",
                                     action: .appWheel,
                                     presentation: .init(label: "App Wheel",
                                                         icon: "circle.grid.3x3.fill"),
                                     isCancel: false),
                                ]
                            )
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.92) {
                                widget.endHold(firedIndex: 1)
                            }
                        }
                    }
                case "mute-state-cycle":
                    // Deterministic speaker ↔ speaker.slash audit. Overrides prevent this visual
                    // test from reading or changing the machine's actual output state.
                    let cycleLength: TimeInterval = 2.25
                    let cycles = max(1, Int((dwell - 0.4) / cycleLength))
                    for cycle in 0..<cycles {
                        let start = 0.45 + Double(cycle) * cycleLength
                        let showMuteState: (TimeInterval, Bool) -> Void = { offset, muted in
                            DispatchQueue.main.asyncAfter(deadline: .now() + start + offset) {
                                widget.showAction(
                                    .init(key: "button.mute", action: .media(key: "mute"),
                                          presentation: .init(label: "Mute",
                                                              icon: "speaker.slash.fill")),
                                    durationOverride: 1.10,
                                    controlStateOverride: .init(kind: .volume,
                                                                value: muted ? 0 : 0.58,
                                                                isMuted: muted)
                                )
                            }
                        }
                        showMuteState(0, false)
                        showMuteState(0.58, true)
                        showMuteState(1.25, false)
                    }
                case "interruption-cycle":
                    // Input-free stress loop for animation continuity. Deterministic overrides
                    // exercise the exact production variable-value path without changing the
                    // machine's real volume/brightness. Each burst must visibly track state while
                    // remaining one stable presentation, then unrelated actions test interruption.
                    let cycleLength: TimeInterval = 6.2
                    let cycles = max(1, Int(dwell / cycleLength))
                    for cycle in 0..<cycles {
                        let start = 0.55 + Double(cycle) * cycleLength
                        for tick in 0..<10 {
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + start + Double(tick) * 0.11
                            ) {
                                widget.showAction(.init(key: "button.volumeUp",
                                                        action: .media(key: "volup"),
                                                        presentation: nil),
                                                  durationOverride: 0.62,
                                                  controlStateOverride: .init(
                                                    kind: .volume,
                                                    value: 0.12 + Double(tick) * 0.075
                                                  ))
                            }
                        }
                        for tick in 0..<6 {
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + start + 1.10 + Double(tick) * 0.11
                            ) {
                                widget.showAction(.init(key: "button.volumeDown",
                                                        action: .media(key: "voldown"),
                                                        presentation: nil),
                                                  durationOverride: 0.62,
                                                  controlStateOverride: .init(
                                                    kind: .volume,
                                                    value: 0.80 - Double(tick) * 0.12
                                                  ))
                            }
                        }
                        for tick in 0..<7 {
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + start + 2.05 + Double(tick) * 0.11
                            ) {
                                widget.showAction(.init(key: "button.brightnessUp",
                                                        action: .brightnessStep(direction: 1),
                                                        presentation: nil),
                                                  durationOverride: 0.62,
                                                  controlStateOverride: .init(
                                                    kind: .brightness,
                                                    value: 0.14 + Double(tick) * 0.13
                                                  ))
                            }
                        }
                        let mixed: [(TimeInterval, String, Action)] = [
                            (3.25, "button.playPause", .media(key: "playpause")),
                            (3.41, "button.menu", .keystroke(keys: "delete")),
                            (3.57, "button.nextTrack", .media(key: "next")),
                        ]
                        for event in mixed {
                            DispatchQueue.main.asyncAfter(deadline: .now() + start + event.0) {
                                widget.showAction(.init(key: event.1, action: event.2,
                                                        presentation: nil),
                                                  durationOverride: 0.64)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + start + 4.65) {
                            widget.setLayer(cycle.isMultiple(of: 2) ? "L1" : nil)
                        }
                    }
                case "connection-cycle":
                    let interval: TimeInterval = 2.2
                    let cycles = max(1, Int(dwell / interval))
                    for cycle in 0..<cycles {
                        let start = 0.7 + Double(cycle) * interval
                        DispatchQueue.main.asyncAfter(deadline: .now() + start) {
                            widget.setConnected(false)
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + start + 0.72) {
                            widget.setConnected(true)
                        }
                    }
                case "return-cycle":
                    // Isolated Back-button causality check. This preview does not emit the
                    // keystroke; it only exercises the status surface and its idle return.
                    let interval: TimeInterval = 1.55
                    let cycles = max(1, Int(dwell / interval))
                    for cycle in 0..<cycles {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65
                                                      + Double(cycle) * interval) {
                            widget.showAction(.init(
                                key: "button.menu",
                                action: .keystroke(keys: "delete"),
                                presentation: .init(label: "Backspace",
                                                    icon: "delete.left.fill")
                            ), durationOverride: 0.62)
                        }
                    }
                default:
                    break
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + dwell + 1.0) { exit(0) }
                return
            }
            // Deliberately spacious beats: tool-driven screenshots have to survive permission/UI
            // round trips, while the real widget's per-action dwell remains sub-second.
            DispatchQueue.main.asyncAfter(deadline: .now() + beat) {
                widget.showApplication(bundleID: "com.apple.Music",
                                       duration: slowVisualQC ? beat * 0.8 : 0.90)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + beat * 2) {
                widget.showAction(.init(key: "button.nextTrack.double",
                                        action: .media(key: "next"),
                                        presentation: .init(label: "Next Track", icon: nil)),
                                  durationOverride: slowVisualQC ? beat * 0.8 : nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + beat * 3) {
                widget.setLayer("L1")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + beat * 4) {
                widget.showAction(.init(key: "button.siri.hold2",
                                        action: .pushToTalk(keys: "rctrl+rcmd+ropt"),
                                        presentation: .init(label: "Voice Input", icon: "waveform")),
                                  durationOverride: slowVisualQC ? beat * 0.8 : nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (slowVisualQC ? 60.0 : 15.2)) { exit(0) }
            return
        }

        // Headless visual QC: `--test-connect-hud` shows the connect/disconnect HUDs so they can be
        // screenshotted, then exits — without seizing the remote or wiring up the rest of the app.
        if CommandLine.arguments.contains("--test-connect-hud")
            || CommandLine.arguments.contains("--test-connect-hud-long") {
            NSApp.setActivationPolicy(.accessory)
            let interval: TimeInterval = CommandLine.arguments.contains("--test-connect-hud-long")
                ? 8.0 : 2.2
            let hud = LayerHUD(holdDuration: interval + 0.55)
            layerHUD = hud
            hud.showRemoteConnected()
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                hud.showRemoteDisconnected()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * 2 + 0.5) { exit(0) }
            return
        }

        // Headless visual QC for Select's exact timing contract: the water vessel appears at the
        // 0.18 s visual lead-in and rises toward the unchanged 0.5 s sticky-drag boundary. This
        // path creates only the HUD; it never starts HID detection or emits a mouse event.
        if CommandLine.arguments.contains("--test-select-hold-hud") {
            NSApp.setActivationPolicy(.accessory)
            let hud = HoldProgressHUD()
            holdHUD = hud
            hud.prewarm()
            func face(_ action: Action, _ presentation: Config.Presentation) -> HoldProgressHUD.Face {
                let visual = ActionVisual.resolve(action, presentation)
                return .init(label: visual.label, image: visual.image,
                             symbolName: visual.symbolName, iconOnly: visual.iconOnly,
                             tint: visual.tint, symbolCue: visual.symbolCue)
            }
            let click = face(.mouse(op: "click"),
                             .init(label: "Click", icon: "cursorarrow.click"))
            let drag = face(.mouse(op: "click"),
                            .init(label: "Drag", icon: "hand.draw.fill"))
            hud.begin(base: click, stages: [.init(threshold: 0.5, face: drag)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { hud.end(firedIndex: 1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { exit(0) }
            return
        }

        // Headless visual QC for the TV-button App Wheel stage in the large water HUD. This keeps
        // the production 0.5 s action boundary and confirms shortly afterwards, exercising both
        // the nine-dot entrance and the rule that release must not replay it. No launcher opens and
        // no input event is emitted.
        if CommandLine.arguments.contains("--test-app-wheel-hold-hud") {
            NSApp.setActivationPolicy(.accessory)
            let hud = HoldProgressHUD()
            holdHUD = hud
            hud.prewarm()
            func face(_ action: Action, _ presentation: Config.Presentation?) -> HoldProgressHUD.Face {
                let visual = ActionVisual.resolve(action, presentation)
                return .init(label: visual.label, image: visual.image,
                             symbolName: visual.symbolName, iconOnly: visual.iconOnly,
                             tint: visual.tint, symbolCue: visual.symbolCue)
            }
            let layer = face(.layerCycle,
                             .init(label: "Next Layer", icon: "square.stack.3d.up.fill"))
            let appWheel = face(.appWheel,
                                .init(label: "App Wheel", icon: "circle.grid.3x3.fill"))
            hud.begin(base: layer, stages: [.init(threshold: 0.5, face: appWheel)])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.84) { hud.end(firedIndex: 1) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.45) { exit(0) }
            return
        }

        // Headless visual QC for the exact production Back ladder in the large water HUD. Stages
        // are stretched only for capture: Delete must be blue, Close/Quit system red, and Cancel
        // neutral, with native symbol layers replacing one another in place.
        if CommandLine.arguments.contains("--test-back-hold-hud")
            || CommandLine.arguments.contains("--test-back-hold-hud-long") {
            NSApp.setActivationPolicy(.accessory)
            let longCapture = CommandLine.arguments.contains("--test-back-hold-hud-long")
            let segment: TimeInterval = longCapture ? 8.0 : 1.6
            let hud = HoldProgressHUD()
            holdHUD = hud
            hud.prewarm()
            func face(_ action: Action, _ presentation: Config.Presentation?) -> HoldProgressHUD.Face {
                let visual = ActionVisual.resolve(action, presentation)
                return .init(label: visual.label, image: visual.image,
                             symbolName: visual.symbolName, iconOnly: visual.iconOnly,
                             tint: visual.tint, symbolCue: visual.symbolCue)
            }
            let base = face(.keystroke(keys: "delete"),
                            .init(label: "Delete", icon: "delete.left.fill"))
            let close = face(.closeWindow,
                             .init(label: "Close Window", icon: "xmark.circle.fill"))
            let quit = face(
                .applescript(script: "tell application \"System Events\" to set n to name of first application process whose frontmost is true\nif n is not \"HyperVibe\" then tell application n to quit"),
                .init(label: "Quit App", icon: "power")
            )
            var cancel = face(.mouse(op: "click"),
                              .init(label: "Cancel", icon: "arrow.uturn.backward.circle.fill"))
            cancel.isCancel = true
            hud.begin(base: base, stages: [
                .init(threshold: segment, face: close),
                .init(threshold: segment * 2, face: quit),
                .init(threshold: segment * 3, face: cancel),
            ])
            DispatchQueue.main.asyncAfter(deadline: .now() + segment * 3 + 0.7) {
                hud.end(firedIndex: 3)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + segment * 3 + 1.9) { exit(0) }
            return
        }

        // Headless visual QC: `--test-hold-hud` runs a hold from 0 through every stage so the
        // progress card can be screenshotted, then exits — without seizing the remote. Uses real
        // actions so the icon resolution (app icons vs SF Symbols) is exercised too.
        if CommandLine.arguments.contains("--test-hold-hud") {
            NSApp.setActivationPolicy(.accessory)
            let hud = HoldProgressHUD()
            holdHUD = hud
            hud.prewarm()
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
                return .init(label: v.label, image: v.image, symbolName: v.symbolName,
                             iconOnly: v.iconOnly, tint: v.tint, symbolCue: v.symbolCue)
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
        startPermissionHealthMonitoring()
        
        // Initialize controllers
        let cursorController = CursorController()

        remoteInputHandler = RemoteInputHandler(
            cursorController: cursorController,
            menuBarManager: menuBarManager
        )

        // --- Config engine (SiriRemoteCore): config bindings override native button behavior;
        //     unbound buttons fall through to HyperVibe's native mapping. ---
        let config = ConfigStore.loadConfig()
        SystemControlState.prewarm()

        let persistentStatus = StatusWidgetController(
            layers: config.settings.layers,
            icons: config.settings.icons,
            enabled: config.settings.statusWidgetEnabled
        )
        statusWidget = persistentStatus
        let pipelineHUD = VoicePipelineHUDController(
            layers: config.settings.layers,
            icons: config.settings.icons,
            enabled: config.settings.dictation.pipelineOverlayEnabled
        )
        voicePipelineHUD = pipelineHUD

        // Tuning: config.jsonc's `settings` block is the source of truth — always seed from it (a
        // stale saved tune no longer shadows config edits), and re-seed on every hot-reload below.
        let model = SettingsModel(initial: TuneSettings(seed: config.settings))
        let dictation = VoiceDictationCoordinator(runtime: model.voiceRuntime)
        voiceDictation = dictation
        let voiceFeedback = VoiceFeedbackSound()
        voiceFeedbackSound = voiceFeedback
        prepareVoiceDictionary(config.settings.dictation.dictionary)
        dictation.configureHistoryProfiles(config.appProfiles)
        dictation.configure(
            config.settings.dictation,
            prewarmModes: config.settings.dictation.outputModesToPrewarm(
                layerIDs: config.settings.layers.map(\.id)
            )
        )
        model.voiceCredentials.onCredentialsChanged = { [weak self, weak model] in
            guard let self, let model else { return }
            let settings = model.tune.dictation
            let layerIDs = model.config?.settings.layers.map(\.id) ?? []
            self.configureVoiceImmediately(settings, layerIDs: layerIDs,
                                           forceReconnect: true)
        }
        model.voiceCredentials.preload()
        model.onApply = { [weak self, weak model] tune in
            self?.applyTune(tune)
            model?.noteConfigSavePending(from: .tuning)
            self?.scheduleTunePersist()   // write slider values back into config.jsonc (debounced)
        }
        model.config = config   // publish the live config to the Settings "Layout" tab
        let updates = UpdateManager()
        updateManager = updates
        model.onCheckForUpdates = { [weak updates] in updates?.checkForUpdates() }
        updates.onUpdateAvailable = { [weak model, weak menuBar = menuBarManager] version in
            model?.availableUpdateVersion = version
            menuBar?.setAvailableUpdate(version: version)
        }
        updates.onUpdateCleared = { [weak model, weak menuBar = menuBarManager] in
            model?.availableUpdateVersion = nil
            menuBar?.setAvailableUpdate(version: nil)
        }
        // Install every callback before starting: a cached/local feed can complete on the next
        // run-loop turn, and the very first gentle reminder must not race past the UI observers.
        updates.start(
            automaticChecks: model.tune.automaticUpdateChecksEnabled,
            automaticDownloads: model.tune.automaticallyDownloadUpdatesEnabled
        )
        settingsModel = model
        let settingsWin = SettingsWindowController(model: model)
        settingsWindow = settingsWin
        menuBarManager.onOpenSettings = { [weak settingsWin] in settingsWin?.show() }
        menuBarManager.onOpenSetup = { [weak self] in self?.showSetupWizard() }
        menuBarManager.onCheckForUpdates = { [weak updates] in updates?.checkForUpdates() }

        // Demo Mode is a passive surface inside this process. Its button state comes from the
        // already-deduplicated HID edges and its touch point comes from the existing multitouch
        // stream; normal actions continue through their unchanged paths underneath it.
        let demoWindow = DemoModeWindowController()
        demoModeWindow = demoWindow
        demoWindow.onVisibilityChanged = { [weak self] visible in
            self?.menuBarManager.updateDemoModeVisibility(visible)
            self?.refreshRawTouchObserver()
        }
        demoWindow.onEnabledChangeRequested = { [weak self] enabled in
            self?.setDemoRemoteEnabled(enabled)
        }
        menuBarManager.onToggleDemoMode = { [weak self, weak demoWindow] in
            self?.setDemoRemoteEnabled(!(demoWindow?.isVisible ?? false))
        }
        remoteInputHandler?.onPhysicalButtonStateChanged = { [weak demoWindow] rawName, pressed in
            demoWindow?.setPhysicalButton(rawName, pressed: pressed)
        }
        remoteInputHandler?.onPhysicalButtonStateReset = { [weak demoWindow] in
            demoWindow?.resetPhysicalButtons()
        }
        // Convenience: `./HyperVibe --settings` pops the window open immediately.
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { settingsWin.show() }
        }
        if CommandLine.arguments.contains("--system-check") {
            DispatchQueue.main.async { [weak self] in self?.showSetupWizard() }
        }

        // First launch — or a later permission revocation: open the live system check. A config can
        // disable automatic presentation, but the warning remains visible in the menu bar and the
        // same surface can always be reopened manually.
        let launchReadiness = SystemReadiness.snapshot()
        if model.tune.showSetupWizardOnFirstLaunch,
           (!UserDefaults.standard.bool(forKey: SetupWizardController.completedKey)
            || !launchReadiness.corePermissionsGranted) {
            DispatchQueue.main.async { [weak self] in self?.showSetupWizard() }
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
        engineController.onActionHandled = { [weak persistentStatus] handled in
            persistentStatus?.showAction(handled)
        }
        appWatcher = AppWatcher { [weak engineController, weak persistentStatus] bundleID in
            rmDebug("🎯 frontmost app → \(bundleID)")
            engineController?.frontmostAppChanged(bundleID: bundleID)
            persistentStatus?.showApplication(bundleID: bundleID)
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
            self?.layerHUD?.configure(layers: reloaded.settings.layers,
                                      icons: reloaded.settings.icons)
            self?.statusWidget?.configure(layers: reloaded.settings.layers,
                                          icons: reloaded.settings.icons,
                                          enabled: reloaded.settings.statusWidgetEnabled)
            self?.voicePipelineHUD?.configure(
                layers: reloaded.settings.layers,
                icons: reloaded.settings.icons,
                enabled: reloaded.settings.dictation.pipelineOverlayEnabled
            )
            self?.voiceDictation?.configureHistoryProfiles(reloaded.appProfiles)
            // Live-tune: re-seed from genuine external edits, but never let the watcher for an
            // earlier GUI save overwrite a newer debounced choice. Without this arbitration a
            // quick External -> Final switch could show the Final confirmation, then route the
            // next Side hold through External and open no Voice capsule at all.
            let reloadedTune = TuneSettings(seed: reloaded.settings)
            if self?.settingsModel?.shouldAcceptTuneReload(reloadedTune) != false {
                self?.settingsModel?.tune = reloadedTune
                self?.configureVoiceImmediately(
                    reloaded.settings.dictation,
                    layerIDs: reloaded.settings.layers.map(\.id)
                )
            } else {
                print("♻️ ignored stale tuning reload while a newer GUI save is pending")
            }
            print("♻️ siriRemote config reloaded")
        }
        print("🧩 siriRemote config engine active — \(ConfigStore.path.path)")

        // Start touch handler for trackpad (before remote detection so we can wire the callback)
        let touch = TouchHandler(cursorController: cursorController)
        touchHandler = touch
        touch.scrollScale = menuBarManager.scrollSpeed.scale
        // The outer-ring gesture is vertical in the base layer and horizontal in Layer 1. Listen to
        // Controller rather than only the sticky-layer HUD callback so momentary L1 holds work too.
        engineController.onLayerChanged = {
            [weak touch, weak persistentStatus, weak pipelineHUD] layer in
            touch?.circularScrollAxis = layer == "L1" ? .horizontal : .vertical
            persistentStatus?.setLayer(layer)
            pipelineHUD?.setLayer(layer)
        }
        touch.onSwipe = { [weak self] direction in
            // Swipes are config-driven only. An unbound swipe does nothing — no native fallback,
            // so HyperVibe's Claude-Code default swipe keys (e.g. right = Shift+Tab) no longer
            // fire and cause the system beep. Bind swipe.<dir> in the config to use them.
            self?.remoteInputHandler?.noteLayerUsedByOtherInput()   // swipe while holding a layer = use
            let key = "swipe.\(direction.rawValue)"
            if self?.controller?.handle(InputEvent(key: key)) == true {
                print("👆 \(key) (config)")
            }
        }
        touch.onTwoFingerTap = { [weak self] in
            // Config-driven only: unbound two-finger tap does nothing. Bind tap.two to use it.
            self?.remoteInputHandler?.noteLayerUsedByOtherInput()
            if self?.controller?.handle(InputEvent(key: "tap.two")) == true {
                print("👐 tap.two (config)")
            }
        }
        // Find-my-cursor: a cursor shake flashes a highlight. Gated on the enabled setting
        // (`findCursorEnabled`, kept in sync by applyTune) so it can be toggled live.
        // Layer HUD: show a macOS-style overlay when a sticky layer toggles on/off.
        let hud = LayerHUD(layers: config.settings.layers, icons: config.settings.icons)
        layerHUD = hud
        remoteInputHandler?.onLayerToggle = { [weak self, weak hud] on, name in
            guard self?.layerHUDEnabled == true else { return }
            on ? hud?.showOn(name) : hud?.showOff(name)
        }

        // Release-to-select needs to be visible: a track that fills while a button is held, with a
        // tick per bound stage and the name of the action that runs if it is released right now.
        let progress = HoldProgressHUD()
        holdHUD = progress
        progress.prewarm()
        remoteInputHandler?.onHoldBegan = { [weak self, weak persistentStatus] startedAt, base, stages in
            persistentStatus?.beginHold(startedAt: startedAt, base: base, stages: stages)
            guard self?.holdHUDEnabled == true else { return }
            func face(_ action: Action, _ p: Config.Presentation?) -> HoldProgressHUD.Face {
                let v = ActionVisual.resolve(action, p)
                return .init(label: v.label, image: v.image, symbolName: v.symbolName,
                             iconOnly: v.iconOnly, tint: v.tint, symbolCue: v.symbolCue)
            }
            progress.begin(startedAt: startedAt,
                           base: base.map { face($0.action, $0.presentation) },
                           stages: stages.map {
                               var f = face($0.action, $0.presentation)
                               f.isCancel = $0.isCancel
                               return .init(threshold: $0.threshold, face: f)
                           })
        }
        remoteInputHandler?.onHoldEnded = { [weak persistentStatus] firedIndex in
            // `end` is safe even when the large HUD was disabled; calling it unconditionally also
            // dismisses a HUD immediately if the user switches that preference off mid-hold.
            progress.end(firedIndex: firedIndex)
            persistentStatus?.endHold(firedIndex: firedIndex)
        }
        remoteInputHandler?.onContinuousActionBegan = { [weak self, weak persistentStatus] handled in
            if case .pushToTalk = handled.action {
                self?.builtinMicFeeder?.setVoiceMetering(true)
            }
            persistentStatus?.beginContinuousAction(handled)
        }
        remoteInputHandler?.onContinuousActionEnded = { [weak self, weak persistentStatus] key in
            self?.builtinMicFeeder?.setVoiceMetering(false)
            persistentStatus?.endContinuousAction(key: key)
        }
        // Native dictation starts its expensive work on the raw press edge. The handler still owns
        // tap/hold disambiguation, so a quick side-button tap never flashes Voice or inserts audio.
        remoteInputHandler?.shouldUseNativeDictation = { [weak model] in
            guard let settings = model?.tune.dictation else { return false }
            return settings.resolvedOutputMode(for: nil) != nil
        }
        remoteInputHandler?.onNativeDictationPrimed = {
            [weak dictation, weak model] handled in
            guard let settings = model?.tune.dictation.resolvedSettings(for: nil)
            else { return .unavailable }
            return dictation?.prime(handled, settings: settings) ?? .unavailable
        }
        remoteInputHandler?.onNativeDictationBegan = { [weak dictation] in
            dictation?.beginListening()
        }
        remoteInputHandler?.onNativeDictationCancelled = { [weak dictation] in
            dictation?.cancelPrime()
        }
        remoteInputHandler?.onNativeDictationEnded = { [weak dictation] in
            dictation?.finishListening()
        }
        remoteInputHandler?.onNativeDictationMisconfigured = { [weak dictation] in
            dictation?.reportConfigurationError(VoiceAPIError.missingOpenAIKeyMessage)
        }
        remoteInputHandler?.shouldCopyLastNativeDictationOnDouble = { [weak model] in
            guard let settings = model?.tune.dictation else { return false }
            return settings.copyLastOnSideButtonDouble
                && settings.resolvedOutputMode(for: nil) != nil
        }
        remoteInputHandler?.onCopyLastNativeDictation = { [weak dictation] in
            dictation?.copyLastTranscript() == true
        }
        remoteInputHandler?.shouldUseVoiceModeCycleChord = { [weak model] in
            model?.tune.dictation.enabled == true
        }
        remoteInputHandler?.onVoiceModeCycleRequested = {
            [weak self, weak model, weak persistentStatus, weak pipelineHUD] in
            guard let self, let model else { return }
            var tune = model.tune
            let next = tune.dictation.activeMode.next
            tune.dictation.selectMode(next)
            model.tune = tune

            // Input ownership and visuals change on the same physical down edge. Voice sessions
            // are configured immediately rather than waiting for the debounced JSON save, while
            // both native transports remain warm for the next hold.
            self.configureVoiceImmediately(tune.dictation, layerIDs: [])
            persistentStatus?.showVoiceModeSwitch(next)
            pipelineHUD?.showVoiceModeSwitch(next)
            print("🎙 Voice mode → \(next.rawValue) (Mute + Side)")
        }
        dictation.onMeteringChanged = { [weak self] active in
            self?.builtinMicFeeder?.setVoiceMetering(active)
        }
        dictation.onListeningBegan = {
            [weak persistentStatus, weak pipelineHUD, weak model, weak voiceFeedback] handled in
            persistentStatus?.beginContinuousAction(handled)
            pipelineHUD?.beginListening()
            guard let settings = model?.tune.dictation,
                  settings.feedbackSoundsEnabled else { return }
            // The cue is deliberately audible to the user but must not inflate the on-screen
            // waveform. Audio capture independently excludes the same acoustic window from the
            // transcription stream, so both the visual and model input describe the speaker.
            persistentStatus?.suppressVoiceMeter(for: VoiceFeedbackSound.acousticExclusionDuration)
            pipelineHUD?.suppressMeter(for: VoiceFeedbackSound.acousticExclusionDuration)
            voiceFeedback?.play(.began, volume: settings.feedbackSoundVolume)
        }
        dictation.onSelectionEditingBegan = { [weak persistentStatus, weak pipelineHUD]
            characterCount, applicationName in
            persistentStatus?.showSelectionEditing(characterCount: characterCount,
                                                   applicationName: applicationName)
            pipelineHUD?.showSelectionEditing(characterCount: characterCount,
                                              applicationName: applicationName)
        }
        dictation.onListeningEnded = { [weak persistentStatus, weak pipelineHUD] key in
            persistentStatus?.endNativeContinuousAction(key: key)
            pipelineHUD?.endListening()
        }
        dictation.onShortCaptureDiscarded = { [weak pipelineHUD] in
            pipelineHUD?.dismissShortCapture()
        }
        dictation.onCaptureStopped = { [weak model, weak voiceFeedback] in
            guard let settings = model?.tune.dictation,
                  settings.feedbackSoundsEnabled else { return }
            voiceFeedback?.play(.ended, volume: settings.feedbackSoundVolume)
        }
        dictation.onPhaseChanged = { [weak persistentStatus, weak pipelineHUD] phase, message in
            persistentStatus?.showNativeDictationPhase(phase, message: message)
            pipelineHUD?.showNativeDictationPhase(phase, message: message)
        }

        let dragBadge = DragIndicator()
        dragIndicator = dragBadge
        remoteInputHandler?.onStickyDrag = { [weak self, weak dragBadge] on in
            guard self?.dragIndicatorEnabled == true else {
                dragBadge?.hide()
                return
            }
            on ? dragBadge?.show() : dragBadge?.hide()
        }

        // `--touch-monitor`: open the live view alongside normal operation, so the remote keeps
        // working while its raw data is on screen. Read-only; it only observes.
        if CommandLine.arguments.contains("--touch-monitor") {
            let monitor = TouchMonitorWindowController()
            touchMonitor = monitor
            if let size = touchHandler?.surfaceDimensions { monitor.model.surface = size }
            refreshRawTouchObserver()
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
        // Explicit developer/demo launch is a one-run visibility override. Ordinary launch,
        // menu-bar control, Settings and hot reload all use settings.demoRemoteEnabled.
        if CommandLine.arguments.contains("--demo-mode") {
            DispatchQueue.main.async { [weak demoWindow] in demoWindow?.show() }
        }
        remoteInputHandler?.onButtonActivity = { [weak self] in
            self?.touchHandler?.tryReconnectTrackpad()
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector { [weak self] event in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let connected = event.isConnected
                switch event {
                case let .added(device, _):
                    self.remoteInputHandler?.setRemoteDevice(device)
                case let .removed(device, _):
                    self.remoteInputHandler?.removeRemoteDevice(device)
                case .reset:
                    self.remoteInputHandler?.setRemoteDevice(nil)
                }
                self.menuBarManager.updateConnectionStatus(connected: connected)
                self.settingsModel?.connected = connected
                self.demoModeWindow?.setConnected(connected)
                RemoteConnection.shared.update(connected)

                // HUD only on an actual transition. The remote publishes several HID interfaces and
                // this callback can run more than once per physical connect, which would otherwise
                // stack up identical "Connected" cards.
                if self.lastConnectedState != connected {
                    self.lastConnectedState = connected
                    if self.layerHUDEnabled {
                        connected ? self.layerHUD?.showRemoteConnected()
                                  : self.layerHUD?.showRemoteDisconnected()
                    }
                    // The always-on status widget rests on a "not connected" face and plays a
                    // brief connect animation on the connect edge (setConnected de-duplicates the
                    // several per-interface callbacks internally).
                    self.statusWidget?.setConnected(connected)

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
        
        // Virtual-mic fallback (Phase 2b): keep the "Siri Remote Mic" device fed with the
        // Mac's BUILT-IN microphone whenever the virtual device needs fallback audio. The same
        // pinned AUHAL briefly supplies a real level meter while Voice is physically held; no
        // second/default-input capture path is opened, so the virtual mic cannot feed back.
        let micFeeder = BuiltinMicFeeder()
        micFeeder.setMeterLevelHandler { [weak persistentStatus, weak pipelineHUD] sample in
            persistentStatus?.updateVoiceMeter(sample)
            pipelineHUD?.updateVoiceMeter(sample)
        }
        builtinMicFeeder = micFeeder
        micFeeder.start()
        if config.settings.dictation.enabled { micFeeder.prepareVoiceCapture() }

        // Start media key interceptor
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType)
        }
        mediaKeyInterceptor?.start()
    }

    /// Raw touch snapshots cost an allocation and a main-thread publication per frame. Keep that
    /// diagnostic/presentation tap completely detached during ordinary remote use, and multiplex it
    /// only while one of the two live visual surfaces actually needs it.
    private func refreshRawTouchObserver() {
        guard let touchHandler = touchHandler else { return }
        let demoVisible = demoModeWindow?.isVisible == true
        let monitorPresent = touchMonitor != nil
        guard demoVisible || monitorPresent else {
            touchHandler.onRawTouch = nil
            return
        }

        touchHandler.onRawTouch = { [weak self] snapshots in
            guard let self = self else { return }
            self.touchMonitor?.model.ingest(snapshots)
            if self.demoModeWindow?.isVisible == true {
                self.demoModeWindow?.ingest(snapshots)
            }
        }
    }
    
    /// Push cursor-feel settings from config into the touch handler (also called on hot reload).
    /// Push UI tuning values into the running touch handler (initial + on every settings change).
    private func applyTune(_ t: TuneSettings) {
        prepareVoiceDictionary(t.dictation.dictionary)
        if t.dictation.enabled { builtinMicFeeder?.prepareVoiceCapture() }
        // Settings callbacks are intentionally plain closures, while the latency state machine is
        // main-actor isolated. Hop explicitly instead of weakening its isolation guarantees.
        let dictationSettings = t.dictation
        let layerIDs = settingsModel?.config?.settings.layers.map(\.id) ?? []
        scheduleVoiceConfigure(dictationSettings, layerIDs: layerIDs)
        touchHandler?.cursorSpeed = CGFloat(t.cursorSpeed)
        touchHandler?.cursorDeadzone = CGFloat(t.cursorDeadzone)
        touchHandler?.accelMin = CGFloat(t.accelMin)
        touchHandler?.accelMax = CGFloat(t.accelMax)
        touchHandler?.accelLowSpeed = CGFloat(t.accelLowSpeed)
        touchHandler?.accelHighSpeed = CGFloat(t.accelHighSpeed)
        touchHandler?.accelCurve = CGFloat(t.accelCurve)
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
        Loc.shared.apply(configValue: t.interfaceLanguage)
        // Visual-QC only: render the installed App in another supported language without writing
        // the user's config.jsonc or legacy defaults. Production launches never pass this flag.
        if let languageIndex = CommandLine.arguments.firstIndex(of: "--test-interface-language"),
           languageIndex + 1 < CommandLine.arguments.count,
           let language = AppLanguage(rawValue: CommandLine.arguments[languageIndex + 1]) {
            Loc.shared.choose(language)
        }
        let automaticUpdateChecks = t.automaticUpdateChecksEnabled
        let automaticUpdateDownloads = t.automaticallyDownloadUpdatesEnabled
        Task { @MainActor [weak updateManager] in
            updateManager?.apply(
                automaticChecks: automaticUpdateChecks,
                automaticDownloads: automaticUpdateDownloads
            )
        }
        statusItem?.isVisible = t.menuBarIconEnabled
        statusWidget?.setEnabled(t.statusWidgetEnabled)
        voicePipelineHUD?.setEnabled(t.dictation.pipelineOverlayEnabled)
        demoModeWindow?.setVisible(t.demoRemoteEnabled)
        let wasShowingLayerHUD = layerHUDEnabled
        layerHUDEnabled = t.layerHUDEnabled
        if wasShowingLayerHUD, !t.layerHUDEnabled { layerHUD?.hideImmediately() }
        let wasShowingHoldHUD = holdHUDEnabled
        holdHUDEnabled = t.holdHUDEnabled
        if wasShowingHoldHUD, !t.holdHUDEnabled { holdHUD?.hideImmediately() }
        let wasShowingDragIndicator = dragIndicatorEnabled
        dragIndicatorEnabled = t.dragIndicatorEnabled
        if wasShowingDragIndicator, !t.dragIndicatorEnabled { dragIndicator?.hideImmediately() }
        focusFollower?.enabled = t.focusFollowsCursor
        if lastLaunchAtLoginRequest != t.launchAtLoginEnabled {
            lastLaunchAtLoginRequest = t.launchAtLoginEnabled
            do {
                try LaunchAtLogin.setEnabled(t.launchAtLoginEnabled)
                settingsModel?.launchAtLoginError = nil
            } catch {
                settingsModel?.launchAtLoginError = error.localizedDescription
                NSLog("[siriRemote] launch-at-login apply failed: \(error)")
            }
        }
    }

    private func prepareVoiceDictionary(_ entries: [Config.DictationTerm]) {
        guard preparedVoiceDictionary != entries else { return }
        preparedVoiceDictionary = entries
        DispatchQueue.global(qos: .userInitiated).async {
            VoiceDictionary.prepare(entries)
        }
    }

    private func scheduleVoiceConfigure(_ settings: Config.DictationSettings,
                                        layerIDs: [String]) {
        voiceConfigureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.voiceConfigureWork = nil
                self.voiceDictation?.configure(
                    settings,
                    prewarmModes: settings.outputModesToPrewarm(layerIDs: layerIDs)
                )
            }
        }
        voiceConfigureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func configureVoiceImmediately(_ settings: Config.DictationSettings,
                                           layerIDs: [String],
                                           forceReconnect: Bool = false) {
        voiceConfigureWork?.cancel()
        voiceConfigureWork = nil
        Task { @MainActor [weak self] in
            self?.voiceDictation?.configure(
                settings,
                prewarmModes: settings.outputModesToPrewarm(layerIDs: layerIDs),
                forceReconnect: forceReconnect
            )
        }
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
            s.accelCurve = t.accelCurve
            s.accelerationCurvesLinked = t.accelerationCurvesLinked
            s.clickRiseThreshold = t.clickRiseThreshold
            s.pressMoveMax = t.pressMoveMax
            s.holdThreshold = t.holdThreshold
            s.holdThreshold2 = t.holdThreshold2
            s.holdThreshold3 = t.holdThreshold3
            s.holdCancelGrace = t.holdCancelGrace
            s.doubleTapWindow = t.doubleTapWindow
            s.spacesModeWindow = t.spacesModeWindow
            s.findCursorEnabled = t.findCursorEnabled
            s.interfaceLanguage = t.interfaceLanguage
            s.launchAtLoginEnabled = t.launchAtLoginEnabled
            s.automaticUpdateChecksEnabled = t.automaticUpdateChecksEnabled
            s.automaticallyDownloadUpdatesEnabled = t.automaticallyDownloadUpdatesEnabled
            s.menuBarIconEnabled = t.menuBarIconEnabled
            s.statusWidgetEnabled = t.statusWidgetEnabled
            s.demoRemoteEnabled = t.demoRemoteEnabled
            s.layerHUDEnabled = t.layerHUDEnabled
            s.holdHUDEnabled = t.holdHUDEnabled
            s.dragIndicatorEnabled = t.dragIndicatorEnabled
            s.showSetupWizardOnFirstLaunch = t.showSetupWizardOnFirstLaunch
            s.focusFollowsCursor = t.focusFollowsCursor
            s.dictation = t.dictation
            s.circularScroll = t.circularConfig
        }
        // No change (e.g. this fire came from a hot-reload re-seed) → don't churn the file.
        guard merged != base else {
            model.noteConfigSaveSucceeded(from: .tuning)
            return
        }
        do {
            try ConfigStore.save(merged)
            // Keep the in-memory base in lockstep with the atomic write. This prevents a Layout
            // edit made before the file watcher callback from being based on stale tuning values.
            model.config = merged
            model.noteConfigSaveSucceeded(from: .tuning)
        } catch {
            model.noteConfigSaveFailed(error, from: .tuning)
            NSLog("[siriRemote] tune persist failed: \(error)")
        }
    }

    /// Menu-bar and in-window context-menu requests travel through the same Settings model as the
    /// SwiftUI toggle. This keeps the live window, GUI and hot-reloaded JSON on one value.
    private func setDemoRemoteEnabled(_ enabled: Bool) {
        guard let model = settingsModel else {
            demoModeWindow?.setVisible(enabled)
            return
        }
        guard model.tune.demoRemoteEnabled != enabled else {
            demoModeWindow?.setVisible(enabled)
            return
        }
        var tune = model.tune
        tune.demoRemoteEnabled = enabled
        model.tune = tune
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
        voiceConfigureWork?.cancel()
        voiceConfigureWork = nil
        voicePipelineHUD?.hideImmediately()
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
        permissionHealthTimer?.invalidate()
        permissionHealthTimer = nil
        if let observer = permissionActivationObserver {
            NotificationCenter.default.removeObserver(observer)
            permissionActivationObserver = nil
        }
        if let observer = openSystemCheckObserver {
            NotificationCenter.default.removeObserver(observer)
            openSystemCheckObserver = nil
        }
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

    private func startPermissionHealthMonitoring() {
        let initial = SystemReadiness.snapshot()
        previousAccessibilityGranted = initial.accessibilityGranted
        previousInputMonitoringGranted = initial.inputMonitoringGranted
        menuBarManager?.updatePermissionStatus(ready: initial.corePermissionsGranted)

        permissionHealthTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            self?.refreshPermissionHealth()
        }
        if let timer = permissionHealthTimer { RunLoop.main.add(timer, forMode: .common) }

        permissionActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.refreshPermissionHealth() }

        openSystemCheckObserver = NotificationCenter.default.addObserver(
            forName: .hyperVibeOpenSystemCheck,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.showSetupWizard() }
    }

    private func refreshPermissionHealth() {
        let current = SystemReadiness.snapshot()
        menuBarManager?.updatePermissionStatus(ready: current.corePermissionsGranted)

        if previousInputMonitoringGranted == false, current.inputMonitoringGranted {
            // A manager opened while Input Monitoring was denied stays unusable. Recreate it as
            // soon as the user returns from System Settings — no app restart required.
            remoteDetector?.stopDetection()
            remoteDetector?.startDetection()
            rmDebug("🔐 Input Monitoring granted — HID detection reattached")
        }
        if previousAccessibilityGranted == false, current.accessibilityGranted {
            // CGEvent taps created before Accessibility was granted are nil. Rebuild only this tap.
            mediaKeyInterceptor?.stop()
            mediaKeyInterceptor?.start()
            rmDebug("🔐 Accessibility granted — media event tap reattached")
        }

        previousAccessibilityGranted = current.accessibilityGranted
        previousInputMonitoringGranted = current.inputMonitoringGranted
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
