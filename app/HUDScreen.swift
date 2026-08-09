//
//  HUDScreen.swift
//  HyperVibe
//
//  Stable display identity for one-HUD-window-per-screen mirroring.
//

import AppKit
import CoreGraphics

extension NSScreen {
    /// Stable identity used to keep one HUD window per physical display. `NSScreen` instances can
    /// be recreated when the display arrangement changes, so object identity is not sufficient.
    var hudDisplayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

}
