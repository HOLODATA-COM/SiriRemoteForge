//
//  RemoteInputHandler.swift
//  HyperVibe
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit
import QuartzCore

/// Per-interface metadata retained for the lifetime of an IOHID raw-report callback.
/// A distinct context is required because the callback's `sender` is an opaque pointer and macOS
/// rewrites several different Siri Remote GATT reports to the same HID report id (0xFF).
private final class MicReportCaptureContext {
    let label: String

    init(interfaceNumber: Int, locationID: Int, usagePage: Int, usage: Int) {
        label = String(format: "interface=%d location=0x%X usage=0x%X/0x%X",
                       interfaceNumber, locationID, usagePage, usage)
    }
}

class RemoteInputHandler {
    private let cursorController: CursorController
    private weak var menuBarManager: MenuBarManager?
    private var devices: [IOHIDDevice] = []

    // --- Mic/voice capture diagnostic (enabled with `--capture-mic`). The 3rd-gen remote streams
    //     its microphone as large HID input reports (the button interface is 3 bytes; there's a
    //     separate interface with a 209-byte input report). This logs raw reports so we can see the
    //     voice data when the Siri button is held. Buffers must outlive the callback registration.
    private let captureMic = CommandLine.arguments.contains("--capture-mic")
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []
    private var reportCaptureContexts: [MicReportCaptureContext] = []

    // --- Mic reverse-engineering diagnostics (off by default) ---
    //  --dump-reports : enumerate every HID element (input/output/feature) with its report id, type,
    //                   size and usage — mapping the remote's whole control surface — and GetReport
    //                   each feature report. Read /tmp/hypervibe.log for `🔎` lines.
    //  --activate-mic : register the raw-report capture (like --capture-mic), then write the `0xAF`
    //                   "enable input" byte to report 0xFF on every virtual interface that exposes
    //                   that Feature report. Gen-3 firmware has Feature (not Output) enable reports.
    //                   The Linux implementation identifies wire report 0xFA as 99-byte Opus;
    //                   macOS splits the GATT reports into interfaces and rewrites them to id 0xFF.
    //  --direct-ptt   : re-arm those Feature reports, then send the Apple driver's hidden one-byte
    //                   report 0x99 for a bounded, automatically released PTT trial.
    private let dumpReports = CommandLine.arguments.contains("--dump-reports")
    private let activateMic = CommandLine.arguments.contains("--activate-mic")
    private let nativePushToTalk = CommandLine.arguments.contains("--native-ptt")
    private let directPushToTalk = CommandLine.arguments.contains("--direct-ptt")

    /// Config engine (SiriRemoteCore). Buttons are routed through it; unbound buttons do nothing.
    var controller: Controller?

    /// Multi-stage long-press — RELEASE-TO-SELECT. If any of `<key>.hold`/`.hold2`/`.hold3` is
    /// bound, a press schedules a timer for each BOUND stage at its threshold (holdThreshold =
    /// stage 1, holdThreshold2 = stage 2, holdThreshold3 = stage 3). When a stage's timer elapses
    /// it only RECORDS that the stage was reached (`deepestStage`) — it does NOT fire. Keep holding
    /// to reach a deeper stage. On RELEASE, the deepest bound stage reached is fired; releasing
    /// before stage 1 fires the normal tap/double instead. HID callbacks run on the main runloop.
    /// (Consequence: a single `.hold` binding now fires on release-after-threshold, not at the
    /// threshold — an intentional trade of the multi-stage model.)
    var holdThreshold: TimeInterval = 0.5
    var holdThreshold2: TimeInterval = 1.0
    var holdThreshold3: TimeInterval = 1.6
    /// Seconds after the DEEPEST BOUND stage past which releasing fires nothing — the escape hatch
    /// for a hold started by mistake. 0 disables it.
    ///
    /// Only reaches keys that actually have hold bindings: it is armed inside the same branch as
    /// the stage timers, and `.repeatKey` keys return long before that. A key whose hold means
    /// "repeat" (Back in a terminal) therefore never cancels, which is right — there is nothing
    /// pending to take back, the repeats already happened.
    var holdCancelGrace: TimeInterval = 1.0
    private var holdCancelled: Set<String> = []
    private var holdCancelWork: [String: DispatchWorkItem] = [:]
    private var holdStageTimers: [String: [DispatchWorkItem]] = [:]

    /// One armed hold stage: which binding it fires and when. Ordered by `delay`, NOT by the `.hold`
    /// / `.hold2` / `.hold3` suffix — with per-binding `after` overrides a key may perfectly well
    /// give `.hold3` an earlier delay than `.hold`, and the suffix is then just a name.
    private struct ArmedStage {
        let key: String
        let delay: TimeInterval
    }
    /// The stages armed for the press in progress, sorted by delay.
    private var armedStages: [String: [ArmedStage]] = [:]
    /// Index into `armedStages` of the DEEPEST stage reached. Timers fire in time order, so the last
    /// one to write wins — no max() over stage numbers, which stopped meaning "latest" the moment
    /// delays became per-binding.
    private var deepestStage: [String: Int] = [:]

    /// Layer key (Feature: LAYER). A `.layer` binding gives its button BOTH activation styles:
    ///   • HOLD it and press other keys → momentary (the layer is active only while held).
    ///   • TAP it (press+release with no other key in between) → TOGGLE a *sticky* layer that
    ///     persists until you tap the key again.
    /// Permissive-hold: on press we engage the layer immediately (so momentary has ZERO latency),
    /// and on release we decide tap-vs-hold from `layerUsed` (whether another key was pressed during
    /// the hold). `stickyLayer` survives button releases; a momentary hold temporarily overrides it
    /// and reverts to it on release. A newer layer press overwrites the held-button tracking.
    private var layerButton: String?     // HID button currently held as a layer key
    private var layerName: String?       // the layer that button engaged
    private var layerUsed = false        // another key was pressed during this hold → momentary use
    private var stickyLayer: String?     // toggled-on layer that persists after release (nil = none)
    private var stickyButton: String?    // the button that toggled `stickyLayer` on — re-tapping it
                                         // toggles off even if the `.layer` binding isn't visible
                                         // from inside the layer's own inherits chain.
    /// Fired when a STICKY layer is toggled on (true) or off (false) — the app shows a HUD. Not
    /// fired for the transient momentary hold (which would flash on every press/release).
    var onLayerToggle: ((_ on: Bool, _ layer: String) -> Void)?

    /// While the radial launcher is up it is MODAL: every button belongs to it, Select launching
    /// what is highlighted and anything else cancelling. Summoning it is an ordinary `.appWheel`
    /// hold binding — it goes through the same stage machinery, and therefore the same progress
    /// card, as every other hold. `isAppWheelOpen` is set by the app, which owns the overlay.
    static var isAppWheelOpen = false
    var onAppWheelButton: ((_ button: String) -> Void)?

    /// Multi-stage hold progress, for the on-screen HUD. `onHoldBegan` carries every BOUND stage
    /// with its threshold and a short label for the action it would run; `onHoldEnded` reports which
    /// stage actually fired (0 = released before stage 1). Only emitted for buttons that have at
    /// least one hold binding — there is nothing to choose between otherwise.
    var onHoldBegan: ((_ base: (action: Action, presentation: Config.Presentation?)?,
                       _ stages: [(threshold: TimeInterval, action: Action,
                                   presentation: Config.Presentation?, isCancel: Bool)]) -> Void)?
    /// Which of the stages passed to `onHoldBegan` fired, as a 1-BASED POSITION in that list
    /// (0 = released before the first). Deliberately not the binding's stage number: the list holds
    /// only the BOUND stages, so for a key with just `.hold2`/`.hold3` those numbers are 2 and 3
    /// while the positions are 1 and 2.
    var onHoldEnded: ((_ firedIndex: Int) -> Void)?

    /// Multi-tap: `<key>` / `<key>.double` / `<key>.triple`. Each tap is HELD for `doubleTapWindow`
    /// to see whether another arrives; the deepest count actually reached is what fires, and it
    /// fires ALONE — a triple never also emits a double or a single.
    ///
    /// Latency is charged only where it was asked for. A key resolves its DEEPEST BOUND count and
    /// stops waiting the moment it reaches it:
    ///   - nothing but `<key>` bound  → the single fires on press, no wait at all (as it always did);
    ///   - `.double` bound, no triple → the double fires on the 2nd press, immediately (as before);
    ///   - `.triple` bound            → the double must now wait one window to see if a 3rd tap
    ///                                  comes, and the triple fires on the 3rd press immediately.
    /// So binding a triple slows that key's double by one window, and nothing else — no key that
    /// does not use `.triple` pays anything, and the single is never delayed by either.
    var doubleTapWindow: TimeInterval = 0.3
    /// Consecutive taps seen inside the window, per button. Absent = no run in progress.
    private var tapRun: [String: Int] = [:]
    private var pendingTap: [String: DispatchWorkItem] = [:]
    /// Buttons whose CURRENT press already dispatched its deepest variant, so their release must not
    /// then open a fresh window and turn that tap into the first tap of a new run.
    private var tapFiredThisPress: Set<String> = []
    /// When each button's last tap ENDED. A press landing within `doubleTapWindow` of this, on a key
    /// with a `.taphold*` menu, is the hold half of tap-then-hold (see `isTapholdCandidate`).
    private var lastTapTime: [String: CFTimeInterval] = [:]

    /// Hold-to-repeat: a `.repeatKey` binding auto-repeats its keystroke while the button is held
    /// (HID sends a press then a release with NO auto-repeat, so the app generates the repeats).
    /// A press fires once + schedules a repeating timer (after `delay`, every `interval`); the
    /// matching release stops it. Keyed by HID button name. Bypasses `.hold`/`.double` entirely.
    private var repeatTimers: [String: DispatchSourceTimer] = [:]
    /// Repeat keys currently held DOWN (a true held key, not rapid re-tapping). buttonName → the
    /// parsed combo pressed by `Keys.holdBegin`. Released ONLY through `stopKeyRepeat`; every
    /// teardown path funnels there, so a held key can never survive its button and stick down.
    private var heldRepeatKeys: [String: KeyMap.Combo] = [:]
    /// Buttons whose current press actually ENGAGED a held-key repeat (held past the onset, not a quick
    /// tap). Outlives `stopKeyRepeat` (which runs before `handleTapRelease` and clears `heldRepeatKeys`),
    /// so release can tell a plain hold from a quick tap; cleared on the next press. Used to suppress a
    /// `.taphold*` key's DEFERRED tap when the press turned out to be a hold that already deleted.
    private var heldKeyEngaged: Set<String> = []

    /// Push-to-talk pairs currently OPEN: buttonName → the combo fired on the press edge, replayed
    /// verbatim on the release edge. Capturing at press time keeps the two edges firing the SAME
    /// combo even if the binding resolves differently mid-hold (a layer engaged by another button,
    /// an app switch, a config hot-reload) — the target hotkey is a toggle, and an unpaired edge
    /// would leave it latched on. Closed by the release edge or by `endPressScopedWork`.
    private var pushToTalkOpen: [String: String] = [:]
    /// Push-to-talk presses whose ACTIVATION delay has not yet elapsed: buttonName → the scheduled
    /// opener. A too-quick tap (released before `pushToTalkActivationDelay`) cancels this and fires
    /// nothing, so a brush of the button can't toggle dictation on; holding past the delay fires the
    /// opener and promotes the entry into `pushToTalkOpen`. Cleared on release, on fire, or teardown.
    private var pushToTalkPending: [String: DispatchWorkItem] = [:]
    /// How long a push-to-talk button must be held before its opening hotkey fires — gives the remote
    /// mic + capture pipeline a beat to spin up and rejects accidental brushes. (User-chosen 0.2 s.)
    private let pushToTalkActivationDelay: TimeInterval = 0.2
    /// Quick taps of a push-to-talk button (released before the activation delay, so they never open
    /// dictation) still drive DOUBLE-TAP: two within `doubleTapWindow` fire the button's `.double`
    /// binding (e.g. Enter). buttonName → when the last such quick tap ended. Hold and double-tap
    /// never collide — the 0.2 s delay cleanly separates "held" (push-to-talk) from "two quick taps".
    private var pushToTalkTapTime: [String: CFTimeInterval] = [:]

    /// Spaces Mode: long-pressing ring.up opens Mission Control AND arms this mode. While armed,
    /// ring.left/right switch desktops (animated, via System Events) and each switch restarts a
    /// `spacesModeWindow` timer. It exits (disarms) on ring.down (also closes Mission Control), a
    /// second ring.up long-press (also closes Mission Control), or `spacesModeWindow` of inactivity.
    var spacesModeWindow: TimeInterval = 5.0
    private var spacesModeActive = false
    private var spacesModeTimer: DispatchWorkItem?

    // Space switching used to shell out to BetterTouchTool's predefined actions 113/114, because
    // the in-tree alternative (a private CGS call) moved the bookkeeping without moving the screen.
    // `Spaces.switchSpace` now goes through System Events, which does work — see Spaces.swift — so
    // no third-party tool is involved.

    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    
    // First press after connection: do not perform action (sound already played at connect).
    private var isFirstPressAfterConnection = false
    
    // Click/drag state
    private var isSelectPressed = false
    private var selectPressTime: UInt64 = 0
    private var isDragging = false
    /// Deferred work owned by the CURRENT select press, so a stale closure from a previous press
    /// cannot act on this one. Both are cancelled the moment that press ends / a new one starts —
    /// the same pattern as `pendingTap`, and as `Brightness.rampGeneration`.
    private var dragStartWork: DispatchWorkItem?
    private var clickActiveClearWork: DispatchWorkItem?
    /// STICKY DRAG. Holding Select past this picks the item up and keeps the mouse button down
    /// after the remote button is released, so the finger can leave the pad and come back; the next
    /// Select press drops it.
    ///
    /// This REPLACES drag-while-held rather than layering on top of it. A tiered design (0.25s
    /// ordinary drag, 0.5s sticky) cannot work: dragging something involves moving, moving takes a
    /// second or two, so every ordinary drag would cross the deeper threshold anyway.
    private let stickyDragThreshold: Double = 0.5
    private var isStickyDragging = false
    /// The press currently down is the one that DROPPED a sticky drag. Its release must not also
    /// click: the drop already sent mouseUp, and an extra click would land wherever you dropped.
    private var isDropPress = false

    /// Select is hardcoded rather than config-driven, but its hold must still LOOK like every other
    /// hold — the same progress card, not a second style of its own. These are the two faces it
    /// shows: releasing now (a click) and holding on (pick the item up).
    private static let selectTapPresentation =
        Config.Presentation(label: "Click", icon: "cursorarrow.click")
    private static let selectDragPresentation =
        Config.Presentation(label: "Drag", icon: "hand.draw.fill")

    /// Sticky drag started (true) / dropped (false). The app pins a badge beside the pointer for
    /// the duration: the hold card is gone by then, so nothing else shows the mouse is still down.
    var onStickyDrag: ((Bool) -> Void)?
    
    // Prevent double-processing with MediaKeyInterceptor
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0

    // MARK: - Input guard (power button)

    /// The Power button sits right next to the glass, so pressing it almost always brushes the
    /// trackpad — which instantly undid the dim it had just triggered (a touch restores brightness)
    /// and could nudge the cursor. While this deadline is in the future, incidental remote input is
    /// ignored for *actions*: touches don't move the cursor, click, or restore brightness, and other
    /// buttons don't dispatch their bindings. Events are still read and tracked, so state stays
    /// consistent — only the misfiring is suppressed.
    private static var inputGuardDeadlineNanos: UInt64 = 0

    /// Seconds of quiet after a Power press. Long enough to cover the release plus a clumsy grip.
    static let inputGuardDuration: Double = 1.0

    static var isInputGuarded: Bool {
        DispatchTime.now().uptimeNanoseconds < inputGuardDeadlineNanos
    }

    static func armInputGuard(_ seconds: Double = inputGuardDuration) {
        inputGuardDeadlineNanos =
            DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    }

    // MARK: - Touch guard (click-ring / centre)

    /// The click-ring directions and the centre button are pressed THROUGH the glass, so every one
    /// of them also lands as a touch: the cursor jumps, or the press is read as a swipe, and the two
    /// interpretations fight. This suppresses only the trackpad for a moment — unlike
    /// `inputGuardDeadlineNanos`, other buttons keep working normally.
    ///
    /// Kept shorter than `stickyDragThreshold` (0.5s) on purpose: press-and-hold-to-drag has to still
    /// start on time, so the guard must have expired before the drag begins.
    private static var touchGuardDeadlineNanos: UInt64 = 0

    static var touchGuardDuration: Double = 0.2

    static var isTouchGuarded: Bool {
        DispatchTime.now().uptimeNanoseconds < touchGuardDeadlineNanos
    }

    static func armTouchGuard(_ seconds: Double = touchGuardDuration) {
        touchGuardDeadlineNanos =
            DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
    }

    /// Buttons that are physically part of the touch surface.
    private static let onGlassButtons: Set<String> =
        ["ringUp", "ringDown", "ringLeft", "ringRight", "select"]


    /// Last observed pressed/released state per button. The Siri Remote mirrors each logical
    /// button across multiple HID interfaces (6 seized here), so every physical press/release
    /// fires the callback N times. This collapses dup events to a single state transition.
    private var buttonState: [String: Bool] = [:]
    
    init(cursorController: CursorController, menuBarManager: MenuBarManager) {
        self.cursorController = cursorController
        self.menuBarManager = menuBarManager
    }
    
    func setRemoteDevice(_ device: IOHIDDevice?) {
        guard let device = device else {
            releaseAllHeldKeys()
            for d in devices {
                IOHIDDeviceRegisterInputValueCallback(d, nil, nil)
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                IOHIDDeviceClose(d, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            devices.removeAll()
            isFirstPressAfterConnection = false
            return
        }
        
        guard !devices.contains(where: { $0 == device }) else { return }
        
        let usagePage = IOHIDDeviceGetProperty(
            device, kIOHIDPrimaryUsagePageKey as CFString
        ) as? Int ?? -1
        let usage = IOHIDDeviceGetProperty(
            device, kIOHIDPrimaryUsageKey as CFString
        ) as? Int ?? -1

        // Normal operation seizes every remote interface to prevent duplicate system handling. The
        // direct-PTT diagnostic is narrower: seize only the audio interface whose raw reports we
        // need, and leave the management/button siblings non-exclusive while report 0x99 is tested.
        let shouldSeize = !directPushToTalk || (usagePage == 0x0C && usage == 0x04)
        let openOptions = IOOptionBits(
            shouldSeize ? kIOHIDOptionsTypeSeizeDevice : kIOHIDOptionsTypeNone
        )
        let openResult = IOHIDDeviceOpen(device, openOptions)

        if openResult == kIOReturnSuccess {
            rmDebug(String(format: "%@ HID device usage=0x%X/0x%X (vendor=0x%X product=0x%X)",
                  shouldSeize ? "🔒 SEIZED" : "🔓 OPENED non-exclusive",
                  usagePage,
                  usage,
                  IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0,
                  IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0))
            IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
            if captureMic || activateMic || nativePushToTalk || directPushToTalk {
                registerReportCapture(device)
            }
            if dumpReports { dumpHIDReports(device) }
            if activateMic {
                // Give macOS a moment to finish HOGP setup / notification subscribe before writing.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                    self?.sendMicActivation(device)
                }
            }
            IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            devices.append(device)
            isFirstPressAfterConnection = true
        } else {
            rmDebug(String(format: "⚠️ FAILED to %@ HID device usage=0x%X/0x%X (IOReturn=0x%X) — retrying non-exclusive",
                           shouldSeize ? "seize" : "open", usagePage, usage, openResult))
            if IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess {
                IOHIDDeviceRegisterInputValueCallback(device, inputValueCallback, Unmanaged.passUnretained(self).toOpaque())
                if captureMic || activateMic || nativePushToTalk || directPushToTalk {
                    registerReportCapture(device)
                }
                if dumpReports { dumpHIDReports(device) }
                if activateMic {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.sendMicActivation(device)
                    }
                }
                IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
                devices.append(device)
                isFirstPressAfterConnection = true
            }
        }
    }
    
    /// Register a raw input-report callback (voice-capture diagnostic). The buffer must outlive the
    /// registration, so it's retained in `reportBuffers`.
    private func registerReportCapture(_ device: IOHIDDevice) {
        let bufLen = 512
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufLen)
        buf.initialize(repeating: 0, count: bufLen)
        let captureContext = MicReportCaptureContext(
            interfaceNumber: IOHIDDeviceGetProperty(device, "bInterfaceNumber" as CFString) as? Int ?? -1,
            locationID: IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? -1,
            usagePage: IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1,
            usage: IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
        )
        reportBuffers.append(buf)
        reportCaptureContexts.append(captureContext)
        IOHIDDeviceRegisterInputReportCallback(device, buf, bufLen, inputReportCallback,
                                               Unmanaged.passUnretained(captureContext).toOpaque())
        rmDebug("🎤 mic-capture: raw report callback registered \(captureContext.label)")
    }

    // MARK: - Mic reverse-engineering diagnostics

    private func hidElementTypeName(_ t: IOHIDElementType) -> String {
        if t == kIOHIDElementTypeOutput     { return "output" }
        if t == kIOHIDElementTypeFeature    { return "feature" }
        if t == kIOHIDElementTypeCollection { return "collection" }
        return "input"
    }

    /// Byte length of each report, keyed "type:reportID", summed from element bit sizes.
    private func reportByteLengths(_ device: IOHIDDevice) -> [String: Int] {
        var bits: [String: Int] = [:]
        if let els = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for el in els {
                let key = "\(hidElementTypeName(IOHIDElementGetType(el))):\(IOHIDElementGetReportID(el))"
                bits[key, default: 0] += Int(IOHIDElementGetReportSize(el)) * Int(IOHIDElementGetReportCount(el))
            }
        }
        return bits.mapValues { ($0 + 7) / 8 }
    }

    /// `--dump-reports`: enumerate every HID element on this interface and GetReport each feature
    /// report id, logging the full control surface to /tmp/hypervibe.log (`🔎` lines).
    private func dumpHIDReports(_ device: IOHIDDevice) {
        let pup = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
        let pu  = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
        let interfaceNumber = IOHIDDeviceGetProperty(device, "bInterfaceNumber" as CFString) as? Int ?? -1
        let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? -1
        let maxIn  = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? -1
        let maxOut = IOHIDDeviceGetProperty(device, kIOHIDMaxOutputReportSizeKey as CFString) as? Int ?? -1
        let maxFeat = IOHIDDeviceGetProperty(device, kIOHIDMaxFeatureReportSizeKey as CFString) as? Int ?? -1
        rmDebug(String(format: "🔎 interface=%d location=0x%X primaryUsagePage=0x%X usage=0x%X maxIn=%d maxOut=%d maxFeat=%d",
                       interfaceNumber, locationID, pup, pu, maxIn, maxOut, maxFeat))

        var featureIDs = Set<Int>()
        var outputIDs  = Set<Int>()
        if let els = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] {
            for el in els {
                let t = IOHIDElementGetType(el)
                let rid = Int(IOHIDElementGetReportID(el))
                if t == kIOHIDElementTypeFeature { featureIDs.insert(rid) }
                if t == kIOHIDElementTypeOutput  { outputIDs.insert(rid) }
                rmDebug(String(format: "🔎 el %@ reportID=%d usagePage=0x%X usage=0x%X sizeBits=%d count=%d",
                               hidElementTypeName(t), rid,
                               IOHIDElementGetUsagePage(el), IOHIDElementGetUsage(el),
                               IOHIDElementGetReportSize(el), IOHIDElementGetReportCount(el)))
            }
        }
        let lens = reportByteLengths(device)
        rmDebug("🔎 report byte-lengths: \(lens.sorted{ $0.key < $1.key }.map{ "\($0.key)=\($0.value)" }.joined(separator: " "))")
        rmDebug("🔎 outputIDs=\(outputIDs.sorted()) featureIDs=\(featureIDs.sorted())")

        // GetReport every feature report id we saw (plus a few common ones) so we can see current state.
        let probeIDs = Set(featureIDs).union([0, 1, 2, 3, 4, 5, 0xAF]).sorted()
        for id in probeIDs {
            let cap = 256
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { buf.deallocate() }
            var len: CFIndex = cap
            let r = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), buf, &len)
            if r == kIOReturnSuccess {
                let hex = (0..<min(Int(len), 48)).map { String(format: "%02x", buf[$0]) }.joined(separator: " ")
                rmDebug(String(format: "🔎 GetReport FEATURE id=%d len=%ld: %@", id, len, hex))
            } else {
                rmDebug(String(format: "🔎 GetReport FEATURE id=%d → 0x%X", id, r))
            }
        }
    }

    private func ioReturnName(_ value: IOReturn) -> String {
        switch value {
        case kIOReturnSuccess:       return "success"
        case kIOReturnError:         return "general error"
        case kIOReturnNotFound:      return "not found"
        case kIOReturnUnsupported:   return "unsupported"
        case kIOReturnNotWritable:   return "not writable"
        case kIOReturnNotOpen:       return "not open"
        case kIOReturnNotPermitted:  return "not permitted"
        case kIOReturnBadArgument:   return "bad argument"
        default:                     return "unknown"
        }
    }

    /// `--activate-mic`: write the enable byte to Feature report 0xFF on every virtual interface that
    /// actually declares it. IORegistry confirms that macOS splits the remote's same-UUID GATT Report
    /// characteristics into numbered IOHID interfaces and rewrites the individual reports to 0xFF.
    ///
    /// The current Linux gen-3 implementation reads each Report Reference descriptor and establishes
    /// that this firmware exposes no Output reports: it writes 0xAF to every writable Feature report,
    /// then receives microphone input as wire report 0xFA with a 99-byte Opus payload. The earlier
    /// macOS probe covered only five of seven virtual interfaces; diagnostic matching now includes
    /// the two usage-page-0x20 interfaces so this pass covers the complete report surface.
    private func sendMicActivation(_ device: IOHIDDevice) {
        let pup = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? -1
        let pu = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? -1
        let interfaceNumber = IOHIDDeviceGetProperty(device, "bInterfaceNumber" as CFString) as? Int ?? -1
        let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? -1

        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        let hasFeatureFF = elements.contains {
            IOHIDElementGetType($0) == kIOHIDElementTypeFeature && IOHIDElementGetReportID($0) == 0xFF
        }
        guard hasFeatureFF else {
            rmDebug(String(format: "🎬 activate-mic: skip interface=%d location=0x%X usage=0x%X/0x%X (no Feature 0xFF)",
                           interfaceNumber, locationID, pup, pu))
            return
        }

        rmDebug(String(format: "🎬 activate-mic: FEATURE target interface=%d location=0x%X usage=0x%X/0x%X",
                       interfaceNumber, locationID, pup, pu))
        var enable: [UInt8] = [0xAF]
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0xFF, &enable, enable.count)
        rmDebug(String(format: "🎬 SetReport FEATURE id=0xFF bytes=[AF] → 0x%X (%@)%@",
                       result, ioReturnName(result), result == kIOReturnSuccess ? " ✅" : ""))
    }

    /// `--direct-ptt`: exercise the hidden one-byte Feature report used by
    /// AppleEmbeddedBluetoothDeviceManagement for product IDs 0x314/0x315. Unlike
    /// `NativePushToTalk`, this sends the report through the already-open IOHID device, which lets
    /// us distinguish a blocked registry-property path from a blocked HID report path. Restrict the
    /// write to the management interface (usage page 0xFF00, usage 0x0B); all other interfaces are
    /// capture-only. Calling this with `false` sends the matching release byte.
    func setDirectPushToTalk(_ enabled: Bool) {
        if enabled {
            rmDebug("🗣 direct-ptt: re-arming all \(devices.count) interfaces before PTT")
            for device in devices {
                sendMicActivation(device)
            }
        }

        let targets = devices.filter { device in
            let usagePage = IOHIDDeviceGetProperty(
                device, kIOHIDPrimaryUsagePageKey as CFString
            ) as? Int ?? -1
            let usage = IOHIDDeviceGetProperty(
                device, kIOHIDPrimaryUsageKey as CFString
            ) as? Int ?? -1
            return usagePage == 0xFF00 && usage == 0x0B
        }

        guard !targets.isEmpty else {
            rmDebug("🗣 direct-ptt: management interface 0xFF00/0x0B not found")
            return
        }

        for device in targets {
            let interfaceNumber = IOHIDDeviceGetProperty(
                device, "bInterfaceNumber" as CFString
            ) as? Int ?? -1
            let locationID = IOHIDDeviceGetProperty(
                device, kIOHIDLocationIDKey as CFString
            ) as? Int ?? -1
            var payload: [UInt8] = [enabled ? 1 : 0]
            let result = payload.withUnsafeMutableBufferPointer { buffer in
                IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeFeature,
                    0x99,
                    buffer.baseAddress!,
                    buffer.count
                )
            }
            rmDebug(String(
                format: "🗣 direct-ptt: FEATURE id=0x99 bytes=[%02X] interface=%d location=0x%X → 0x%X (%@)%@",
                enabled ? 1 : 0,
                interfaceNumber,
                locationID,
                result,
                ioReturnName(result),
                result == kIOReturnSuccess ? " ✅" : ""
            ))
        }
    }

    func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let identified = identifyButton(page: usagePage, usage: usage)
        rmDebug(String(format: "🎮 HID event: page=0x%X usage=0x%X value=%d → %@",
                       usagePage, usage, intValue, identified ?? "<unmapped>"))
        guard let buttonName = identified else { return }

        onButtonActivity?()

        // Collapse mirrored-interface duplicates: only proceed on a real state transition.
        let isPressed = (intValue == 1)
        if buttonState[buttonName] == isPressed {
            return
        }
        buttonState[buttonName] = isPressed

        // The remote can sleep between initial enumeration and a later Siri press. Re-send the
        // gen-3 enable byte at the physical start of every diagnostic trial so a stale activation
        // cannot explain an otherwise empty voice stream.
        if activateMic && buttonName == "siri" && isPressed {
            rmDebug("🎬 activate-mic: Siri down — re-arming all \(devices.count) interfaces")
            for device in devices {
                sendMicActivation(device)
            }
        }

        // Pressing Power opens the input guard FIRST, so the rest of this press — and anything the
        // hand brushes on the way — cannot undo the dim it is about to trigger.
        if isPressed && buttonName == "power" {
            RemoteInputHandler.armInputGuard()
        }

        // Ring/centre presses come through the glass, so each one also arrives as a touch. Mute the
        // trackpad briefly so the press is not simultaneously read as a cursor move or a swipe.
        if isPressed && RemoteInputHandler.onGlassButtons.contains(buttonName) {
            RemoteInputHandler.armTouchGuard()
        }

        // Any real button press restores brightness — so after button.power dims all displays to
        // minimum (brightness action), pressing anything brings the backlight back to max. The
        // guard only restores when currently at/near minimum, so normal-brightness presses are a
        // no-op here. Press only, never release. Skipped inside the input guard, which is the whole
        // point of it: Power itself must not restore, and neither may an accidental brush.
        if isPressed && !RemoteInputHandler.isInputGuarded { Brightness.restoreIfDimmed() }

        // Volume keys are left to the remote's native BT/AVRCP absolute-volume path so they
        // control system volume in every app (we no longer arm the revert guard to undo it).

        let pressed = (intValue == 1)

        // Stamp WHICH button the remote just sent, before any early return below.
        //
        // This is attribution, not dispatch. MediaKeyInterceptor uses it to tell "this system media
        // key came from our remote" apart from the Mac's own keys, and it consumes the native key
        // only when the button is attributed AND bound. Every `return` below suppresses our
        // *action* — but macOS still emits the native media key, and if we did not stamp, the tap
        // would let that native key through. The suppressing paths would then be strictly worse
        // than no suppression at all: our binding silently skipped, the native behaviour fired.
        //
        // Concretely, with playPause bound: clipping it while reaching for Power would toggle the
        // player (the exact event the input guard exists to swallow), and the first press after
        // every reconnect would do the same.
        if pressed {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }

        // A RELEASE must always stop a running auto-repeat, before any of the guards below — every
        // one of them returns without distinguishing press from release, and a swallowed release
        // leaves the repeat timer firing forever with no way to stop it but disconnecting the
        // remote. Observed with the Power input guard: hold an arrow, brush Power, let go, and the
        // arrow repeated without end. Not a `return` — the normal path still runs when it can.
        if !pressed, repeatTimers[buttonName] != nil {
            stopKeyRepeat(buttonName)
        }

        // First key-down after connection: skip so the connect handshake doesn't fire an action.
        if intValue == 1 && isFirstPressAfterConnection {
            isFirstPressAfterConnection = false
            return
        }

        // Inside the Power input guard, other buttons are read and tracked but must not fire their
        // bindings — a button clipped while reaching for Power should do nothing. Power itself is
        // exempt so its own press/release still work normally.
        if buttonName != "power" && RemoteInputHandler.isInputGuarded {
            // Suppress the ACTION, not the bookkeeping. A release swallowed here still ends the
            // press, so nothing it armed is left scheduled.
            if !pressed { endPressScopedWork(buttonName) }
            return
        }

        // The app wheel is modal: while it is up every button belongs to it, including the release
        // of the very press that summoned it (which must not then toggle the layer).
        if RemoteInputHandler.isAppWheelOpen {
            if pressed { onAppWheelButton?(buttonName) }
            return
        }

        // Select is the trackpad click — handled separately for click/drag semantics.
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
            return
        }

        // Config-driven only, with long-press discrimination.
        routeButton(buttonName, pressed: pressed)
    }

    /// Route a button press/release through the config engine. Priority on press: Spaces Mode →
    /// `.pushToTalk` (both raw edges, no discrimination) → `.repeatKey` (auto-repeat) →
    /// `.layer` (momentary layer) → multi-stage long-press / tap.
    /// Long-press is RELEASE-TO-SELECT (see the `holdThreshold`/`holdStageTimers` docs): a press
    /// arms a timer per bound `.hold*` stage, each timer only records the stage reached, and the
    /// deepest stage reached fires on release; a release before stage 1 fires the tap/double.
    /// Unbound events do nothing.
    /// If a layer button is held momentarily and a DIFFERENT button is pressed, the layer is being
    /// "used" (as a shift), so its release should revert — not toggle it sticky.
    private func markLayerUsed(byButton buttonName: String, pressed: Bool) {
        if pressed, let lb = layerButton, buttonName != lb { layerUsed = true }
    }

    /// Same, for non-`routeButton` input (center click, swipe, two-finger tap): if a momentary layer
    /// is held while one of those fires, count it as a use so the layer release reverts, not toggles.
    func noteLayerUsedByOtherInput() {
        if layerButton != nil { layerUsed = true }
    }

    private func routeButton(_ buttonName: String, pressed: Bool) {
        guard let controller = controller else { return }
        let tapKey = RemoteInputHandler.configKey(for: buttonName)

        // If a layer button is being held momentarily, ANY other button press "uses" it (so its
        // release reverts the layer instead of toggling it sticky). Mark this FIRST — before the
        // Spaces / repeatKey early-returns — so a repeat-bound or Spaces key still counts as a use.
        markLayerUsed(byButton: buttonName, pressed: pressed)

        // 1) Spaces Mode: while armed, the ring becomes a desktop switcher. Intercept on press,
        //    BEFORE any config dispatch, and consume so the normal binding doesn't also fire.
        //    (ring.up long-press is handled in the hold path below so a hold can toggle it off.)
        if spacesModeActive && pressed {
            switch tapKey {
            case "ring.left":
                Spaces.switchSpace(-1)
                restartSpacesModeTimer()
                print("🖥 Spaces Mode: ← space")
                return
            case "ring.right":
                Spaces.switchSpace(1)
                restartSpacesModeTimer()
                print("🖥 Spaces Mode: → space")
                return
            case "ring.down":
                sendKey(kVK_Escape)          // close Mission Control
                disarmSpacesMode()
                print("🖥 Spaces Mode: exit (ring.down)")
                return
            default:
                break                        // other buttons pass through normally, no disarm
            }
        }

        // 2) Push-to-talk: fire the combo on BOTH raw edges — press AND release — immediately,
        //    bypassing tap/double/taphold/hold discrimination and auto-repeat entirely. Built for
        //    toggle hotkeys (press = dictation ON, release = OFF), so the two edges must always
        //    come in matched pairs:
        //      - the release replays the combo CAPTURED AT PRESS TIME, and closes the pair even if
        //        the key no longer resolves to `.pushToTalk` (layer/mode change mid-hold, config
        //        hot-reload) — same reasoning as the unconditional repeat-timer stop below;
        //      - a release with no open pair fires nothing: its press was swallowed upstream (the
        //        first-press-after-connection guard, a modal intercept), so firing here would
        //        toggle the hotkey with no matching edge.
        //    Bookkeeping stays consistent for free: `buttonState` and `lastProcessedButton` are
        //    stamped in `handleInputValue` before any dispatch (the same contract every other
        //    early-return here relies on), and a push-to-talk press arms nothing — no stage
        //    timers, no pending tap, no repeat — so its release has nothing else to unwind.
        // Release BEFORE the activation delay elapsed → a too-quick tap: cancel the pending opener and
        // fire NOTHING, so a brush of the button can't latch the dictation toggle on.
        if !pressed, let pending = pushToTalkPending.removeValue(forKey: buttonName) {
            pending.cancel()   // released before activation → a quick tap, dictation not opened
            // A quick tap still feeds DOUBLE-TAP: two within `doubleTapWindow` fire the `.double`
            // binding (Enter). A lone quick tap does nothing — a push-to-talk button has no single-tap
            // action — so there is no window-wait latency here; only the 2nd tap acts.
            let now = CACurrentMediaTime()
            if let last = pushToTalkTapTime[buttonName], now - last < doubleTapWindow {
                pushToTalkTapTime[buttonName] = nil
                let dbl = tapVariant(tapKey, 2)
                if controller.handle(InputEvent(key: dbl)) { print("🔘 \(dbl) (pushToTalk double)") }
            } else {
                pushToTalkTapTime[buttonName] = now
            }
            return
        }
        // Release AFTER the opener fired → fire the closing hotkey (dictation off).
        if !pressed, let keys = pushToTalkOpen.removeValue(forKey: buttonName) {
            Keys.synthesize(keys)
            print("🔘 \(tapKey) → pushToTalk '\(keys)' (release edge)")
            return
        }
        // Press → SCHEDULE the opener for `pushToTalkActivationDelay` later. Only if the button is
        // still held then does it fire and "open" the pair (so the release fires the matching close).
        // `keys` is captured at press time so both edges use the SAME combo even if the binding
        // resolves differently mid-hold (a layer/mode change, a config hot-reload).
        if pressed, case let .pushToTalk(keys)? = controller.resolvedAction(for: tapKey) {
            pushToTalkPending.removeValue(forKey: buttonName)?.cancel()   // supersede any stale pending
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pushToTalkPending.removeValue(forKey: buttonName)
                self.pushToTalkOpen[buttonName] = keys
                Keys.synthesize(keys)
                print("🔘 \(tapKey) → pushToTalk '\(keys)' (press edge, +\(self.pushToTalkActivationDelay)s)")
            }
            pushToTalkPending[buttonName] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + pushToTalkActivationDelay, execute: work)
            return
        }

        // 3) Hold-to-repeat: if this key resolves to a `.repeatKey` action, bypass the normal
        //    hold/double discrimination — a press fires once and starts an auto-repeat, and the
        //    release stops it. (Because this bypasses the `.hold` path, an inherited `<key>.hold`
        //    binding is intentionally NOT reachable for a `.repeatKey` key.)
        // Any release of a button that has a live repeat timer MUST stop it — even if the key no
        // longer resolves to `.repeatKey` (config hot-reload or an app/mode switch mid-hold, e.g. the
        // repeating Delete closed the window and focus moved). Otherwise the timer runs forever.
        if !pressed, repeatTimers[buttonName] != nil {
            stopKeyRepeat(buttonName)
            return
        }
        if case let .repeatKey(keys, delay, interval)? = controller.resolvedAction(for: tapKey) {
            if pressed {
                startKeyRepeat(buttonName, tapKey: tapKey, keys: keys, delay: delay, interval: interval)
            } else {
                stopKeyRepeat(buttonName)
            }
            return
        }

        // 4) Layer key: a `.layer` binding acts like a shift/layer key with BOTH activation styles
        //    (see the `layerButton`/`stickyLayer` docs above). The layer key CONSUMES its own press —
        //    it fires nothing itself; keys pressed while a layer is active resolve in that layer
        //    (Controller.handle/hasBinding/resolvedAction all consult the active layer).
        if pressed {
            // Engage a layer if this key is a `.layer` binding — OR if it's the button that toggled
            // the current sticky layer on (so a re-tap can toggle OFF even when the `.layer` binding
            // isn't visible from inside the layer's own inherits chain).
            var engage: String? = nil
            if case let .layer(name)? = controller.resolvedAction(for: tapKey) { engage = name }
            else if buttonName == stickyButton, let s = stickyLayer { engage = s }
            if let name = engage {
                controller.pushLayer(name)          // engage immediately → momentary has no latency
                layerButton = buttonName
                layerName = name
                layerUsed = false
                print("🔘 \(tapKey) → layer '\(name)' (engage)")

                // A layer key may ALSO carry hold bindings. Fall through so its stages are armed by
                // the normal machinery — which is what gives it the progress card for free, rather
                // than the bespoke timer this used to have. With no hold bindings it consumes its
                // own press exactly as before.
                if !hasAnyHoldStage(tapKey) { return }
            }
        } else if layerButton == buttonName {
            // Reaching a hold stage means this press was never a layer gesture. Unwind the layer
            // engaged optimistically on press and DO NOT return — the hold path below still has to
            // dispatch the action, cancel the stage timers and dismiss the progress card. Returning
            // here left all three undone, so the card hung on screen looking like a stuck hold.
            if deepestStage[buttonName] != nil || holdCancelled.contains(buttonName) {
                unwindMomentaryLayer()
            } else {
                let name = layerName ?? ""
                if layerUsed {
                    if let s = stickyLayer { controller.pushLayer(s) } else { controller.popLayer() }
                    print("🔘 \(tapKey) → layer '\(name)' (momentary release)")
                } else if stickyLayer == name {
                    stickyLayer = nil; stickyButton = nil   // tap while sticky-on → toggle OFF
                    controller.popLayer()
                    onLayerToggle?(false, name)          // HUD: back to the base layer
                    print("🔘 \(tapKey) → layer '\(name)' (toggle off)")
                } else {
                    stickyLayer = name; stickyButton = buttonName   // bare tap → toggle ON (sticky)
                    controller.pushLayer(name)
                    onLayerToggle?(true, name)           // HUD: this layer is now active
                    print("🔘 \(tapKey) → layer '\(name)' (toggle on)")
                }
                layerButton = nil
                layerName = nil
                layerUsed = false
                // This release was a layer gesture, so the hold path below must not dispatch — but
                // it still armed stage timers on the way in, and they have to be called off here.
                // Without this a short press left them scheduled and never told the card the hold
                // had ended, so the progress card appeared on an ordinary tap and stayed up.
                endPressScopedWork(buttonName)
                return
            }
        }

        // 5) Multi-stage long-press (RELEASE-TO-SELECT) + tap/double.
        if pressed {
            // Tap-then-hold: a press that lands within the double-tap window of a recent tap, on a
            // key that has a `.taphold*` menu, is the "hold" half of tap-then-hold — arm THAT second
            // menu (identical machinery, `.taphold*` bindings) instead of counting another tap.
            if isTapholdCandidate(buttonName, tapKey: tapKey),
               armHoldStages(buttonName: buttonName, tapKey: tapKey, family: .taphold) {
                // This second press IS the hold half of tap-then-hold, so cancel the first tap's
                // DEFERRED delete (armed in handleTapPress) — otherwise it lands right before the menu.
                pendingTap.removeValue(forKey: buttonName)?.cancel()
                tapRun.removeValue(forKey: buttonName)
                lastTapTime[buttonName] = nil       // a taphold doesn't chain into another taphold
                return
            }
            // Plain long-press menu.
            if armHoldStages(buttonName: buttonName, tapKey: tapKey, family: .hold) {
                return
            }
            // No hold menu bound: this is the ordinary tap, and holding it now auto-repeats since
            // nothing else claims the hold.
            handleTapPress(buttonName, tapKey: tapKey)
            startAutoRepeatIfEligible(buttonName, tapKey: tapKey)
        } else {
            // Release-to-select: cancel remaining stage timers, then fire the deepest stage reached.
            guard let items = holdStageTimers.removeValue(forKey: buttonName) else {
                // No hold stages: this is where the double-tap window OPENS. Measuring it from the
                // release rather than from the press is the point — a first tap held a little
                // longer would otherwise eat into the window, so how fast you must tap the second
                // time depended on how long you held the first.
                handleTapRelease(buttonName, tapKey: tapKey)
                return
            }
            items.forEach { $0.cancel() }
            let reachedIndex = deepestStage.removeValue(forKey: buttonName)
            let armed = armedStages.removeValue(forKey: buttonName) ?? []
            holdCancelWork.removeValue(forKey: buttonName)?.cancel()
            let cancelled = holdCancelled.remove(buttonName) != nil

            // `armed` is already in the order the HUD was given, so the index IS the position —
            // no translating between stage numbers and list positions, which is what previously
            // confirmed the wrong action on release. The cancel entry, if any, sits after them all.
            if cancelled {
                onHoldEnded?(armed.count + 1)
                print("🔘 \(tapKey) hold cancelled")
                return
            }
            onHoldEnded?(reachedIndex.map { $0 + 1 } ?? 0)
            if let index = reachedIndex, index < armed.count {
                fireHold(controller: controller, holdKey: armed[index].key)
            } else {
                // Released before the first stage → it was a tap: fire the single (or a `.double`).
                fireTapOrDouble(buttonName, tapKey: tapKey)
            }
        }
    }

    /// Arm the release-to-select stages of a hold family (`.hold*` OR `.taphold*`) and raise the
    /// progress HUD. Returns false — arming nothing — if the button binds no stage in that family,
    /// so the caller can fall through to the next family or to the plain tap. This is the shared
    /// machinery behind both the plain long-press and the tap-then-hold menu; only the binding
    /// suffix differs. The release branch above is family-agnostic: it reads `holdStageTimers`
    /// whichever family populated it.
    private func armHoldStages(buttonName: String, tapKey: String, family: HoldFamily) -> Bool {
        guard let controller = controller else { return false }

        // Resolve every bound stage with its EFFECTIVE delay first (the binding's own `after` wins;
        // the global threshold for that stage is the fallback), then order by time.
        var armed: [ArmedStage] = []
        for stage in 1...3 {
            let stageKey = RemoteInputHandler.holdStageKey(tapKey, stage, family)
            guard controller.hasBinding(for: stageKey) else { continue }
            let delay = controller.resolvedHoldDelay(for: stageKey) ?? holdStageThreshold(stage)
            armed.append(ArmedStage(key: stageKey, delay: delay))
        }
        guard !armed.isEmpty else { return false }
        armed.sort { $0.delay < $1.delay }

        var items: [DispatchWorkItem] = []
        var hudStages: [(threshold: TimeInterval, action: Action,
                         presentation: Config.Presentation?, isCancel: Bool)] = []
        for (index, stage) in armed.enumerated() {
            let work = DispatchWorkItem { [weak self] in self?.deepestStage[buttonName] = index }
            items.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + stage.delay, execute: work)
            if let stageAction = controller.resolvedAction(for: stage.key) {
                hudStages.append((stage.delay, stageAction,
                                  controller.resolvedPresentation(for: stage.key), false))
            }
        }
        // Cancel anything still armed from a previous press whose release was swallowed —
        // overwriting the dictionary would orphan those work items, not stop them.
        holdStageTimers.removeValue(forKey: buttonName)?.forEach { $0.cancel() }
        holdCancelWork.removeValue(forKey: buttonName)?.cancel()
        deepestStage.removeValue(forKey: buttonName)   // absent = no stage reached yet
        armedStages[buttonName] = armed
        holdStageTimers[buttonName] = items
        holdCancelled.remove(buttonName)

        // Escape hatch: keep holding past the deepest stage and releasing does nothing at all.
        if holdCancelGrace > 0, let deepest = armed.last {
            let cancelAt = deepest.delay + holdCancelGrace
            let cancel = DispatchWorkItem { [weak self] in self?.holdCancelled.insert(buttonName) }
            holdCancelWork[buttonName] = cancel
            DispatchQueue.main.asyncAfter(deadline: .now() + cancelAt, execute: cancel)
            hudStages.append((cancelAt, Action.mouse(op: "click"),
                              Config.Presentation(label: "Cancel", icon: "arrow.uturn.backward"), true))
        }
        // Stage 0 is the ordinary tap — releasing early fires it (see the release branch).
        let base = controller.resolvedAction(for: tapKey).map {
            (action: $0, presentation: controller.resolvedPresentation(for: tapKey))
        }
        onHoldBegan?(base, hudStages)
        return true
    }

    /// A press qualifies as the "hold" half of tap-then-hold when the key carries a `.taphold*` menu
    /// AND a tap ended within `doubleTapWindow`. Recorded on tap release, so a first tap held past
    /// the window (which auto-repeats) has already let the window lapse and won't trip this.
    private func isTapholdCandidate(_ buttonName: String, tapKey: String) -> Bool {
        guard hasAnyHoldStage(tapKey, family: .taphold), let t = lastTapTime[buttonName] else {
            return false
        }
        return CACurrentMediaTime() - t < doubleTapWindow
    }

    /// The two hold-menu families a button can carry. `.hold*` is the plain long-press; `.taphold*`
    /// is the second menu reached by tap-then-hold. Both use the identical release-to-select
    /// machinery below — only the binding suffix differs.
    enum HoldFamily: String { case hold, taphold }

    /// The binding key for a hold stage in a family: (hold, 1) → `<key>.hold`, (taphold, 2) →
    /// `<key>.taphold2`, etc. Stage 1 has no numeric suffix.
    static func holdStageKey(_ tapKey: String, _ stage: Int, _ family: HoldFamily = .hold) -> String {
        let n = stage >= 2 ? "\(stage)" : ""
        return tapKey + "." + family.rawValue + n
    }

    /// The configured threshold (seconds) at which a hold stage is reached.
    private func holdStageThreshold(_ stage: Int) -> TimeInterval {
        switch stage {
        case 2:  return holdThreshold2
        case 3:  return holdThreshold3
        default: return holdThreshold
        }
    }

    /// Run a long-press (`<key>.hold*`) action, fired on release by the hold path. `ring.up.hold`
    /// additionally toggles Spaces Mode: the first long-press runs its config action (open Mission
    /// Control) and arms; a second long-press while armed closes Mission Control (Escape) and
    /// disarms instead of re-opening. (Arming now happens on release — see the release-to-select model.)
    private func fireHold(controller: Controller, holdKey: String) {
        if holdKey == "ring.up.hold" {
            if spacesModeActive {
                sendKey(kVK_Escape)              // close Mission Control
                disarmSpacesMode()
                print("🖥 Spaces Mode: exit (ring.up long-press)")
                return
            }
            if controller.handle(InputEvent(key: holdKey)) { print("🔘 \(holdKey) (config)") }
            armSpacesMode()                      // Mission Control now open → arm desktop switching
            return
        }
        if controller.handle(InputEvent(key: holdKey)) { print("🔘 \(holdKey) (config)") }
    }

    // MARK: - Hold-to-repeat (Feature 1)

    /// Start auto-repeating `keys` for `buttonName`. Fires once immediately (through the config
    /// path so it's logged like any dispatch), then after `delay` repeats every `interval` on the
    /// main queue until `stopKeyRepeat`. Repeats call `Keys.synthesize` directly to avoid
    /// re-resolving the binding every tick.
    /// How long a button must be held before it starts auto-repeating. Decoupled from `holdThreshold`
    /// (~a keyboard's "delay until repeat"): auto-repeat only happens on keys with NO `.hold*` menu,
    /// so there is no hold stage for it to race — it can start sooner than the hold threshold without
    /// any conflict, which keeps a held Delete feeling as snappy as a real keyboard. Was tied to
    /// `holdThreshold` (0.5s); that made a held key feel sluggish to start for no benefit here.
    private let autoRepeatDelay: TimeInterval = RemoteInputHandler.systemInitialKeyRepeat()

    /// Held-key repeat timing read from the USER'S OWN keyboard settings, so a held remote key repeats at
    /// EXACTLY their keyboard's rate. macOS stores these in NSGlobalDomain as integer 15 ms "ticks":
    /// `InitialKeyRepeat` = delay before the first repeat, `KeyRepeat` = interval between repeats. This
    /// user runs 15 / 1 → 225 ms / 15 ms (the fastest). Our old hard-coded 60 ms interval was 4× too slow,
    /// which read as a sluggish, choppy "re-send" rather than a smooth hold. Floored so a pathological
    /// value can't spin the CPU. (Read once at init; a mid-session settings change needs an app restart.)
    private static let keyRepeatTickSeconds = 0.015
    private static func systemInitialKeyRepeat() -> TimeInterval {
        max(0.05, globalRepeatTicks("InitialKeyRepeat", fallback: 25) * keyRepeatTickSeconds)   // default ≈ 375 ms
    }
    private static func systemKeyRepeatInterval() -> TimeInterval {
        max(0.008, globalRepeatTicks("KeyRepeat", fallback: 6) * keyRepeatTickSeconds)           // default ≈ 90 ms
    }
    private static func globalRepeatTicks(_ key: String, fallback: Double) -> Double {
        (CFPreferencesCopyAppValue(key as CFString, kCFPreferencesAnyApplication) as? NSNumber)?.doubleValue ?? fallback
    }
    /// Interval between held-KEYSTROKE repeats (Delete, arrows) — matches the keyboard rate above. Media
    /// keeps the slower discrete `autoRepeatInterval` below, since each media tick steps one notch and 66/s
    /// would make volume/brightness fly.
    private let keystrokeRepeatInterval: TimeInterval = RemoteInputHandler.systemKeyRepeatInterval()
    /// A `.taphold*` key DEFERS its tap (see `handleTapPress`), so for it the held-key repeat is what
    /// delivers the FIRST delete of a plain hold — engage it this fast rather than after the full
    /// `autoRepeatDelay`, so holding to delete stays responsive (~130 ms, not 300 ms). Must stay LONGER
    /// than a deliberate quick tap, or the "tap" half of tap-then-hold would fire a delete before the
    /// hold is recognised. This is the tap-vs-hold discrimination point for taphold keys.
    private let tapholdHoldOnset: TimeInterval = 0.13
    /// ~16 repeats/second once it starts, roughly matching the system key-repeat feel.
    private let autoRepeatInterval: TimeInterval = 0.06

    /// Hold-to-repeat for keys that never asked for it: if a button has a tap binding and no
    /// `.hold*` binding, nothing else claims the hold, so holding it repeats the tap.
    ///
    /// Restricted to actions where repeating is *meaningful and harmless* — a real keystroke or a
    /// media key. Repeating the others would be actively wrong: `applescript`/`shell` would re-run
    /// a side effect dozens of times (a bound Mute toggle would flap on and off), `launch` would
    /// reopen an app, `mode`/`layer` would thrash the active layer, `brightness` would re-set the
    /// same value. A modifier-only chord ("hyperkey") is excluded too: it has no main key, so it is
    /// held rather than tapped, and repeating it means nothing.
    ///
    /// Opting out is already possible without new config: bind any `.hold` stage to the button and
    /// that claims the hold instead.
    private func startAutoRepeatIfEligible(_ buttonName: String, tapKey: String) {
        guard let controller = controller,
              let action = controller.resolvedAction(for: tapKey) else { return }

        switch action {
        case .keystroke(let keys):
            // mainKey == nil ⇒ modifier-only chord; there is no key to repeat.
            guard KeyMap.parse(keys)?.mainKey != nil else { return }
        case .media:
            break
        default:
            return
        }

        // A KEYSTROKE holds down and repeats as a genuine key (the initial tap already typed the
        // first character with the key up, so the hold begins after `autoRepeatDelay`). A MEDIA key
        // keeps the old discrete re-tap below, which is CORRECT for it — each press steps volume one
        // notch, so "repeating" it means stepping, not holding.
        if case .keystroke(let keys) = action {
            // A taphold key deferred its tap, so this repeat delivers the FIRST delete of a plain hold —
            // engage it fast (`tapholdHoldOnset`). A quick tap releases before then and is deferred.
            let onset = hasAnyHoldStage(tapKey, family: .taphold) ? tapholdHoldOnset : autoRepeatDelay
            startHeldKeyRepeat(buttonName, tapKey: tapKey, keys: keys,
                               delay: onset, interval: keystrokeRepeatInterval, pressNow: false)
            return
        }

        stopKeyRepeat(buttonName)   // never stack two repeats on one button
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + autoRepeatDelay, repeating: autoRepeatInterval)
        // Re-dispatch through the controller rather than synthesizing directly, so each repeat
        // resolves against the CURRENT mode/layer — holding a key while the frontmost app changes
        // then does the right thing instead of replaying a stale keystroke.
        rmDebug("🔁 media-repeat ARM \(buttonName) → \(tapKey)")
        timer.setEventHandler { [weak self] in
            guard let self = self, let controller = self.controller else { return }
            // Check against ground truth before every repeat. `buttonState` is maintained by the
            // HID decoder from real transitions, so if the button is not actually held any more,
            // this timer has outlived its press and must die — whatever desynchronised it.
            //
            // A repeat that survives its release is unbounded: it types forever with no way to stop
            // it short of unpairing the remote. That has been seen and could not be reproduced on
            // demand, so rather than guess at the cause, the damage is bounded to one interval.
            guard self.buttonState[buttonName] == true else {
                rmDebug("🔁 media-repeat ORPHANED \(buttonName) — button not held, stopping")
                self.stopKeyRepeat(buttonName)
                return
            }
            _ = controller.handle(InputEvent(key: tapKey))
        }
        repeatTimers[buttonName] = timer
        timer.resume()
    }

    private func startKeyRepeat(_ buttonName: String, tapKey: String, keys: String,
                                delay: Double, interval: Double) {
        // `.repeatKey`: the press itself is the first character, so the key goes down NOW and holds.
        startHeldKeyRepeat(buttonName, tapKey: tapKey, keys: keys,
                           delay: delay, interval: interval, pressNow: true)
    }

    /// Hold a keystroke DOWN and let it auto-repeat as a GENUINE held key — not the old rapid
    /// press-release re-tap. `holdBegin` presses it down (and, when `pressNow`, that IS the first
    /// character); each tick re-fires it with the OS auto-repeat flag while the key stays down;
    /// `stopKeyRepeat` lifts it. `pressNow` is true for `.repeatKey` (the press = the first char) and
    /// false when auto-repeating a plain tap (the tap already typed once with the key up, so the hold
    /// only begins after `delay` — that keeps a quick tap a single character).
    ///
    /// The held key is released ONLY by `stopKeyRepeat`, and every teardown path funnels there, so a
    /// held key can never outlive its button and stick down — the one failure mode a held key adds
    /// over the old re-tap. If you add a new teardown path, it MUST call `stopKeyRepeat`.
    private func startHeldKeyRepeat(_ buttonName: String, tapKey: String, keys: String,
                                    delay: TimeInterval, interval: TimeInterval, pressNow: Bool) {
        stopKeyRepeat(buttonName)   // releases any prior held key AND cancels its timer

        if pressNow {
            guard let held = Keys.holdBegin(keys) else { return }
            heldRepeatKeys[buttonName] = held
            heldKeyEngaged.insert(buttonName)
            print("🔘 \(tapKey) ⤓ hold (config)")
        }

        // `.strict` stops the system COALESCING / DEFERRING this timer for power savings. WITHOUT it a
        // ~15 ms timer on the main queue actually fires at ~36 ms and wildly uneven (measured: avg 36 ms,
        // spikes to 74 ms) — precisely the "slower + choppy than the keyboard" the held keys felt. WITH
        // `.strict` + tight leeway it holds ~15 ms / 67 per second, matching the keyboard's own repeat.
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now() + delay, repeating: interval, leeway: .nanoseconds(100_000))
        rmDebug("🔁 held-repeat ARM \(buttonName) keys=\(keys) pressNow=\(pressNow)")
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Ground truth: `buttonState` comes from real HID transitions. A timer outliving its
            // press must die — and because `stopKeyRepeat` also LIFTS the held key, an orphaned
            // repeat can never leave a key stuck down (unbounded typing until the remote unpairs).
            guard self.buttonState[buttonName] == true else {
                rmDebug("🔁 held-repeat ORPHANED \(buttonName) — button not held, stopping")
                self.stopKeyRepeat(buttonName)
                return
            }
            // Re-resolve each tick: if the binding moved (app switch / hot-reload) or is gone, stop —
            // which releases the key — rather than hold a key whose meaning changed out from under it.
            let sameKeys: String?
            switch self.controller?.resolvedAction(for: tapKey) {
            case .repeatKey(let cur, _, _)?: sameKeys = cur
            case .keystroke(let cur)?:       sameKeys = cur
            default:                         sameKeys = nil
            }
            guard sameKeys == keys else {
                rmDebug("🔁 held-repeat STALE \(buttonName) — binding changed, stopping")
                self.stopKeyRepeat(buttonName)
                return
            }
            if let held = self.heldRepeatKeys[buttonName] {
                Keys.holdRepeat(held)                        // key stays down, OS auto-repeat flag
            } else if let held = Keys.holdBegin(keys) {
                self.heldRepeatKeys[buttonName] = held       // first repeat of a plain-tap hold
                self.heldKeyEngaged.insert(buttonName)       // this press became a hold, not a tap
            }
        }
        repeatTimers[buttonName] = timer
        timer.resume()
    }

    /// Stop a button's repeat: LIFT its held key (if any) AND cancel its timer. This is the single
    /// release point for `heldRepeatKeys` — every teardown path calls it, which is what guarantees a
    /// held key never outlives its button. Safe on a button with nothing armed.
    private func stopKeyRepeat(_ buttonName: String) {
        if let held = heldRepeatKeys.removeValue(forKey: buttonName) {
            Keys.holdEnd(held)   // release the genuinely-held key, or it sticks down
            rmDebug("🔁 held-repeat RELEASE \(buttonName)")
        }
        if let timer = repeatTimers.removeValue(forKey: buttonName) {
            rmDebug("🔁 repeat STOP \(buttonName)")
            timer.cancel()
        }
    }

    private func stopAllKeyRepeats() {
        // Route every armed button through stopKeyRepeat so held keys are LIFTED, not just timers
        // cancelled — a cancelled timer that left a key down would stick it forever.
        for name in Set(repeatTimers.keys).union(heldRepeatKeys.keys) { stopKeyRepeat(name) }
    }

    // MARK: - Spaces Mode (Feature 2)

    /// Arm Spaces Mode (called right after ring.up.hold opens Mission Control) and start the
    /// inactivity timer.
    private func armSpacesMode() {
        spacesModeActive = true
        restartSpacesModeTimer()
        rmDebug("🖥 Spaces Mode armed (\(spacesModeWindow)s window)")
    }

    /// Restart the inactivity timer: after `spacesModeWindow` seconds with no left/right switch,
    /// Spaces Mode disarms on its own (Mission Control is left as-is on a timeout — not closed).
    private func restartSpacesModeTimer() {
        spacesModeTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.spacesModeTimer = nil
            self.spacesModeActive = false
            rmDebug("🖥 Spaces Mode timed out")
        }
        spacesModeTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + spacesModeWindow, execute: work)
    }

    private func disarmSpacesMode() {
        spacesModeActive = false
        spacesModeTimer?.cancel()
        spacesModeTimer = nil
    }

    /// The event key for the nth consecutive tap: 1 → `<key>`, 2 → `.double`, 3 → `.triple`.
    private func tapVariant(_ tapKey: String, _ n: Int) -> String {
        switch n {
        case 2:  return tapKey + ".double"
        case 3:  return tapKey + ".triple"
        default: return tapKey
        }
    }

    /// How many taps this key is worth waiting for — its deepest BOUND multi-tap variant. 1 means
    /// nothing to disambiguate, so the tap need not be held at all. This is what keeps the cost of
    /// `.triple` local to the keys that use it.
    private func deepestTapCount(_ tapKey: String) -> Int {
        guard let controller = controller else { return 1 }
        if controller.hasBinding(for: tapKey + ".triple") { return 3 }
        if controller.hasBinding(for: tapKey + ".double") { return 2 }
        return 1
    }

    /// Resolve the run after the window elapses: whatever count we reached is what the user meant.
    private func scheduleTapResolution(_ buttonName: String, tapKey: String) {
        pendingTap[buttonName]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, let controller = self.controller else { return }
            let n = self.tapRun.removeValue(forKey: buttonName) ?? 1
            self.pendingTap[buttonName] = nil
            let key = self.tapVariant(tapKey, n)
            if controller.handle(InputEvent(key: key)) { print("🔘 \(key) (config)") }
        }
        pendingTap[buttonName] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
    }

    /// Press half of the multi-tap machine, for keys with NO hold stages.
    ///
    /// A press landing while a run is pending advances that run, and reaching the deepest bound
    /// count fires HERE rather than waiting for the release — which is what keeps a double as
    /// immediate as it has always been on keys that bind no triple.
    private func handleTapPress(_ buttonName: String, tapKey: String) {
        guard let controller = controller else { return }
        tapFiredThisPress.remove(buttonName)
        heldKeyEngaged.remove(buttonName)      // fresh press — a prior hold no longer applies

        pendingTap.removeValue(forKey: buttonName)?.cancel()
        let n = (tapRun[buttonName] ?? 0) + 1
        tapRun[buttonName] = n

        // Deepest bound count reached — nothing further to wait for … UNLESS this key has a `.taphold*`
        // menu. Then the next press could be the hold half of tap-then-hold, so firing the tap NOW would
        // leak it (e.g. Back sending Delete before its close-window menu). Defer instead: a QUICK release
        // schedules it via `handleTapRelease` (cancelled if a taphold follows); a HELD press fires it
        // fast through the repeat's short `tapholdHoldOnset`. Non-taphold keys are unchanged (immediate).
        if n >= deepestTapCount(tapKey) && !hasAnyHoldStage(tapKey, family: .taphold) {
            tapRun.removeValue(forKey: buttonName)
            tapFiredThisPress.insert(buttonName)
            let key = tapVariant(tapKey, n)
            if controller.handle(InputEvent(key: key)) { print("🔘 \(key) (config)") }
        }
    }

    /// Release half: open the next window, timed from HERE.
    private func handleTapRelease(_ buttonName: String, tapKey: String) {
        // A tap just ended here — start the tap-then-hold watch window (harmless on keys with no
        // `.taphold*`, since `isTapholdCandidate` checks for that binding before using this).
        lastTapTime[buttonName] = CACurrentMediaTime()
        // If this press was HELD long enough to engage the repeat (a plain hold, not a quick tap), the
        // hold already delivered its deletes — the DEFERRED tap of a `.taphold*` key must not ALSO fire.
        let wasHold = heldKeyEngaged.remove(buttonName) != nil
        // The press that just ended already fired its variant; it must not start a fresh run.
        guard tapFiredThisPress.remove(buttonName) == nil else { return }
        guard tapRun[buttonName] != nil, !wasHold else { tapRun.removeValue(forKey: buttonName); return }
        scheduleTapResolution(buttonName, tapKey: tapKey)
    }

    /// Multi-tap for keys that DO have hold stages, where every half necessarily happens on release
    /// — a further press cannot be called a tap until it is known not to be a hold.
    private func fireTapOrDouble(_ buttonName: String, tapKey: String) {
        guard let controller = controller else { return }

        pendingTap.removeValue(forKey: buttonName)?.cancel()
        let n = (tapRun[buttonName] ?? 0) + 1
        tapRun[buttonName] = n

        if n >= deepestTapCount(tapKey) {
            tapRun.removeValue(forKey: buttonName)
            let key = tapVariant(tapKey, n)
            if controller.handle(InputEvent(key: key)) { print("🔘 \(key) (config)") }
        } else {
            scheduleTapResolution(buttonName, tapKey: tapKey)
        }
    }
    
    /// Drop whatever sticky drag is carrying. Safe to call when not dragging.
    func endStickyDrag() {
        guard isStickyDragging else { return }
        print("🔘 Select button: sticky drag ended")
        isStickyDragging = false
        isDragging = false
        cursorController.isDragging = false
        cursorController.mouseUp()
        onStickyDrag?(false)
    }

    private let dumpPress = CommandLine.arguments.contains("--dump-press")

    private func handleSelectButton(pressed: Bool) {
        if dumpPress {
            rmDebug(String(format: "PRESSLOG t=%.4f BUTTON %@",
                           CACurrentMediaTime(), pressed ? "DOWN" : "UP"))
        }
        if pressed { noteLayerUsedByOtherInput() }   // center-click while holding a layer = momentary use
        if pressed && !isSelectPressed {
            // Already carrying something → this press is the drop, and nothing else.
            if isStickyDragging {
                endStickyDrag()
                isSelectPressed = true
                isDropPress = true
                return
            }
            isDropPress = false
            isSelectPressed = true
            isDragging = false
            selectPressTime = mach_absolute_time()
            cursorController.isClickActive = true

            // A pending clear from the PREVIOUS release would otherwise land 0.1s into this press
            // and drop isClickActive while the button is physically down — which opens the
            // press-freeze (so a resting finger drifts the cursor mid-click) and defeats the
            // "don't tap while the physical click is active" guard on the touch side.
            clickActiveClearWork?.cancel()
            clickActiveClearWork = nil

            // Start drag after threshold. Held in a cancellable item so it belongs to THIS press:
            // checking `isSelectPressed` alone is not enough, because a quick click-then-press
            // (release at 0.10s, press again at 0.20s) leaves the first press's closure to fire at
            // 0.25s and start a drag 0.05s into the second press — breaking double-click and
            // micro-dragging whatever is under the cursor.
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.isSelectPressed, !self.isDragging else { return }
                self.dragStartWork = nil
                print("🔘 Select button: sticky drag started")
                self.isDragging = true
                self.isStickyDragging = true
                self.cursorController.isDragging = true
                self.cursorController.mouseDown()
                self.onStickyDrag?(true)
            }
            dragStartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + stickyDragThreshold, execute: work)

            // Same card as any other hold. Not emitted for a drop press, which schedules nothing —
            // a filling track there would promise a drag that is not coming.
            onHoldBegan?((action: .mouse(op: "click"),
                          presentation: RemoteInputHandler.selectTapPresentation),
                         [(stickyDragThreshold, Action.mouse(op: "click"),
                           RemoteInputHandler.selectDragPresentation, false)])
        } else if !pressed && isSelectPressed {
            isSelectPressed = false

            // This press is over — its drag must not start after the fact.
            dragStartWork?.cancel()
            dragStartWork = nil
            if !isDropPress { onHoldEnded?(isStickyDragging ? 1 : 0) }

            if isStickyDragging {
                // Carrying something: releasing the button must NOT drop it. That is the point.
            } else if isDropPress {
                isDropPress = false      // this press only dropped; it is not also a click
            } else {
                print("🔘 Select button: Click")
                cursorController.performClick()
            }

            let clear = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.clickActiveClearWork = nil
                self.cursorController.isClickActive = false
            }
            clickActiveClearWork = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: clear)
        }
    }
    
    /// Map an identified HID button name to a config event key (`ring.*` for the
    /// click-ring, `button.*` for everything else).
    static func configKey(for buttonName: String) -> String {
        switch buttonName {
        case "ringUp":    return "ring.up"
        case "ringDown":  return "ring.down"
        case "ringLeft":  return "ring.left"
        case "ringRight": return "ring.right"
        default:          return "button.\(buttonName)"
        }
    }

    // MARK: - Button Identification

    private func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)
        
        // Consumer Page (0x0C)
        case (0x0C, 0x42): return "ringUp"        // Menu Up — click-ring up
        case (0x0C, 0x43): return "ringDown"      // Menu Down — click-ring down
        case (0x0C, 0x44): return "ringLeft"      // Menu Left — click-ring left
        case (0x0C, 0x45): return "ringRight"     // Menu Right — click-ring right
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Select (alternative)
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu
        case (0x0C, 0x30): return "power"         // Power
        // 0xE2 is the Consumer Page's standard Mute usage and what the 3rd-gen Siri Remote actually
        // sends; only 0x20 was mapped, so this button was <unmapped> and every `button.mute`
        // binding silently did nothing while the native mute still fired — which looks like the
        // button "working" until you try to bind a .double/.hold variant to it.
        case (0x0C, 0xE2): return "mute"          // Mute (HID Consumer Page standard)
        case (0x0C, 0x20): return "mute"          // Mute (some other remotes)
        
        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1
        
        // Apple Vendor Page (0xFF00) - Siri button
        case (0xFF00, 0x01): return "siri"        // Siri button
        case (0xFF00, 0x02): return "siri"        // Siri button (alternative)
        case (0xFF00, 0x03): return "siri"        // Siri button (alternative)
        case (0xFF00, _): return "siri"           // Any Apple vendor usage = likely Siri
        
        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute
        
        default: return nil
        }
    }
    
    /// Called on device removal, to make sure nothing this handler started outlives the device.
    /// (It does not release keyboard modifiers, despite what this comment used to claim —
    /// `Keys.synthesize` posts down and up in one synchronous call, so a disconnect cannot land
    /// between them.)
    private func releaseAllHeldKeys() {
        // Before clearing the state, end every press that is still open. Losing the device ends a
        // press with no release at all, so nothing it armed would otherwise be cancelled — a Select
        // press interrupted inside its 0.5s drag window posted mouseDown AFTER this cleanup ran,
        // leaving the left button down with no remote attached.
        for name in Set(buttonState.keys).union(["select"]) {
            endPressScopedWork(name)
        }
        buttonState.removeAll()
        // Sticky drag is designed to outlive letting go of the button AND the pad, so nothing else
        // would ever end it — and a BLE remote disconnects on idle. Picking something up and
        // walking away would otherwise leave the left mouse button held down across the whole
        // system, with no way back short of clicking manually.
        endStickyDrag()
        stopAllKeyRepeats()   // don't leak auto-repeat timers if the remote disconnects mid-hold
        cancelHoldStages()    // and don't leave release-to-select stage timers pending
        cancelPendingSingles()   // and don't let a delayed single fire after disconnect
        disarmSpacesMode()    // and don't leave Spaces Mode armed with no device attached
        // A physically-held momentary layer can't survive the device going away — unwind it and
        // revert to the sticky layer (if any). KEEP the sticky layer: BLE remotes disconnect on
        // idle, and a sticky toggle should persist across an idle reconnect, not silently drop.
        if layerButton != nil {
            if let s = stickyLayer { controller?.pushLayer(s) } else { controller?.popLayer() }
            layerButton = nil
            layerName = nil
            layerUsed = false
        }
    }

    /// Cancel any window-delayed multi-tap work items (so a pending tap can't fire after a
    /// disconnect / device swap). The run counters go with them — a half-finished run resuming
    /// against a different device would count the next tap as a second.
    private func cancelPendingSingles() {
        for (_, item) in pendingTap { item.cancel() }
        pendingTap.removeAll()
        tapRun.removeAll()
        tapFiredThisPress.removeAll()
    }

    /// Clear a sticky layer + its Controller state (used by config hot-reload when the layer's mode
    /// no longer exists, so bindings don't all resolve to nil with no way to pop).
    func clearStickyLayer() {
        let had = stickyLayer
        stickyLayer = nil
        stickyButton = nil
        layerButton = nil
        layerName = nil
        layerUsed = false
        controller?.popLayer()
        if let name = had { onLayerToggle?(false, name) }
    }

    /// Cancel all pending multi-stage hold timers and reset the reached-stage tracking.
    /// End every piece of deferred work this press started, firing nothing.
    ///
    /// The normal release path does this as a side effect of dispatching an action — but there are
    /// paths where a release never reaches it, and each of them leaked something different: the
    /// Power input guard returns on release as well as press, and a disconnect ends a press with no
    /// release at all. Doing it in ONE place is the point: otherwise the next path to skip the
    /// release leaks whatever has been added since, which is exactly how this went wrong twice.
    /// Does this key have any bound hold stage? Decides whether a layer key keeps consuming its
    /// own press or falls through to have those stages armed.
    private func hasAnyHoldStage(_ tapKey: String, family: HoldFamily = .hold) -> Bool {
        guard let controller = controller else { return false }
        return (1...3).contains {
            controller.hasBinding(for: RemoteInputHandler.holdStageKey(tapKey, $0, family))
        }
    }

    /// Drop a momentary layer without the tap/toggle decision — used when the press turned out to
    /// be a hold rather than a layer gesture.
    private func unwindMomentaryLayer() {
        guard layerButton != nil else { return }
        if let sticky = stickyLayer { controller?.pushLayer(sticky) } else { controller?.popLayer() }
        layerButton = nil
        layerName = nil
        layerUsed = false
    }

    private func endPressScopedWork(_ buttonName: String) {
        stopKeyRepeat(buttonName)

        // An open push-to-talk pair holds a toggle hotkey "on" between its edges the way a held
        // repeat key holds a key down — and like the key-up inside `stopKeyRepeat` above, the
        // closing combo must fire on every teardown path (a release swallowed by the input guard,
        // a disconnect mid-hold). Dropping it silently would leave the toggle latched on with the
        // button long gone.
        // A not-yet-fired opener (button torn down during the activation delay): cancel it — nothing
        // was sent, so there is nothing to close.
        pushToTalkPending.removeValue(forKey: buttonName)?.cancel()
        if let keys = pushToTalkOpen.removeValue(forKey: buttonName) {
            Keys.synthesize(keys)
        }

        // Select's drag timer. Left running, it posts mouseDown at +0.5s with nothing physically
        // held, and the left button then stays down across the whole system. `isSelectPressed` must
        // be cleared too, or the timer's own guard reads it as still-pressed and fires anyway — and
        // the NEXT press falls through both branches, needing two clicks to recover.
        if buttonName == "select" {
            dragStartWork?.cancel()
            dragStartWork = nil
            isSelectPressed = false
            isDropPress = false
            // `isClickActive` gates the press-freeze; stuck true it freezes the cursor outright and
            // kills tap-to-click until a full press/release gets through again.
            clickActiveClearWork?.cancel()
            clickActiveClearWork = nil
            cursorController.isClickActive = false
            // Sticky drag is deliberately NOT ended here: it is built to outlive the button. Only
            // losing the device (releaseAllHeldKeys) or a deliberate press drops it.
        }

        // Hold stages. Left running, a stale recorder fires during the NEXT press and inflates
        // `deepestStage`, so releasing that press as a quick tap dispatches the long-press action.
        holdStageTimers.removeValue(forKey: buttonName)?.forEach { $0.cancel() }
        holdCancelWork.removeValue(forKey: buttonName)?.cancel()
        deepestStage.removeValue(forKey: buttonName)
        armedStages.removeValue(forKey: buttonName)
        holdCancelled.remove(buttonName)
        tapFiredThisPress.remove(buttonName)

        // A momentary layer is engaged on press and released only in the release branch. Swallow
        // that release and every key resolves inside the layer indefinitely, with no indication —
        // the layer button has to be cycled to escape. Unwind to the sticky layer if there is one,
        // exactly as a real release would, but without the tap/toggle decision: this was not a tap.
        if layerButton == buttonName { unwindMomentaryLayer() }

        // The progress card is dismissed only by an end notification. Without one it stays pinned
        // above every Space, with a 60 Hz repaint behind it, until the next hold or a restart.
        onHoldEnded?(0)
    }

    private func cancelHoldStages() {
        for (_, items) in holdStageTimers { items.forEach { $0.cancel() } }
        holdStageTimers.removeAll()
        for (_, work) in holdCancelWork { work.cancel() }
        holdCancelWork.removeAll()
        deepestStage.removeAll()
        armedStages.removeAll()
        holdCancelled.removeAll()
    }

    private func postKey(keyCode: Int, flags: CGEventFlags, keyDown: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(keyCode), keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        postKey(keyCode: keyCode, flags: flags, keyDown: true)
        usleep(10000)
        postKey(keyCode: keyCode, flags: flags, keyDown: false)
    }
}

// C callback
/// Raw HID input-report callback (mic/voice capture). Logs report id, length, and the leading bytes
/// so we can see the remote's large voice reports when the Siri button is held.
private func inputReportCallback(context: UnsafeMutableRawPointer?, result: IOReturn,
                                 sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
                                 reportID: UInt32, report: UnsafeMutablePointer<UInt8>,
                                 reportLength: CFIndex) {
    guard let context else { return }
    let captureContext = Unmanaged<MicReportCaptureContext>.fromOpaque(context).takeUnretainedValue()
    let n = Int(reportLength)
    let hex = (0..<min(n, 40)).map { String(format: "%02x", report[$0]) }.joined(separator: " ")
    rmDebug(String(format: "🎤 raw %@ type=%d id=%u len=%ld result=0x%X: %@%@",
                   captureContext.label, type.rawValue, reportID, reportLength, result,
                   hex, n > 40 ? " …" : ""))
}

private func inputValueCallback(context: UnsafeMutableRawPointer?, result: IOReturn, sender: UnsafeMutableRawPointer?, value: IOHIDValue) {
    guard let context = context else { return }
    Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue().handleInputValue(value)
}
