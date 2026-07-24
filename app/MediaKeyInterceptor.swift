//
//  MediaKeyInterceptor.swift
//  Remotastic
//
//  Intercepts system media key events at HID level to reliably prevent default handling.
//  Re-enables tap when disabled by timeout/sleep and on wake.
//

import Cocoa
import CoreGraphics

class MediaKeyInterceptor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    /// Polls that the tap is still enabled — see the comment where it is created.
    private var healthTimer: Timer?

    
    var onMediaKey: ((MediaKeyType) -> Bool)?

    enum MediaKeyType {
        case playPause, next, previous, volumeUp, volumeDown, mute
    }
    
    func start() {
        let eventMask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        
        // HID-level tap intercepts media keys before the system handles them (more reliable than session tap).
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                return interceptor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            // Never fail silently: without this tap the remote's power button reaches loginwindow
            // and sleeps/locks the Mac, which looks like a random bug rather than a missing
            // permission. tapCreate returns nil when the process is not trusted for Accessibility.
            rmDebug("❌ MediaKeyInterceptor: CGEvent.tapCreate FAILED — check Accessibility permission")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            rmDebug("✅ MediaKeyInterceptor: event tap installed and enabled")
        }

        // The system can disable a tap at any time (slow callback, sleep/wake, user input) and the
        // notification is not always delivered to our callback. When that happens the interception
        // silently stops and the power button starts locking the Mac again. Poll cheaply and
        // re-arm, so a disabled tap self-heals instead of degrading until the next relaunch.
        let health = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self, let tap = self.eventTap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                rmDebug("⚠️ MediaKeyInterceptor: tap found disabled — re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        // .common, not the default mode: during run-loop tracking (an open menu-bar menu, a slider
        // drag, a window resize) a default-mode timer does not fire, while the tap's own source and
        // the HID devices keep running. That is precisely when this backstop is needed — a tap
        // disabled during tracking would otherwise stay dead until tracking ended, and a Power press
        // in that window reaches loginwindow and locks the Mac.
        RunLoop.main.add(health, forMode: .common)
        healthTimer = health
        
        // Re-enable tap after sleep/wake (system often disables taps during sleep).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reenableTap()
        }
    }
    
    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }
    
    /// Re-enable the event tap after it was disabled by timeout or sleep.
    func reenableTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap when system disables it (timeout or user input); then consume the event.
        // Logging here is safe: this branch is rare, unlike the per-event hot path below.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            rmDebug("🩺 TAP DISABLED by \(type == .tapDisabledByTimeout ? "timeout" : "userInput") — re-enabling")
            reenableTap()
            return nil
        }
        
        // NX_SYSDEFINED = 14
        guard type.rawValue == 14 else {
            return Unmanaged.passRetained(event)
        }

        // Discard our own synthesized brightness keys before doing any expensive work. A dim posts
        // 32 of these from the main thread, which is also where this tap's run-loop source lives;
        // converting each one to an NSEvent here starved the tap and let power events slip through
        // to loginwindow. This integer read is cheap enough to keep the callback fast.
        if event.getIntegerValueField(.eventSourceUserData) == Brightness.syntheticEventMarker {
            return Unmanaged.passRetained(event)
        }
        
        // Get NSEvent to parse the media key
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passRetained(event)
        }


        // Check subtype 8 = media key event
        guard nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passRetained(event)
        }
        
        // Parse the key code from data1
        let keyCode = Int32((nsEvent.data1 & 0xFFFF0000) >> 16)
        let keyFlags = nsEvent.data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == 0x0A
        
        // Only handle key down events
        guard isKeyDown else {
            return Unmanaged.passRetained(event)
        }
        
        // Identify the media key
        var mediaKey: MediaKeyType?
        switch keyCode {
        case NX_KEYTYPE_PLAY:
            mediaKey = .playPause
        case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST:
            mediaKey = .next
        case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND:
            mediaKey = .previous
        case NX_KEYTYPE_SOUND_UP:
            mediaKey = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN:
            mediaKey = .volumeDown
        case NX_KEYTYPE_MUTE:
            mediaKey = .mute
        default:
            break
        }
        
        if let key = mediaKey, let handler = onMediaKey, handler(key) {
            return nil // Consume event
        }
        
        return Unmanaged.passRetained(event)
    }
    
    deinit {
        stop()
    }
}
