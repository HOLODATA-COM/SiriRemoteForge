//
//  TouchHandler.swift
//  HyperVibe
//
//  Handles Siri Remote trackpad input using Apple's private MultitouchSupport.framework
//

import Foundation
import CoreGraphics
import QuartzCore
import AppKit
import Darwin

/// Single-finger trackpad swipe directions (detected here, dispatched to the config as `swipe.<dir>`).
enum SwipeDirection: String, CaseIterable {
    case up, down, left, right
}

/// Output axis for the iPod-style outer-ring gesture.
enum CircularScrollAxis {
    case vertical
    case horizontal
}

/// Serialises the shared gesture state across several remote touch surfaces. A positive frame from
/// either remote takes ownership immediately; a stale zero-touch frame from the previous remote
/// cannot end the new remote's gesture.
struct ActiveTouchDeviceTracker<Key: Hashable> {
    private(set) var active: Key?

    mutating func beginOrContinue(_ key: Key) -> Bool {
        let switched = active != nil && active != key
        active = key
        return switched
    }

    mutating func endIfActive(_ key: Key) -> Bool {
        guard active == key else { return false }
        active = nil
        return true
    }

    mutating func reset() { active = nil }
}

private func touchCallback(device: MTDevice?,
                           touches: UnsafeMutablePointer<MTTouch>?,
                           numTouches: Int,
                           timestamp: Double,
                           frame: Int,
                           refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let handler = Unmanaged<TouchHandler>.fromOpaque(refcon).takeUnretainedValue()
    handler.handleTouches(device: device, touches: touches,
                          count: numTouches, timestamp: timestamp)
}

class TouchHandler {
    
    /// mach_absolute_time() is in machine-dependent units; convert to seconds via timebase.
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        if mach_timebase_info(&info) == 0 {
            return (info.numer, info.denom)
        }
        return (1, 1)
    }()
    
    private static func machDeltaToSeconds(from startMach: UInt64) -> Double {
        guard startMach > 0 else { return 0 }
        let now = mach_absolute_time()
        let delta = now >= startMach ? (now - startMach) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private let cursorController: CursorController
    private var devices: [UInt64: MTDevice] = [:]
    private var activeTouchDevice = ActiveTouchDeviceTracker<UInt64>()
    private let touchStateLock = NSLock()

    /// Sensor surface in 0.01 mm units, for anything that needs to draw the pad at true scale.
    var surfaceDimensions: CGSize? {
        guard let dev = devices.values.first else { return nil }
        var w: Int32 = 0, h: Int32 = 0
        MTDeviceGetSensorSurfaceDimensions(dev, &w, &h)
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: Int(w), height: Int(h))
    }
    private var reconnectTimer: Timer?
    private var fastReconnectTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    
    var scrollScale: CGFloat = 150.0
    
    private var lastTouchPosition: CGPoint?
    private var lastTouchCount = 0
    private var lastTouchTime: UInt64 = 0
    private var touchStartTime: UInt64 = 0
    private var touchStartPosition: CGPoint = .zero
    
    private let cursorScale: CGFloat = 500.0
    /// Cursor speed multiplier (config: settings.cursorSpeed). Lower = less sensitive.
    var cursorSpeed: CGFloat = 1.0
    /// Velocity-based pointer acceleration (config: settings.accel*). A gain layered on top of
    /// cursorSpeed: below `accelLowSpeed` (slow, deliberate motion) the multiplier is `accelMin`
    /// for precision; above `accelHighSpeed` (a quick flick) it caps at `accelMax` for reach;
    /// smoothstep in between. Thresholds are in the SAME normalized units as the per-frame delta
    /// magnitude (hypot(dx,dy)); the jitter deadzone is ~0.006, so the defaults sit between a slow
    /// deliberate drag (~0.008) and a quick flick (~0.06), with the multiplier ≈1.0 at typical
    /// medium move speed (~0.025) so mid-speed feel matches the old linear behavior.
    var accelMin: CGFloat = 0.4
    var accelMax: CGFloat = 2.6
    var accelLowSpeed: CGFloat = 0.008
    var accelHighSpeed: CGFloat = 0.06
    /// Bends the normalised smoothstep ramp. Kept separate from the gain/speed scales so it can be
    /// linked to circular scroll without mixing pointer delta/frame with ring radians/frame.
    var accelCurve: CGFloat = 1.0
    /// Per-frame jitter deadzone (config: settings.cursorDeadzone). Movement below this
    /// (normalized) is ignored so resting/pressing a finger doesn't drift the cursor.
    var cursorDeadzone: CGFloat = 0.006
    /// Circular-scroll (iPod wheel) config; all params are config-tunable and hot-reloadable.
    var circularConfig: CircularScrollConfig = .default {
        didSet { circularDetector.update(config: circularConfig) }
    }
    /// The base layer scrolls vertically. AppDelegate switches this to horizontal while L1 is active.
    var circularScrollAxis: CircularScrollAxis = .vertical
    private let circularDetector = CircularScrollDetector(config: .default)
    private var circularActive = false
    /// Whether THIS contact is allowed to become a circular scroll at all, decided once when the
    /// finger lands and never revisited.
    ///
    /// The ring test used to be per-frame, so a single stroke that began in the middle and ran out
    /// to the edge would start scrolling partway through: once past `minRadius`, continuing along
    /// the edge sweeps the angle, which is indistinguishable from deliberate circling. Deciding at
    /// touchdown makes one contact mean one thing. A stroke that starts in the middle moves the
    /// cursor for its whole life, however far out it wanders; a stroke that starts on the ring may
    /// still become a scroll once it has turned enough.
    ///
    /// The opposite direction was already safe: `circularActive` latches, and the scroll branch
    /// returns before the cursor is touched.
    private var circularEligible = false
    /// Set once this touch scrolls (circular or two-finger). A scrolling touch can NEVER also
    /// fire a swipe or tap — scroll and swipe are mutually exclusive within one touch.
    private var didScroll = false
    /// Whether this Layer 1 circular contact has emitted its `.began` event. Native horizontal
    /// scrollers require a complete began → changed → ended gesture stream.
    private var circularScrollPhaseStarted = false
    /// Layer 1's output axis is captured when its fluid gesture starts. Layer 0 intentionally
    /// remains on the original stateless vertical-wheel path.
    private var activeCircularScrollAxis: CircularScrollAxis?
    /// Native horizontal shelves consume the same pixel stream more conservatively than the
    /// established Layer 0 vertical path. This is a small final-output speed adjustment only;
    /// both layers still share the exact acceleration curve calculated upstream.
    private let layer1HorizontalSpeedScale: Double = 1.3
    /// Sub-pixel accumulator so smooth continuous rotation emits whole scroll pixels as they add up.
    private var scrollRemainder: Double = 0
    /// Press-to-click freeze: pressing to click makes contact (zTotal) spike upward. A per-frame
    /// rise above this threshold = a press starting → freeze the cursor for a short window so the
    /// press/release doesn't drift the pointer.
    var clickRiseThreshold: Double = 0.1
    /// A press is a contact spike WITH the finger nearly still. If it's moving more than this
    /// (normalized), it's a real cursor move — so a stray freeze is cancelled and the cursor never
    /// feels stuck ("断触").
    var pressMoveMax: Double = 0.025
    private var pressFreezeWindow = 15
    private var pressFreezeFrames = 0

    private var lastContact: Float = 0
    /// Position-follow smoothing for circular scroll: total scroll always equals total rotation ×
    /// speed (never over/under), and each frame eases toward that target (circularConfig.scrollEase)
    /// so jittery hand circling still scrolls smoothly.
    private var rotationTotal: Double = 0
    private var scrollEmitted: Double = 0
    private let tapMaxDuration: Double = 0.22
    private let tapMaxDistance: CGFloat = 0.07
    // Swipe detection: velocity-gated single-finger flick. Distance > 35% of trackpad in < 350ms,
    // with the dominant axis at least 2× the orthogonal axis (rejects diagonal wobble).
    private let swipeMinDistance: CGFloat = 0.35
    private let swipeMaxDuration: Double = 0.35
    private let swipeAxisRatio: CGFloat = 2.0
    private var hadMultipleFingersInSession = false

    /// Fired on touch-up when a single-finger flick is detected. Dispatched on main.
    var onSwipe: ((SwipeDirection) -> Void)?
    /// Fired on touch-up for a still two-finger tap (a two-finger drag scrolls instead).
    var onTwoFingerTap: (() -> Void)?
    /// Fired when the cursor is "shaken" (rapid horizontal back-and-forth) — used to trigger the
    /// find-my-cursor highlight. Dispatched on main. Wiring gates it on the enabled setting.
    var onShake: (() -> Void)?

    // MARK: - Shake-to-locate detection
    // Feeds the per-frame horizontal movement (post-deadzone, PRE-accel) into a sign-reversal
    // counter: each time dx flips sign while |dx| is above `shakeSpeedThreshold`, a reversal is
    // recorded; `shakeReversals` reversals within `shakeWindow` seconds fire `onShake`. Debounced
    // so it can't re-fire faster than `shakeDebounce`.
    /// Reversals required within the window to count as a shake.
    var shakeReversals: Int = 3
    /// Sliding window (seconds) the reversals must fall within.
    var shakeWindow: TimeInterval = 0.45
    /// Minimum per-frame |dx| (normalized units, same as the deadzone) for a frame to count —
    /// gates out slow drift so only a brisk shake triggers.
    var shakeSpeedThreshold: CGFloat = 0.02
    /// Minimum seconds between two shake fires.
    private let shakeDebounce: TimeInterval = 0.4
    private var shakeLastSign = 0
    private var shakeReversalTimes: [Double] = []
    private var shakeLastFireTime: Double = 0
    /// Highest finger count seen this touch session (to classify two-finger gestures on lift).
    private var sessionMaxFingers = 0
    private let reconnectInterval: TimeInterval = 2.0
    private let idleTimeout: TimeInterval = 90.0
    private let touchStarvationThreshold: TimeInterval = 15.0

    init(cursorController: CursorController) {
        self.cursorController = cursorController
    }
    
    deinit {
        stop()
    }
    
    func start() {
        findAndReconcileDevices(logInventory: true)
        startReconnectTimer()
        // Restart MT device after sleep (trackpad stops delivering until restarted).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restartTrackpadAfterWake()
        }
    }
    
    func stop() {
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        fastReconnectTimer?.invalidate()
        fastReconnectTimer = nil
        stopAllDevices()
    }
    
    /// Call when HID button activity is detected (e.g. after remote wake). Re-scans MT devices
    /// after HID activity. A newly connected second remote must be discovered even while the first
    /// touch surface is healthy, so this reconciles the complete set rather than returning early.
    func tryReconnectTrackpad() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.tryReconnectTrackpad() }
            return
        }
        let doScan = { [weak self] in
            self?.findAndReconcileDevices(logInventory: false)
        }
        doScan()
        // Device may re-enumerate shortly after HID activity; retry once after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { doScan() }
        // A connected surface already has the normal two-second reconciliation timer. Only use the
        // aggressive recovery loop when every touch surface is missing; otherwise every ordinary
        // button press would keep a needless 500 ms scan running for twenty seconds.
        guard devices.isEmpty else { return }
        fastReconnectTimer?.invalidate()
        let startDate = Date()
        fastReconnectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if Date().timeIntervalSince(startDate) > 20 {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            self.findAndReconcileDevices(logInventory: false)
        }
        if let timer = fastReconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func restartTrackpadAfterWake() {
        stopAllDevices()
        findAndReconcileDevices(logInventory: true)
    }

    private func deviceID(_ dev: MTDevice) -> UInt64 {
        var value: UInt64 = 0
        MTDeviceGetDeviceID(dev, &value)
        return value
    }
    
    private func describe(_ dev: MTDevice) -> String {
        let builtIn = MTDeviceIsBuiltIn(dev)
        var devID: UInt64 = 0; MTDeviceGetDeviceID(dev, &devID)
        var fam: Int32 = 0; MTDeviceGetFamilyID(dev, &fam)
        var w: Int32 = 0, h: Int32 = 0; MTDeviceGetSensorSurfaceDimensions(dev, &w, &h)
        return "builtIn=\(builtIn) id=\(devID) family=\(fam) surface=\(w)x\(h)"
    }

    /// The Siri Remote clickpad is a small square (~2775×2775 in 0.01 mm units); trackpads are
    /// far larger (>12000 on the long axis). Match the remote by its small surface so we never
    /// accidentally attach to a Magic Trackpad or the built-in trackpad.
    private func isRemoteSurface(_ dev: MTDevice) -> Bool {
        var w: Int32 = 0, h: Int32 = 0
        MTDeviceGetSensorSurfaceDimensions(dev, &w, &h)
        let maxDim = max(w, h)
        return maxDim > 0 && maxDim < 6000
    }

    private func findAndReconcileDevices(logInventory: Bool) {
        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else { return }
        let deviceList = cfArray as [MTDevice]
        if logInventory {
            rmDebug("📱 MTDeviceCreateList: \(deviceList.count) device(s)")
            for (i, dev) in deviceList.enumerated() {
                rmDebug("📱   [\(i)] \(describe(dev))")
            }
        }
        let remotes = deviceList.filter { !MTDeviceIsBuiltIn($0) && isRemoteSurface($0) }
        var liveByID: [UInt64: MTDevice] = [:]
        for remote in remotes {
            liveByID[deviceID(remote)] = remote
        }

        for id in Set(devices.keys).subtracting(liveByID.keys) {
            stopDevice(id: id)
        }
        for (id, remote) in liveByID {
            if let current = devices[id], MTDeviceIsRunning(current) { continue }
            if devices[id] != nil { stopDevice(id: id) }
            startDevice(remote, id: id)
        }
        if remotes.isEmpty {
            rmDebug("📱 no remote-sized multitouch device found; not attaching")
        }
    }
    
    private func startDevice(_ dev: MTDevice, id: UInt64) {
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        MTRegisterContactFrameCallbackWithRefcon(dev, touchCallback, refcon)
        MTDeviceStart(dev, 0)
        devices[id] = dev
        // Reset so we don't immediately re-enter starvation and restart every 2s when no touches yet.
        lastTouchTime = mach_absolute_time()
        rmDebug("📱 remote touch surface started id=\(id) activeSurfaces=\(devices.count)")
        print("📱 Trackpad device connected and started (\(devices.count) active)")
    }
    
    private func stopDevice(id: UInt64) {
        guard let dev = devices.removeValue(forKey: id) else { return }
        MTUnregisterContactFrameCallback(dev, touchCallback)
        MTDeviceStop(dev)
        touchStateLock.lock()
        if activeTouchDevice.endIfActive(id) { resetTouchSessionWithoutAction() }
        touchStateLock.unlock()
        rmDebug("📱 remote touch surface stopped id=\(id) activeSurfaces=\(devices.count)")
        print("📱 Trackpad device disconnected (\(devices.count) active)")
    }

    private func stopAllDevices() {
        for id in Array(devices.keys) { stopDevice(id: id) }
    }
    
    private func startReconnectTimer() {
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval, repeats: true) { [weak self] _ in
            self?.checkAndReconnect()
        }
        // Fire when app is in background (menu bar only); otherwise timer may not run.
        if let timer = reconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func checkAndReconnect() {
        let timeSinceLastTouch = lastTouchTime == 0 ? 0 : Self.machDeltaToSeconds(from: lastTouchTime)

        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else { return }
        let listed = cfArray as [MTDevice]
        let liveRemoteIDs = Set(listed.filter {
            !MTDeviceIsBuiltIn($0) && isRemoteSurface($0)
        }.map(deviceID))
        let knownIDs = Set(devices.keys)
        let hasStoppedDevice = devices.values.contains { !MTDeviceIsRunning($0) }

        // Reconcile immediately when a second surface appears or one disappears. If all known
        // surfaces have been silent long enough, restart the set to recover from remote sleep.
        if liveRemoteIDs != knownIDs || hasStoppedDevice || devices.isEmpty {
            findAndReconcileDevices(logInventory: true)
        } else if timeSinceLastTouch > touchStarvationThreshold
                    || (timeSinceLastTouch > idleTimeout && listed.count > 1) {
            stopAllDevices()
            findAndReconcileDevices(logInventory: true)
        }
    }
    
    /// `--dump-touches`: log every MTTouch field, to find out which the remote actually populates.
    /// We only ever read `normalizedVector.position` and `zTotal`; the struct carries more.
    /// Set to observe raw touch frames (the touch-monitor / Demo Mode windows). The multitouch
    /// callback and AppKit window lifecycle run on different threads, so changing this sink at
    /// runtime must be synchronized even though the sink itself is always invoked on main.
    private let rawTouchSinkLock = NSLock()
    private var rawTouchSink: (([TouchSnapshot]) -> Void)?
    var onRawTouch: (([TouchSnapshot]) -> Void)? {
        get {
            rawTouchSinkLock.lock()
            defer { rawTouchSinkLock.unlock() }
            return rawTouchSink
        }
        set {
            rawTouchSinkLock.lock()
            rawTouchSink = newValue
            rawTouchSinkLock.unlock()
        }
    }

    private let dumpTouches = CommandLine.arguments.contains("--dump-touches")
    private static var dumpCount = 0

    /// `--dump-z`: log only the contact-strength signals, for much longer, to find out how much
    /// dynamic range there is between a light touch and a firm press. The pad is capacitive, not
    /// force-sensing, so these measure coupling area rather than force — the question is whether
    /// that proxy separates cleanly enough to act on.
    private let dumpZ = CommandLine.arguments.contains("--dump-z")
    private static var zCount = 0

    /// `--dump-press`: every frame on a monotonic clock shared with the Select button events, so a
    /// press can be aligned against the touch signal and the lead time measured rather than guessed.
    private let dumpPress = CommandLine.arguments.contains("--dump-press")

    func handleTouches(device: MTDevice?, touches: UnsafeMutablePointer<MTTouch>?,
                       count: Int, timestamp: Double) {
        guard let device else { return }
        let sourceID = deviceID(device)
        touchStateLock.lock()
        defer { touchStateLock.unlock() }

        if count > 0 {
            if activeTouchDevice.beginOrContinue(sourceID) {
                // Switching surfaces is ownership transfer, not a lift from the prior surface.
                // Cancel its partial tap/swipe/scroll without firing an action, then let this frame
                // establish the new remote's clean anchor immediately.
                resetTouchSessionWithoutAction()
                rmDebug("📱 active touch surface switched to id=\(sourceID)")
            }
        } else if !activeTouchDevice.endIfActive(sourceID) {
            return
        }

        // Live monitor tap: every frame, verbatim, for the touch-monitor window. Nil in normal use.
        if let sink = onRawTouch {
            // A zero-contact callback may carry a nil pointer. Still publish an empty frame so a
            // monitor or Demo Mode never leaves the final contact frozen on screen.
            let snaps = touches.map { pointer in
                (0..<count).map { TouchSnapshot(pointer[$0]) }
            } ?? []
            DispatchQueue.main.async { sink(snaps) }
        }

        if dumpPress, let touches = touches {
            if count == 0 {
                rmDebug(String(format: "PRESSLOG t=%.4f n=0", CACurrentMediaTime()))
            } else {
                let t = touches[0]
                rmDebug(String(format:
                    "PRESSLOG t=%.4f n=%d z=%.4f d=%.4f maj=%.3f min=%.3f st=%d x=%.4f y=%.4f",
                    CACurrentMediaTime(), count, t.zTotal, t.zDensity,
                    t.majorAxis, t.minorAxis, t.state.rawValue,
                    t.normalizedVector.position.x, t.normalizedVector.position.y))
            }
        }

        if dumpZ, let touches = touches, count > 0, TouchHandler.zCount < 900 {
            let t = touches[0]
            TouchHandler.zCount += 1
            rmDebug(String(format: "📊 zTotal=%.4f zDensity=%.4f major=%.2f minor=%.2f state=%d n=(%.3f,%.3f)",
                           t.zTotal, t.zDensity, t.majorAxis, t.minorAxis,
                           t.state.rawValue, t.normalizedVector.position.x, t.normalizedVector.position.y))
        }
        if dumpTouches, let touches = touches, count > 0, TouchHandler.dumpCount < 40 {
            for i in 0..<count {
                let t = touches[i]
                TouchHandler.dumpCount += 1
                rmDebug(String(format:
                    "👆 n=(%.4f,%.4f) v=(%.3f,%.3f) | abs=(%.4f,%.4f) absV=(%.3f,%.3f) | "
                  + "zTotal=%.4f zDensity=%.4f | major=%.3f minor=%.3f angle=%.3f | "
                  + "state=%d finger=%d hand=%d path=%d f9=%d f14=%d f15=%d",
                    t.normalizedVector.position.x, t.normalizedVector.position.y,
                    t.normalizedVector.velocity.x, t.normalizedVector.velocity.y,
                    t.absoluteVector.position.x, t.absoluteVector.position.y,
                    t.absoluteVector.velocity.x, t.absoluteVector.velocity.y,
                    t.zTotal, t.zDensity,
                    t.majorAxis, t.minorAxis, t.angle,
                    t.state.rawValue, t.fingerID, t.handID, t.pathIndex,
                    t.field9, t.field14, t.field15))
            }
        }
        lastTouchTime = mach_absolute_time()
        countFrame(timestamp: timestamp)

        // The Power button is right beside the glass, so pressing it nearly always brushes the
        // trackpad. Inside the guard that brush must not move the cursor, tap, swipe, or restore
        // the brightness the press just dimmed. Frames are still counted above (wake/rate tracking
        // stays accurate); only the gesture handling is skipped. Dropping `lastTouchPosition` makes
        // whatever the finger is doing when the guard expires start as a fresh, clean touch instead
        // of jumping the cursor by the distance it drifted while suppressed.
        // Two separate guards, both of which mute the trackpad but for different reasons:
        //   • isInputGuarded  — Power was pressed; suppresses other inputs' actions too.
        //   • isTouchGuarded  — a click-ring/centre button was pressed, and those are pressed
        //     THROUGH the glass, so the same press also arrives here as a touch. Only the trackpad
        //     is muted; every other button keeps working.
        if RemoteInputHandler.isInputGuarded || RemoteInputHandler.isTouchGuarded {
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }

        guard count > 0, let touchPtr = touches else {
            // Touch ended
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        // Calculate average position of all active touches
        var avgX: Float = 0
        var avgY: Float = 0
        var activeTouchCount = 0
        var contactSize: Float = 0   // total contact "quality"/pressure — grows when you press to click

        for i in 0..<count {
            let touch = touchPtr[i]

            // Only process active touches
            if touch.state == MTTouchStateTouching || touch.state == MTTouchStateMakeTouch {
                avgX += touch.normalizedVector.position.x
                avgY += touch.normalizedVector.position.y
                contactSize += touch.zTotal
                activeTouchCount += 1
            }
        }
        
        guard activeTouchCount > 0 else {
            handleTouchEnd()
            lastTouchPosition = nil
            lastTouchCount = 0
            return
        }
        
        if activeTouchCount >= 2 {
            hadMultipleFingersInSession = true
        }
        sessionMaxFingers = max(sessionMaxFingers, activeTouchCount)

        avgX /= Float(activeTouchCount)
        avgY /= Float(activeTouchCount)
        
        let currentPos = CGPoint(x: CGFloat(avgX), y: CGFloat(avgY))
        
        // Handle touch start
        if lastTouchPosition == nil {
            hadMultipleFingersInSession = false
            circularActive = false
            didScroll = false
            circularScrollPhaseStarted = false
            activeCircularScrollAxis = nil
            scrollRemainder = 0
            rotationTotal = 0
            scrollEmitted = 0
            lastContact = contactSize
            pressFreezeFrames = 0
            // Where the finger landed decides what this contact is for. Same radius that defines
            // the ring, so "landed on the ring" and "is on the ring" cannot disagree.
            let landing = hypot(Double(currentPos.x) - 0.5, Double(currentPos.y) - 0.5)
            circularEligible = landing >= circularConfig.minRadius
            shakeLastSign = 0
            circularDetector.reset()
            cursorController.resetMoveAccumulator()
            Brightness.restoreIfDimmed()   // a touch also restores brightness if dimmed to minimum
            sessionMaxFingers = activeTouchCount
            touchStartTime = mach_absolute_time()
            touchStartPosition = currentPos
            lastTouchPosition = currentPos
            lastTouchCount = activeTouchCount
            return
        }
        
        // Calculate delta
        let deltaX = currentPos.x - (lastTouchPosition?.x ?? currentPos.x)
        let deltaY = currentPos.y - (lastTouchPosition?.y ?? currentPos.y)

        // Process based on finger count: 1 finger = cursor, 2 fingers = scroll
        if activeTouchCount == 1 && lastTouchCount == 1 {
            // Circular scroll (outer ring) preempts the cursor once rotation passes threshold.
            if circularConfig.enabled && circularEligible {
                let radians = circularDetector.feed(x: Double(currentPos.x), y: Double(currentPos.y))
                if radians != 0 { circularActive = true; didScroll = true }
                if circularActive {
                    // Velocity-based gain, the same idea as the cursor's pointer acceleration:
                    // circle slowly and the wheel stays slow and precise, circle fast and it covers
                    // ground. Without this the wheel was strictly 1:1 with rotation, so reaching the
                    // bottom of a long page meant many full turns.
                    //
                    // `radians` is per-frame rotation, so |radians| IS the angular speed in the
                    // units this curve is expressed in. The gain scales the increment before it is
                    // accumulated, which keeps the easing below unchanged — the wheel still follows
                    // a position target, it is just a gained one.
                    let omega = abs(CGFloat(radians))
                    var t = smoothstep(omega,
                                       CGFloat(circularConfig.accelLowSpeed),
                                       CGFloat(circularConfig.accelHighSpeed))
                    // Bend the ramp. smoothstep alone is symmetric; a wheel wants a long flat
                    // precise stretch before it climbs, which is what an exponent > 1 gives.
                    let curve = CGFloat(circularConfig.accelCurve)
                    if curve != 1, t > 0 { t = pow(t, curve) }
                    let gain = CGFloat(circularConfig.accelMin)
                        + (CGFloat(circularConfig.accelMax) - CGFloat(circularConfig.accelMin)) * t
                    rotationTotal += Double(radians) * Double(gain)
                    let target = rotationTotal * circularConfig.pixelsPerRadian
                    let step = (target - scrollEmitted) * circularConfig.scrollEase
                    scrollEmitted += step
                    emitCircularScroll(pixels: step)
                    lastTouchPosition = currentPos
                    lastTouchCount = activeTouchCount
                    return
                }
            }
            // Press-to-click freeze: pressing to click spikes contact (zTotal) upward. A sharp
            // per-frame rise = a press starting → freeze the cursor for a short window covering the
            // press + click + release. Also freeze while the physical click is held. Re-anchor so
            // it resumes cleanly.
            let rise = contactSize - lastContact
            lastContact = contactSize
            let fingerStill = Double(hypot(deltaX, deltaY)) < pressMoveMax
            // Press onset = contact spikes up WHILE the finger is nearly still.
            //
            // Deliberately a SINGLE-frame rise, not a cumulative one over a window. The window
            // version was tried and reverted: measurement said it should fire earlier, and it did —
            // but it also fired whenever the contact patch simply grew mid-slide, which stopped the
            // cursor dead in the middle of a stroke. Firing late and briefly is less intrusive than
            // firing early and wrongly.
            if Double(rise) > clickRiseThreshold && fingerStill {
                pressFreezeFrames = pressFreezeWindow
            }
            // Freeze during the physical click, or during a press-onset window — but only while the
            // finger stays still. Clear finger movement cancels a stray freeze immediately, so the
            // cursor never feels stuck.
            //
            // An active DRAG is exempt: holding select past stickyDragThreshold starts a drag
            // (RemoteInputHandler.handleSelectButton) whose whole purpose is to move the pointer
            // with the button down. `isClickActive` stays true for the entire hold, so without this
            // exemption the freeze swallowed every drag frame and press-and-drag did nothing at all
            // — the drag was started, mouseDown/mouseUp were posted, but the pointer never moved.
            // The freeze still applies for the first stickyDragThreshold of the hold, which is the part
            // that actually needs to be steady.
            let frozenByClick = cursorController.isClickActive && !cursorController.isDragging
            if frozenByClick || (pressFreezeFrames > 0 && fingerStill) {
                if pressFreezeFrames > 0 { pressFreezeFrames -= 1 }
                lastTouchPosition = currentPos
                lastTouchCount = activeTouchCount
                return
            }
            pressFreezeFrames = 0

            // Jitter deadzone: ignore sub-threshold frames and keep the anchor so slow
            // deliberate motion still accumulates across frames, but tremor nets ~zero.
            if hypot(deltaX, deltaY) < cursorDeadzone {
                lastTouchCount = activeTouchCount
                return
            }
            // Shake-to-locate: fed the post-deadzone, pre-accel horizontal delta of a real move.
            detectShake(dx: deltaX, timestamp: timestamp)
            moveCursor(deltaX: deltaX, deltaY: deltaY)
            lastTouchPosition = currentPos
        } else if activeTouchCount == 2 && lastTouchCount == 2 {
            // Two fingers: always scroll regardless of mode
            performScroll(deltaX: deltaX, deltaY: deltaY)
            if hypot(deltaX, deltaY) > 0.004 { didScroll = true }
            lastTouchPosition = currentPos
        } else {
            lastTouchPosition = currentPos
        }
        
        lastTouchCount = activeTouchCount
    }

    /// Drop an interrupted device's partial gesture without manufacturing a tap, swipe or click.
    /// Caller owns `touchStateLock`.
    private func resetTouchSessionWithoutAction() {
        endCircularScrollGestureIfNeeded()
        lastTouchPosition = nil
        lastTouchCount = 0
        lastContact = 0
        touchStartTime = 0
        touchStartPosition = .zero
        hadMultipleFingersInSession = false
        sessionMaxFingers = 0
        circularActive = false
        circularEligible = false
        didScroll = false
        circularScrollPhaseStarted = false
        activeCircularScrollAxis = nil
        scrollRemainder = 0
        rotationTotal = 0
        scrollEmitted = 0
        pressFreezeFrames = 0
        shakeLastSign = 0
        shakeReversalTimes.removeAll()
        circularDetector.reset()
        cursorController.resetMoveAccumulator()
    }
    
    /// Classify a flick delta into a swipe direction (nil if too diagonal).
    /// y increases toward the top of the trackpad in MultitouchSupport coordinates.
    private func swipeDirection(dx: CGFloat, dy: CGFloat) -> SwipeDirection? {
        let absDx = abs(dx), absDy = abs(dy)
        if absDx > absDy * swipeAxisRatio { return dx > 0 ? .right : .left }
        if absDy > absDx * swipeAxisRatio { return dy > 0 ? .up : .down }
        return nil
    }

    private func handleTouchEnd() {
        guard lastTouchPosition != nil else { return }

        // Hard rule: if this touch scrolled (circular ring or two-finger), it is ONLY a scroll —
        // never also a swipe or tap. Scroll and swipe are mutually exclusive within one touch.
        if didScroll {
            endCircularScrollGestureIfNeeded()
            didScroll = false
            circularActive = false
            return
        }

        // Don't trigger tap if physical click button is active
        if cursorController.isClickActive {
            return
        }
        let duration = Self.machDeltaToSeconds(from: touchStartTime)
        let dx = (lastTouchPosition?.x ?? 0) - touchStartPosition.x
        let dy = (lastTouchPosition?.y ?? 0) - touchStartPosition.y
        let movement = hypot(dx, dy)

        // Two fingers that did NOT scroll → a quick still two-finger tap (right-click by default).
        // A two-finger drag scrolled and was already handled by the didScroll lock above.
        if sessionMaxFingers >= 2 {
            if duration < tapMaxDuration, movement < tapMaxDistance {
                DispatchQueue.main.async { [weak self] in self?.onTwoFingerTap?() }
            }
            return
        }

        // One-finger swipe (flick). Distance threshold is well above tapMaxDistance, so a swipe
        // can never also register as a tap.
        if duration < swipeMaxDuration, movement > swipeMinDistance,
           let direction = swipeDirection(dx: dx, dy: dy) {
            DispatchQueue.main.async { [weak self] in self?.onSwipe?(direction) }
            return
        }

        if duration < tapMaxDuration && movement < tapMaxDistance {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.cursorController.performClick()
            }
        }
    }
    
    /// smoothstep(v, lo, hi): 0 below lo, 1 above hi, smooth (ease-in/out) in between.
    private func smoothstep(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        guard hi > lo else { return v < lo ? 0 : 1 }
        let t = min(max((v - lo) / (hi - lo), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private func moveCursor(deltaX: CGFloat, deltaY: CGFloat) {
        // Velocity-based acceleration: slow finger motion → precise (accelMin), fast → reach
        // (accelMax), smooth between. v is the per-frame delta magnitude (same normalized units
        // as the deadzone). This is the ONLY place the delta is scaled (CursorController no longer
        // double-scales), so the accel curve fully controls the feel.
        let v = hypot(deltaX, deltaY)
        var t = smoothstep(v, accelLowSpeed, accelHighSpeed)
        if accelCurve != 1, t > 0 { t = pow(t, accelCurve) }
        let accelMul = accelMin + (accelMax - accelMin) * t
        let effectiveSpeed = cursorSpeed * accelMul
        let scaledX = deltaX * cursorScale * effectiveSpeed
        let scaledY = -deltaY * cursorScale * effectiveSpeed

        // Post directly on the multitouch callback thread — CursorController.moveCursor is
        // CoreGraphics-only and thread-safe, so there is NO main-thread hop (that per-frame
        // `DispatchQueue.main.sync` was the main source of cursor stutter).
        cursorController.moveCursor(deltaX: scaledX, deltaY: scaledY)
    }
    
    /// Shake detector: count horizontal sign reversals of brisk motion; fire `onShake` when
    /// `shakeReversals` land within `shakeWindow`. `now` is the MT frame timestamp (seconds).
    private func detectShake(dx: CGFloat, timestamp now: Double) {
        guard onShake != nil else { return }
        // Only frames with brisk horizontal motion participate; slow drift neither counts nor
        // resets the tracked sign.
        guard abs(dx) >= shakeSpeedThreshold else { return }
        let sign = dx > 0 ? 1 : -1
        if shakeLastSign != 0 && sign != shakeLastSign {
            shakeReversalTimes.append(now)
            shakeReversalTimes.removeAll { now - $0 > shakeWindow }
            if shakeReversalTimes.count >= shakeReversals && now - shakeLastFireTime > shakeDebounce {
                shakeLastFireTime = now
                shakeReversalTimes.removeAll()
                DispatchQueue.main.async { [weak self] in self?.onShake?() }
            }
        }
        shakeLastSign = sign
    }

    // MARK: - Frame-rate measurement (diagnostic)
    private var frameCount = 0
    private var frameWindowStart: Double = 0
    /// Log the touch report rate ~once/sec while a finger is down, to quantify the remote's BLE
    /// sampling ceiling vs. our processing. `timestamp` is the MT frame time in seconds.
    private func countFrame(timestamp: Double) {
        if frameWindowStart == 0 { frameWindowStart = timestamp }
        frameCount += 1
        let elapsed = timestamp - frameWindowStart
        if elapsed >= 1.0 {
            rmDebug(String(format: "⏱ touch rate: %.0f Hz (%d frames / %.2fs)", Double(frameCount) / elapsed, frameCount, elapsed))
            frameCount = 0
            frameWindowStart = timestamp
        }
    }

    /// Emit smooth circular scroll: carry the sub-pixel remainder so a steady rotation scrolls
    /// evenly instead of stepping between whole pixels.
    private func emitCircularScroll(pixels: Double) {
        let axis = activeCircularScrollAxis ?? circularScrollAxis
        let outputScale = axis == .horizontal ? layer1HorizontalSpeedScale : 1.0
        scrollRemainder += pixels * outputScale
        let whole = scrollRemainder.rounded(.towardZero)
        guard whole != 0 else { return }
        scrollRemainder -= whole
        let delta = Int32(whole)
        switch axis {
        case .vertical:
            // This is the exact pre-L1 Layer 0 event path. Do not add phase or continuous-gesture
            // state here: its established behavior is the reference that L1 must follow.
            DispatchQueue.main.async { [weak self] in
                self?.cursorController.scroll(deltaX: 0, deltaY: delta)
            }
        case .horizontal:
            let phase: ContinuousScrollPhase = circularScrollPhaseStarted ? .changed : .began
            if !circularScrollPhaseStarted {
                circularScrollPhaseStarted = true
                activeCircularScrollAxis = .horizontal
            }
            DispatchQueue.main.async { [weak self] in
                // Core Graphics' fluid horizontal axis has the opposite visual direction from the
                // established Layer 0 wheel path. Flip only the final X-axis projection; the
                // shared acceleration/easing value (`delta`) itself remains unchanged.
                self?.cursorController.scrollContinuousHorizontal(deltaX: -delta, phase: phase)
            }
        }
    }

    private func endCircularScrollGestureIfNeeded() {
        guard circularScrollPhaseStarted else { return }
        circularScrollPhaseStarted = false
        activeCircularScrollAxis = nil
        DispatchQueue.main.async { [weak self] in
            self?.cursorController.scrollContinuousHorizontal(deltaX: 0, phase: .ended)
        }
    }

    private func performScroll(deltaX: CGFloat, deltaY: CGFloat) {
        let scrollX = Int32(-deltaX * scrollScale)
        let scrollY = Int32(deltaY * scrollScale)
        
        DispatchQueue.main.async { [weak self] in
            self?.cursorController.scroll(deltaX: scrollX, deltaY: scrollY)
        }
    }
}
