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

    // MARK: - Read current brightness (DisplayServices, dlsym'd — no linker flag)

    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getBrightness: GetFn? = {
        guard let h = handle, let p = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(p, to: GetFn.self)
    }()
    private static func mainValue() -> Float? {
        guard let getBrightness = getBrightness else { return nil }
        var v: Float = 0
        return getBrightness(CGMainDisplayID(), &v) == 0 ? v : nil
    }

    // MARK: - Set via synthesized brightness keys (moves every display, notch by notch)

    private static let brightnessUp:   Int32 = 2   // NX_KEYTYPE_BRIGHTNESS_UP
    private static let brightnessDown: Int32 = 3   // NX_KEYTYPE_BRIGHTNESS_DOWN
    private static let notches = 16                // full brightness range in key steps

    /// Dim every display to minimum (Power button). Marks us dimmed for the restore guard.
    static func dimToMin() {
        isDimmed = true
        DispatchQueue.main.async { rampKey(brightnessDown, remaining: notches) }
    }

    /// Raise every display back to maximum (one notch at a time) and clear the dimmed flag.
    static func restoreToMax() {
        isDimmed = false
        DispatchQueue.main.async { rampKey(brightnessUp, remaining: notches) }
    }

    /// If the displays are currently at/near minimum brightness — either because WE dimmed them
    /// (flag) OR because they were dimmed some other way (live read < `threshold`) — restore to max.
    /// A normal press at normal brightness (flag clear + read above threshold) is a no-op.
    static func restoreIfDimmed(threshold: Float = 0.05) {
        let check = {
            let dimmed = isDimmed || (mainValue().map { $0 < threshold } ?? false)
            guard dimmed else { return }
            restoreToMax()
            rmDebug("💡 brightness: restore → max")
        }
        if Thread.isMainThread { check() } else { DispatchQueue.main.async(execute: check) }
    }

    /// Tap the key once per notch, spaced out on the main runloop — rapid-fire system events get
    /// coalesced/dropped, and NSEvent creation must be on the main thread.
    private static func rampKey(_ keyCode: Int32, remaining: Int) {
        guard remaining > 0 else { return }
        tapAuxKey(keyCode)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.012) {
            rampKey(keyCode, remaining: remaining - 1)
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
        ev.cgEvent?.post(tap: .cghidEventTap)
    }
}
