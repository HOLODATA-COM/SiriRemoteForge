//
//  Spaces.swift
//  HyperVibe (config engine integration)
//
//  Switch macOS Spaces (desktops).
//
//  Three routes were measured, judged by PIXELS rather than by the space index — the index is not
//  evidence, see below:
//
//    CGEvent synthesis of Ctrl+Arrow    no-op. WindowServer reads the real hardware modifier
//                                       state, so a synthesized chord never reaches the handler.
//                                       (Physically pressing Ctrl+Arrow does work, which is how
//                                       we know the shortcut itself is enabled.)
//    Private CGS/SkyLight calls         MOVES THE BOOKKEEPING, NOT THE SCREEN. Calling
//                                       CGSManagedDisplaySetCurrentSpace changed the reported
//                                       space index while 568 of 20,358,144 pixels differed —
//                                       i.e. nothing happened. Worse, it leaves the record and the
//                                       display disagreeing, which corrupts anything read later.
//    System Events `key code` ✅        Works, with the native animation. AppleScript's
//                                       Accessibility injection path is not subject to the
//                                       hardware-modifier check.
//
//  So this goes through System Events. It needs Automation permission (macOS prompts once for
//  "HyperVibe wants to control System Events"); without it the call fails silently, hence the
//  error logging.
//
//  Historical note: this file previously used the CGS route and reported success, which is why
//  animated switching appeared to require BetterTouchTool. The CGS call never worked; it only
//  looked like it did because the index it moved was also what was being checked.
//

import Foundation

enum Spaces {
    /// Switch one space left (-1) or right (+1). Key codes 123/124 are the arrow keys.
    static func switchSpace(_ direction: Int) {
        let keyCode = direction < 0 ? 123 : 124
        let source = "tell application \"System Events\" to key code \(keyCode) using control down"
        let run = {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error = error {
                rmDebug("🖥 space: System Events refused — \(error). Grant Automation permission in "
                      + "System Settings > Privacy & Security > Automation.")
            }
        }
        // NSAppleScript is not thread-safe and expects a runloop; actions can arrive off-main.
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }
}
