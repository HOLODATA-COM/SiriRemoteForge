//
//  TouchHandler.swift
//  HyperVibe
//
//  Handles Siri Remote trackpad input using Apple's private MultitouchSupport.framework
//

import Foundation
import CoreGraphics
import AppKit
import Darwin

/// Single-finger trackpad swipe directions (detected here, dispatched to the config as `swipe.<dir>`).
enum SwipeDirection: String, CaseIterable {
    case up, down, left, right
}

private func touchCallback(device: MTDevice?,
                           touches: UnsafeMutablePointer<MTTouch>?,
                           numTouches: Int,
                           timestamp: Double,
                           frame: Int,
                           refcon: UnsafeMutableRawPointer?) {
    guard let refcon = refcon else { return }
    let handler = Unmanaged<TouchHandler>.fromOpaque(refcon).takeUnretainedValue()
    handler.handleTouches(touches: touches, count: numTouches, timestamp: timestamp)
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
    private var device: MTDevice?
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
    /// Per-frame jitter deadzone (config: settings.cursorDeadzone). Movement below this
    /// (normalized) is ignored so resting/pressing a finger doesn't drift the cursor.
    var cursorDeadzone: CGFloat = 0.006
    /// Circular-scroll (iPod wheel) config; all params are config-tunable and hot-reloadable.
    var circularConfig: CircularScrollConfig = .default {
        didSet { circularDetector.update(config: circularConfig) }
    }
    private let circularDetector = CircularScrollDetector(config: .default)
    private var circularActive = false
    /// Set once this touch scrolls (circular or two-finger). A scrolling touch can NEVER also
    /// fire a swipe or tap — scroll and swipe are mutually exclusive within one touch.
    private var didScroll = false
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
        findAndStartDevice()
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
        stopDevice()
    }
    
    /// Call when HID button activity is detected (e.g. after remote wake). Re-scans MT devices
    /// only when we don't have a device, so we can reattach if it reappeared. If we already
    /// have a working device, do nothing — restarting on every button press would break the trackpad.
    func tryReconnectTrackpad() {
        guard device == nil else { return }
        let doScan = { [weak self] in
            guard self?.device == nil else { return }
            self?.findAndStartDevice()
        }
        if Thread.isMainThread {
            doScan()
        } else {
            DispatchQueue.main.async { doScan() }
        }
        // Device may re-enumerate shortly after HID activity; retry once after a short delay.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { doScan() }
        // Poll more often for a limited time so we attach as soon as the trackpad reappears.
        fastReconnectTimer?.invalidate()
        let startDate = Date()
        fastReconnectTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.device != nil {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            if Date().timeIntervalSince(startDate) > 20 {
                timer.invalidate()
                self.fastReconnectTimer = nil
                return
            }
            self.findAndStartDevice()
        }
        if let timer = fastReconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }
    
    private func restartTrackpadAfterWake() {
        stopDevice()
        findAndStartDevice()
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

    private func findAndStartDevice() {
        guard let cfArray = MTDeviceCreateList()?.takeRetainedValue() else { return }
        let deviceList = cfArray as [MTDevice]
        rmDebug("📱 MTDeviceCreateList: \(deviceList.count) device(s)")
        for (i, dev) in deviceList.enumerated() {
            rmDebug("📱   [\(i)] \(describe(dev))")
        }
        // Attach to the remote specifically (small surface), never a trackpad.
        if let remote = deviceList.first(where: { !MTDeviceIsBuiltIn($0) && isRemoteSurface($0) }) {
            rmDebug("📱 selecting remote (small surface): \(describe(remote))")
            startDevice(remote)
            return
        }
        // No remote-sized device present: do not hijack a trackpad; wait for the remote to appear.
        rmDebug("📱 no remote-sized multitouch device found; not attaching")
        if device != nil { stopDevice() }
    }
    
    private func startDevice(_ dev: MTDevice) {
        stopDevice()
        device = dev
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        MTRegisterContactFrameCallbackWithRefcon(dev, touchCallback, refcon)
        MTDeviceStart(dev, 0)
        // Reset so we don't immediately re-enter starvation and restart every 2s when no touches yet.
        lastTouchTime = mach_absolute_time()
        print("📱 Trackpad device connected and started")
    }
    
    private func stopDevice() {
        guard let dev = device else { return }
        MTUnregisterContactFrameCallback(dev, touchCallback)
        MTDeviceStop(dev)
        device = nil
        
        print("📱 Trackpad device disconnected")
        lastTouchPosition = nil
        lastTouchCount = 0
        hadMultipleFingersInSession = false
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
        let deviceCount = CFArrayGetCount(cfArray)

        // Restart if we have a device ref but the driver stopped (e.g. after remote sleep).
        if let dev = device, !MTDeviceIsRunning(dev) {
            findAndStartDevice()
            return
        }
        // Restart if we have a device but no touch events for a while (remote slept; no "remote wake" API).
        if device != nil && timeSinceLastTouch > touchStarvationThreshold {
            findAndStartDevice()
            return
        }
        if device == nil || (timeSinceLastTouch > idleTimeout && deviceCount > 1) {
            findAndStartDevice()
        }
    }
    
    func handleTouches(touches: UnsafeMutablePointer<MTTouch>?, count: Int, timestamp: Double) {
        lastTouchTime = mach_absolute_time()
        countFrame(timestamp: timestamp)

        // The Power button is right beside the glass, so pressing it nearly always brushes the
        // trackpad. Inside the guard that brush must not move the cursor, tap, swipe, or restore
        // the brightness the press just dimmed. Frames are still counted above (wake/rate tracking
        // stays accurate); only the gesture handling is skipped. Dropping `lastTouchPosition` makes
        // whatever the finger is doing when the guard expires start as a fresh, clean touch instead
        // of jumping the cursor by the distance it drifted while suppressed.
        if RemoteInputHandler.isInputGuarded {
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
            scrollRemainder = 0
            rotationTotal = 0
            scrollEmitted = 0
            lastContact = contactSize
            pressFreezeFrames = 0
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
            if circularConfig.enabled {
                let radians = circularDetector.feed(x: Double(currentPos.x), y: Double(currentPos.y))
                if radians != 0 { circularActive = true; didScroll = true }
                if circularActive {
                    // Position-follow: total scroll tracks total rotation exactly (never faster),
                    // but eased each frame so jittery circling still scrolls smoothly.
                    rotationTotal += Double(radians)
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
            if Double(rise) > clickRiseThreshold && fingerStill {
                pressFreezeFrames = pressFreezeWindow
            }
            // Freeze during the physical click, or during a press-onset window — but only while the
            // finger stays still. Clear finger movement cancels a stray freeze immediately, so the
            // cursor never feels stuck.
            //
            // An active DRAG is exempt: holding select past clickThreshold starts a drag
            // (RemoteInputHandler.handleSelectButton) whose whole purpose is to move the pointer
            // with the button down. `isClickActive` stays true for the entire hold, so without this
            // exemption the freeze swallowed every drag frame and press-and-drag did nothing at all
            // — the drag was started, mouseDown/mouseUp were posted, but the pointer never moved.
            // The freeze still applies for the first clickThreshold of the hold, which is the part
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
        let t = smoothstep(v, accelLowSpeed, accelHighSpeed)
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
        scrollRemainder += pixels
        let whole = scrollRemainder.rounded(.towardZero)
        guard whole != 0 else { return }
        scrollRemainder -= whole
        let dy = Int32(whole)
        DispatchQueue.main.async { [weak self] in
            self?.cursorController.scroll(deltaX: 0, deltaY: dy)
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
