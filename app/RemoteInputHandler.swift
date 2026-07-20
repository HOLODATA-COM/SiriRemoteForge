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
    private var holdStageTimers: [String: [DispatchWorkItem]] = [:]
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

    /// Double-tap: if a `<key>.double` binding exists, the single is HELD for `doubleTapWindow` to
    /// see whether a 2nd tap arrives. A lone tap fires `<key>` only after the window elapses; a
    /// quick 2nd tap cancels that pending single and fires `<key>.double` instead — so a double-tap
    /// emits ONLY the double, never a single too. Keys with no `.double` binding fire the single
    /// immediately (zero added latency).
    var doubleTapWindow: TimeInterval = 0.3
    private var pendingSingle: [String: DispatchWorkItem] = [:]

    /// Hold-to-repeat: a `.repeatKey` binding auto-repeats its keystroke while the button is held
    /// (HID sends a press then a release with NO auto-repeat, so the app generates the repeats).
    /// A press fires once + schedules a repeating timer (after `delay`, every `interval`); the
    /// matching release stops it. Keyed by HID button name. Bypasses `.hold`/`.double` entirely.
    private var repeatTimers: [String: DispatchSourceTimer] = [:]

    /// Spaces Mode: long-pressing ring.up opens Mission Control AND arms this mode. While armed,
    /// ring.left/right switch desktops (animated, via BetterTouchTool) and each switch restarts a
    /// `spacesModeWindow` timer. It exits (disarms) on ring.down (also closes Mission Control), a
    /// second ring.up long-press (also closes Mission Control), or `spacesModeWindow` of inactivity.
    var spacesModeWindow: TimeInterval = 5.0
    private var spacesModeActive = false
    private var spacesModeTimer: DispatchWorkItem?

    /// BetterTouchTool predefined-action triggers for animated space switching (HANDOFF §6):
    /// action 113 = move one space left, 114 = move one space right. Run via the shell (`open -g`).
    private static let bttSpaceLeftCommand  = "open -g \"btt://trigger_action/?json=%7B%22BTTPredefinedActionType%22%3A113%7D\""
    private static let bttSpaceRightCommand = "open -g \"btt://trigger_action/?json=%7B%22BTTPredefinedActionType%22%3A114%7D\""

    /// Called on any button activity; use to trigger trackpad re-scan after remote wake.
    var onButtonActivity: (() -> Void)?
    
    // First press after connection: do not perform action (sound already played at connect).
    private var isFirstPressAfterConnection = false
    
    // Click/drag state
    private var isSelectPressed = false
    private var selectPressTime: UInt64 = 0
    private var isDragging = false
    private let clickThreshold: Double = 0.25
    
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

        // Any real button press restores brightness — so after button.power dims all displays to
        // minimum (brightness action), pressing anything brings the backlight back to max. The
        // guard only restores when currently at/near minimum, so normal-brightness presses are a
        // no-op here. Press only, never release. Skipped inside the input guard, which is the whole
        // point of it: Power itself must not restore, and neither may an accidental brush.
        if isPressed && !RemoteInputHandler.isInputGuarded { Brightness.restoreIfDimmed() }

        // Volume keys are left to the remote's native BT/AVRCP absolute-volume path so they
        // control system volume in every app (we no longer arm the revert guard to undo it).

        // First key-down after connection: skip so the connect handshake doesn't fire an action.
        if intValue == 1 && isFirstPressAfterConnection {
            isFirstPressAfterConnection = false
            return
        }

        // Inside the Power input guard, other buttons are read and tracked but must not fire their
        // bindings — a button clipped while reaching for Power should do nothing. Power itself is
        // exempt so its own press/release still work normally.
        if buttonName != "power" && RemoteInputHandler.isInputGuarded {
            return
        }

        // Select is the trackpad click — handled separately for click/drag semantics.
        if buttonName == "select" {
            handleSelectButton(pressed: intValue == 1)
            return
        }

        let pressed = (intValue == 1)

        // Debounce only on press — release just closes an existing hold.
        if pressed {
            RemoteInputHandler.lastProcessedButton = buttonName
            RemoteInputHandler.lastProcessedTime = mach_absolute_time()
        }

        // Config-driven only, with long-press discrimination.
        routeButton(buttonName, pressed: pressed)
    }

    /// Route a button press/release through the config engine. Priority on press: Spaces Mode →
    /// `.repeatKey` (auto-repeat) → `.layer` (momentary layer) → multi-stage long-press / tap.
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
                Shell.run(RemoteInputHandler.bttSpaceLeftCommand)
                restartSpacesModeTimer()
                print("🖥 Spaces Mode: ← space")
                return
            case "ring.right":
                Shell.run(RemoteInputHandler.bttSpaceRightCommand)
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

        // 2) Hold-to-repeat: if this key resolves to a `.repeatKey` action, bypass the normal
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

        // 3) Layer key: a `.layer` binding acts like a shift/layer key with BOTH activation styles
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
                return
            }
        } else if layerButton == buttonName {
            let name = layerName ?? ""
            if layerUsed {
                // Used to shift other keys → momentary. Revert to the sticky layer if one is on.
                if let s = stickyLayer { controller.pushLayer(s) } else { controller.popLayer() }
                print("🔘 \(tapKey) → layer '\(name)' (momentary release)")
            } else if stickyLayer == name {
                stickyLayer = nil; stickyButton = nil   // tap while sticky-on → toggle OFF
                controller.popLayer()
                onLayerToggle?(false, name)          // HUD: layer off
                print("🔘 \(tapKey) → layer '\(name)' (toggle off)")
            } else {
                stickyLayer = name; stickyButton = buttonName   // bare tap → toggle ON (sticky)
                controller.pushLayer(name)
                onLayerToggle?(true, name)           // HUD: layer on
                print("🔘 \(tapKey) → layer '\(name)' (toggle on)")
            }
            layerButton = nil
            layerName = nil
            layerUsed = false
            return
        }

        // 4) Multi-stage long-press (RELEASE-TO-SELECT) + tap/double.
        if pressed {
            // Arm a timer for each BOUND hold stage; each only records the stage reached (it does
            // NOT fire — see `holdStageTimers`). If no stage is bound the tap completes on press.
            var items: [DispatchWorkItem] = []
            for stage in 1...3 where controller.hasBinding(for: RemoteInputHandler.holdStageKey(tapKey, stage)) {
                let work = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.deepestStage[buttonName] = max(self.deepestStage[buttonName] ?? 0, stage)
                }
                items.append(work)
                DispatchQueue.main.asyncAfter(deadline: .now() + holdStageThreshold(stage), execute: work)
            }
            guard !items.isEmpty else {
                // No `.hold*` binding → the tap completes on press: fire the single immediately
                // (no added latency), or a `.double` if this is a quick 2nd tap.
                fireTapOrDouble(buttonName, tapKey: tapKey)
                return
            }
            deepestStage[buttonName] = 0
            holdStageTimers[buttonName] = items
        } else {
            // Release-to-select: cancel remaining stage timers, then fire the deepest stage reached.
            guard let items = holdStageTimers.removeValue(forKey: buttonName) else { return }
            items.forEach { $0.cancel() }
            let reached = deepestStage.removeValue(forKey: buttonName) ?? 0
            if reached >= 1 {
                fireHoldStage(controller: controller, tapKey: tapKey, reached: reached)
            } else {
                // Released before stage 1 → it was a tap: fire the single (or `.double` on a 2nd tap).
                fireTapOrDouble(buttonName, tapKey: tapKey)
            }
        }
    }

    /// Release-to-select: fire the deepest BOUND hold stage at or below `reached` (the deepest
    /// stage whose threshold elapsed while the button was held). Stage 3 = `<key>.hold3`, stage
    /// 2 = `<key>.hold2`, stage 1 = `<key>.hold`; falls back to a shallower bound stage if the
    /// reached stage isn't bound (normally it is, since only bound stages arm a timer).
    private func fireHoldStage(controller: Controller, tapKey: String, reached: Int) {
        var stage = reached
        while stage >= 1 {
            let holdKey = RemoteInputHandler.holdStageKey(tapKey, stage)
            if controller.hasBinding(for: holdKey) {
                fireHold(controller: controller, holdKey: holdKey)
                return
            }
            stage -= 1
        }
    }

    /// The binding key for a hold stage: 1 = `<key>.hold`, 2 = `<key>.hold2`, 3 = `<key>.hold3`.
    static func holdStageKey(_ tapKey: String, _ stage: Int) -> String {
        switch stage {
        case 2:  return tapKey + ".hold2"
        case 3:  return tapKey + ".hold3"
        default: return tapKey + ".hold"
        }
    }

    /// The configured threshold (seconds) at which a hold stage is reached.
    private func holdStageThreshold(_ stage: Int) -> TimeInterval {
        switch stage {
        case 2:  return holdThreshold2
        case 3:  return holdThreshold3
        default: return holdThreshold
        }
    }

    /// Run a long-press (`<key>.hold*`) action, fired on release by `fireHoldStage`. `ring.up.hold`
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
    private func startKeyRepeat(_ buttonName: String, tapKey: String, keys: String,
                                delay: Double, interval: Double) {
        stopKeyRepeat(buttonName)   // defensive: never stack two repeats on one button

        // First fire via the controller so it logs and honors the config path (executor
        // synthesizes a single keystroke for `.repeatKey`).
        if controller?.handle(InputEvent(key: tapKey)) == true { print("🔘 \(tapKey) ⟳ (config)") }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + delay, repeating: interval)
        timer.setEventHandler { Keys.synthesize(keys) }
        repeatTimers[buttonName] = timer
        timer.resume()
    }

    /// Stop and clear the auto-repeat timer for `buttonName` (on release, a new press, or teardown).
    private func stopKeyRepeat(_ buttonName: String) {
        if let timer = repeatTimers.removeValue(forKey: buttonName) { timer.cancel() }
    }

    private func stopAllKeyRepeats() {
        for (_, timer) in repeatTimers { timer.cancel() }
        repeatTimers.removeAll()
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

    /// Fire a completed tap. With no `<key>.double` binding the single fires immediately (zero
    /// latency). With a `.double` binding the single is held for `doubleTapWindow`: the first tap
    /// schedules `<key>`; a 2nd tap inside the window cancels that pending single and fires
    /// `<key>.double` instead — so a double-tap emits ONLY the double, never a single too.
    private func fireTapOrDouble(_ buttonName: String, tapKey: String) {
        guard let controller = controller else { return }
        let doubleKey = tapKey + ".double"

        // No double binding → nothing to disambiguate; fire the single now.
        guard controller.hasBinding(for: doubleKey) else {
            if controller.handle(InputEvent(key: tapKey)) { print("🔘 \(tapKey) (config)") }
            return
        }

        if let pending = pendingSingle.removeValue(forKey: buttonName) {
            // 2nd tap within the window → it's a double. Cancel the queued single, fire the double.
            pending.cancel()
            if controller.handle(InputEvent(key: doubleKey)) { print("🔘 \(doubleKey) (config)") }
        } else {
            // 1st tap → hold the single; fire it only if no 2nd tap arrives within the window.
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let controller = self.controller else { return }
                self.pendingSingle[buttonName] = nil
                if controller.handle(InputEvent(key: tapKey)) { print("🔘 \(tapKey) (config)") }
            }
            pendingSingle[buttonName] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
        }
    }
    
    private func handleSelectButton(pressed: Bool) {
        if pressed { noteLayerUsedByOtherInput() }   // center-click while holding a layer = momentary use
        if pressed && !isSelectPressed {
            isSelectPressed = true
            isDragging = false
            selectPressTime = mach_absolute_time()
            cursorController.isClickActive = true
            
            // Start drag after threshold
            DispatchQueue.main.asyncAfter(deadline: .now() + clickThreshold) { [weak self] in
                guard let self = self, self.isSelectPressed && !self.isDragging else { return }
                print("🔘 Select button: Drag started")
                self.isDragging = true
                self.cursorController.isDragging = true
                self.cursorController.mouseDown()
            }
        } else if !pressed && isSelectPressed {
            isSelectPressed = false
            
            if isDragging {
                print("🔘 Select button: Drag ended")
                cursorController.isDragging = false
                cursorController.mouseUp()
            } else {
                print("🔘 Select button: Click")
                cursorController.performClick()
            }
            isDragging = false
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.cursorController.isClickActive = false
            }
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
        case (0x0C, 0x20): return "mute"          // Mute (some remotes)
        
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
    
    /// Called on device removal to avoid stuck modifiers / timers if the remote disconnects mid-hold.
    private func releaseAllHeldKeys() {
        buttonState.removeAll()
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

    /// Cancel any double-tap-delayed single-tap work items (so a pending single can't fire after a
    /// disconnect / device swap).
    private func cancelPendingSingles() {
        for (_, item) in pendingSingle { item.cancel() }
        pendingSingle.removeAll()
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
    private func cancelHoldStages() {
        for (_, items) in holdStageTimers { items.forEach { $0.cancel() } }
        holdStageTimers.removeAll()
        deepestStage.removeAll()
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
