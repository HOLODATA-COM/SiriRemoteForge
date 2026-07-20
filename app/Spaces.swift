//
//  Spaces.swift
//  HyperVibe (config engine integration)
//
//  Switch macOS Spaces (desktops) directly via the private SkyLight/CGS API, because synthesized
//  keyboard shortcuts don't reliably trigger the WindowServer's space switch (it reads the real
//  hardware modifier state). Private API — experimental and macOS-version dependent.
//

import Foundation
import CoreGraphics

enum Spaces {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias CopyFn     = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias SetSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)

    private static func fn<T>(_ name: String, _ type: T.Type) -> T? {
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private static func spaceID(_ dict: [String: Any]) -> UInt64? {
        (dict["ManagedSpaceID"] as? NSNumber)?.uint64Value
            ?? (dict["id64"] as? NSNumber)?.uint64Value
    }

    /// Switch one space left (-1) or right (+1) on the display that owns the active space.
    static func switchSpace(_ direction: Int) {
        guard let mainConn = fn("CGSMainConnectionID", MainConnFn.self),
              let copy      = fn("CGSCopyManagedDisplaySpaces", CopyFn.self),
              let setSpace  = fn("CGSManagedDisplaySetCurrentSpace", SetSpaceFn.self) else {
            rmDebug("🖥 space: SkyLight symbols unavailable"); return
        }
        let conn = mainConn()
        guard let displays = copy(conn)?.takeRetainedValue() as? [[String: Any]] else {
            rmDebug("🖥 space: CGSCopyManagedDisplaySpaces returned nil"); return
        }
        for display in displays {
            guard let displayID = display["Display Identifier"] as? String,
                  let spaces = display["Spaces"] as? [[String: Any]],
                  let current = display["Current Space"] as? [String: Any],
                  let curID = spaceID(current),
                  let idx = spaces.firstIndex(where: { spaceID($0) == curID }) else { continue }
            let target = idx + direction
            guard target >= 0, target < spaces.count, let targetID = spaceID(spaces[target]) else {
                rmDebug("🖥 space: at edge (idx \(idx) of \(spaces.count))"); return
            }
            rmDebug("🖥 space: \(curID)[\(idx)] → \(targetID)[\(target)] on \(displayID)")
            setSpace(conn, displayID as CFString, targetID)
            return
        }
        rmDebug("🖥 space: no matching current space in \(displays.count) display(s)")
    }
}
