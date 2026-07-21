//
//  Brightness.swift
//  HyperVibe (config engine integration)
//
//  Dim / restore ALL displays by synthesizing the hardware brightness keys
//  (NX_KEYTYPE_BRIGHTNESS_UP/DOWN, as NX_SYSDEFINED subtype-8 events) — exactly like pressing
//  F1/F2, so every display moves (including externals that DisplayServicesSetBrightness misses),
//  one notch at a time (a gradual dim/restore).
//
//  "Should we restore?" is decided on the MAIN thread by BOTH an `isDimmed` flag (for dims WE did)
//  AND a live brightness read via DisplayServices (so a manual/keyboard-dimmed screen is also
//  restored when you touch the remote). Reading must be on main — off the trackpad's background
//  callback thread the read is unreliable, which is why touch didn't restore before.
//

import Foundation
import CoreGraphics
import AppKit

enum Brightness {
    private static var isDimmed = false

    /// Stamped into every brightness key we synthesize so `MediaKeyInterceptor`'s tap can discard
    /// them with a single integer read, before the (comparatively expensive) `NSEvent(cgEvent:)`
    /// conversion.
    ///
    /// Why this matters: a dim is 16 key taps (32 events) posted from the main thread, and the tap's
    /// run-loop source lives on that same main thread — so every synthesized event came straight
    /// back into our own callback. A dim and a restore overlapping doubled that to ~64 callbacks
    /// while the main thread was still generating them, starving the tap. A starved tap stops
    /// seeing events, so the remote's power-button events reached loginwindow and slept the Mac.
    /// That is what made the lock intermittent rather than consistent.
    static let syntheticEventMarker: Int64 = 0x53524D42  // 'SRMB'

    // MARK: - Read current brightness (DisplayServices, dlsym'd — no linker flag)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetFn? = {
        guard let h = handle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(p, to: GetFn.self)
    }()
    /// Current brightness, read from whichever display will actually answer.
    ///
    /// NOT `CGMainDisplayID()`: `DisplayServicesGetBrightness` fails on many external panels, and
    /// when an external display is the *main* one the read failed every single time. That silently
    /// disabled this whole fallback — restore then depended entirely on the `isDimmed` flag, and if
    /// the flag was ever lost the screen could not be brought back at all. Reading any responsive
    /// display is representative anyway, because `dimToMin`/`restoreToMax` drive brightness KEYS,
    /// which move every display together.
    private static func mainValue() -> Float? {
        guard let getBrightness = getBrightness else { return nil }

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success, count > 0 else { return nil }

        // Built-in first — it is the one that reliably answers; externals are hit or miss.
        let active = Array(ids.prefix(Int(count)))
        let ordered = active.filter { CGDisplayIsBuiltin($0) != 0 }
                    + active.filter { CGDisplayIsBuiltin($0) == 0 }

        for id in ordered {
            var v: Float = 0
            if getBrightness(id, &v) == 0 { return v }
        }
        return nil
    }

    // MARK: - Set via synthesized brightness keys (moves every display, notch by notch)

    private static let brightnessUp:   Int32 = 2   // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown: Int32 = 3   // NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let notches = 16                // full brightness range in key steps

    /// Bumped whenever a new ramp starts, so an in-flight ramp in the opposite direction stops
    /// instead of interleaving with it. A dim and a restore running at once both doubled the
    /// main-thread event load and left the final brightness anywhere between the two.
    private static var rampGeneration = 0

    /// Dim every display to minimum (Power button). Marks us dimmed for the restore guard.
    static func dimToMin() {
        isDimmed = true
        DispatchQueue.main.async {
            rampGeneration += 1
            rampKey(brightnessDown, remaining: notches, generation: rampGeneration)
        }
    }

    /// Raise every display back to maximum (one notch at a time) and clear the dimmed flag.
    static func restoreToMax() {
        isDimmed = false
        DispatchQueue.main.async {
            rampGeneration += 1
            rampKey(brightnessUp, remaining: notches, generation: rampGeneration)
        }
    }

    /// If the displays are currently at/near minimum brightness — either because WE dimmed them
    /// (flag) OR because they were dimmed some other way (live read < `threshold`) — restore to max.
    /// A normal press at normal brightness (flag clear + read above threshold) is a no-op.
    /// Rate-limits the diagnostic below — this runs on every button press and every touch start.
    private static var lastDiagLog: UInt64 = 0

    static func restoreIfDimmed(threshold: Float = 0.05) {
        let check = {
            let measured = mainValue()
            // Fail CLOSED when the read fails. Failing open was tried and was wrong: on a Mac whose
            // main display is an external panel the read failed *every* time, so every button press
            // and every touch ramped the brightness up. Now that `mainValue()` falls back to a
            // display that answers, a nil here means no display would report at all — rare enough
            // that `isDimmed` covers the normal path, and staying put beats raising brightness
            // constantly.
            let dimmed = isDimmed || (measured.map { $0 < threshold } ?? false)

            // Log only near-dim situations, at most once a second. Enough to tell apart the ways
            // "shaking it in the morning doesn't bring the screen back" can happen: the flag was
            // lost (isDimmed=false), the brightness read failed (measured=nil, which makes the
            // fallback fail CLOSED and never restore), or the main display reads bright while
            // another display is the dark one.
            if isDimmed || (measured ?? 1) < 0.15 {
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastDiagLog > 1_000_000_000 {
                    lastDiagLog = now
                    rmDebug(String(format: "💡 restoreIfDimmed: isDimmed=%@ measured=%@ → %@",
                                   isDimmed ? "Y" : "N",
                                   measured.map { String(format: "%.3f", $0) } ?? "nil(read failed)",
                                   dimmed ? "RESTORE" : "declined"))
                }
            }

            guard dimmed else { return }
            restoreToMax()
            rmDebug("💡 brightness: restore → max")
        }
        if Thread.isMainThread { check() } else { DispatchQueue.main.async(execute: check) }
    }

    /// Tap the key once per notch, spaced out on the main runloop — rapid-fire system events get
    /// coalesced/dropped, and NSEvent creation must be on the main thread.
    private static func rampKey(_ keyCode: Int32, remaining: Int, generation: Int) {
        // A newer ramp supersedes this one — stop rather than fight it.
        guard generation == rampGeneration, remaining > 0 else { return }
        tapAuxKey(keyCode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            rampKey(keyCode, remaining: remaining - 1, generation: generation)
        }
    }

    private static func tapAuxKey(_ keyCode: Int32) {
        postAuxKey(keyCode, down: true)
        postAuxKey(keyCode, down: false)
    }

    /// Synthesize an NX_SYSDEFINED "aux control" key event (subtype 8) — the media/brightness key
    /// path. data1 packs the key code and the up/down state.
    private static func postAuxKey(_ keyCode: Int32, down: Bool) {
        let data1 = (Int(keyCode) << 16) | ((down ? 0xa : 0xb) << 8)
        guard let ev = NSEvent.otherEvent(
            with: .systemDefined, location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00),
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 8, data1: data1, data2: -1) else { return }
        guard let cg = ev.cgEvent else { return }
        // Mark it as ours so our own event tap can skip it cheaply — see `syntheticEventMarker`.
        cg.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
        cg.post(tap: .cghidEventTap)
    }
}
