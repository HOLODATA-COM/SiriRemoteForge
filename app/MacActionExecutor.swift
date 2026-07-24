//
//  MacActionExecutor.swift
//  HyperVibe (config engine integration)
//
//  Bridges SiriRemoteCore `Action`s to real macOS effects (CGEvent, media keys,
//  app launch, shell, AppleScript). `Action`, `EventPayload`, `ActionExecutor`
//  come from SiriRemoteCore, compiled into this target by build.sh.
//

import Foundation
import AppKit
import CoreGraphics

final class MacActionExecutor: ActionExecutor {
    /// Summon the radial launcher. A closure rather than a reference, so the executor stays free of
    /// anything that owns a window.
    var onAppWheel: (() -> Void)?

    private let media = MediaController()

    func execute(_ action: Action, payload: EventPayload?) {
        rmDebug("⚙️ action: \(action)")
        switch action {
        case .keystroke(let keys):
            Keys.synthesize(keys)
        case .media(let key):
            postMedia(key)
        case .mouse(let op):
            Mouse.perform(op, payload: payload)
        case .launch(let app, let url):
            if let app = app { Shell.run("open -a \(shellQuote(app))") }
            if let url = url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
        case .shell(let command):
            Shell.run(command)
        case .applescript(let script):
            AppleScriptRunner.run(script)
        case .space(let direction):
            Spaces.switchSpace(direction)
        case .fullscreen:
            WindowControl.toggle()
        case .minimize:
            WindowControl.minimize()
        case .closeWindow:
            WindowControl.close()
        case .appWheel:
            onAppWheel?()
        case .pushToTalk(let keys):
            // The press/release edge dispatch lives in RemoteInputHandler (both edges fire the
            // combo there and never reach the executor). This handles a stray dispatch — e.g. the
            // action bound to a swipe/tap, which has no release edge — as a single keystroke.
            Keys.synthesize(keys)
        case .repeatKey(let keys, _, _):
            // The auto-repeat cadence is driven by RemoteInputHandler (press starts the repeat,
            // release stops it). Here we just synthesize a single keystroke — this handles the
            // first fire and any stray dispatch (e.g. bound to a swipe/tap that has no hold state).
            Keys.synthesize(keys)
        case .brightness(let value):
            // Synthesize the hardware brightness keys so ALL displays move (DisplayServices misses
            // some externals). Low value → dim to minimum, high → restore to maximum.
            if value < 0.5 { Brightness.dimToMin() } else { Brightness.restoreToMax() }
        case .mode, .layer:
            break // handled inside Controller / RemoteInputHandler; never reaches the executor
        }
    }

    private func postMedia(_ key: String) {
        let type: MediaKeyInterceptor.MediaKeyType
        switch key {
        case "playpause":            type = .playPause
        case "next":                 type = .next
        case "previous":             type = .previous
        case "volup", "volumeup":    type = .volumeUp
        case "voldown", "volumedown":type = .volumeDown
        case "mute":                 type = .mute
        default:
            NSLog("[siriRemote] unknown media key '\(key)'"); return
        }
        media.sendMediaKey(type)
    }
}

// MARK: - Effect helpers (self-contained CGEvent / Process wrappers)

enum Keys {
    /// One reused event source for the ~66/s hold-repeat ticks — allocating a fresh `CGEventSource`
    /// every tick is avoidable churn on a cadence meant to match the keyboard. Used by `holdRepeat`.
    private static let sharedSource = CGEventSource(stateID: .combinedSessionState)

    static func synthesize(_ combo: String) {
        guard let parsed = KeyMap.parse(combo) else {
            NSLog("[siriRemote] unknown keystroke '\(combo)'"); return
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        var f: CGEventFlags = []

        // Press modifiers as REAL key events (not just flags) so system-level shortcuts like
        // Spaces / Mission Control — which read whether the modifier is actually held — respond.
        for m in parsed.mods {
            f.insert(m.flag)
            let e = CGEvent(keyboardEventSource: src, virtualKey: m.keyCode, keyDown: true)
            e?.flags = f
            e?.post(tap: .cghidEventTap)
        }

        if let mainKey = parsed.mainKey {
            let down = CGEvent(keyboardEventSource: src, virtualKey: mainKey, keyDown: true)
            down?.flags = f
            let up = CGEvent(keyboardEventSource: src, virtualKey: mainKey, keyDown: false)
            up?.flags = f
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        } else {
            // Modifier-only chord (e.g. "rctrl+rcmd+ropt"): hold briefly so a hyperkey tool sees it.
            usleep(30000)
        }

        // Release modifiers in reverse order.
        for m in parsed.mods.reversed() {
            f.remove(m.flag)
            let e = CGEvent(keyboardEventSource: src, virtualKey: m.keyCode, keyDown: false)
            e?.flags = f
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Held keys (true auto-repeat, not rapid re-tapping)
    //
    // `synthesize` above posts a full down+up per call, so repeating it flaps the key up and down —
    // rapid re-tapping, not a held key. These three drive a GENUINELY held key instead: press it
    // down and leave it down (`holdBegin`), re-fire it with the OS auto-repeat flag while it stays
    // down (`holdRepeat`), then lift it (`holdEnd`). This is what a real keyboard does, so held-key
    // semantics (selection extension, games, apps that inspect the autorepeat flag) behave right.

    /// Press a combo DOWN and leave it held — modifiers and the main key stay down. Returns the
    /// parsed combo so the caller drives `holdRepeat`/`holdEnd` without re-parsing. Pair EVERY
    /// `holdBegin` with exactly one `holdEnd`, or the key sticks down.
    static func holdBegin(_ combo: String) -> KeyMap.Combo? {
        guard let parsed = KeyMap.parse(combo) else {
            NSLog("[siriRemote] unknown keystroke '\(combo)'"); return nil
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        var f: CGEventFlags = []
        for m in parsed.mods {
            f.insert(m.flag)
            let e = CGEvent(keyboardEventSource: src, virtualKey: m.keyCode, keyDown: true)
            e?.flags = f
            e?.post(tap: .cghidEventTap)
        }
        if let mainKey = parsed.mainKey {
            let down = CGEvent(keyboardEventSource: src, virtualKey: mainKey, keyDown: true)
            down?.flags = f
            down?.post(tap: .cghidEventTap)
        }
        return parsed
    }

    /// Re-fire the held main key as a genuine OS-style auto-repeat: the key stays DOWN and the event
    /// carries `kCGKeyboardEventAutorepeat = 1`, exactly like a real keyboard holding a key. The
    /// modifiers are NOT re-pressed — they are already held from `holdBegin`.
    static func holdRepeat(_ parsed: KeyMap.Combo) {
        guard let mainKey = parsed.mainKey else { return }  // modifier-only chord: nothing to repeat
        let e = CGEvent(keyboardEventSource: sharedSource, virtualKey: mainKey, keyDown: true)
        e?.flags = parsed.flags
        e?.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        e?.post(tap: .cghidEventTap)
    }

    /// Release a held combo: main key up, then modifiers up in reverse order. This is the ONLY thing
    /// that lifts a held key, so it must run on every teardown path.
    static func holdEnd(_ parsed: KeyMap.Combo) {
        let src = CGEventSource(stateID: .combinedSessionState)
        var f = parsed.flags
        if let mainKey = parsed.mainKey {
            let up = CGEvent(keyboardEventSource: src, virtualKey: mainKey, keyDown: false)
            up?.flags = f
            up?.post(tap: .cghidEventTap)
        }
        for m in parsed.mods.reversed() {
            f.remove(m.flag)
            let e = CGEvent(keyboardEventSource: src, virtualKey: m.keyCode, keyDown: false)
            e?.flags = f
            e?.post(tap: .cghidEventTap)
        }
    }
}

enum Mouse {
    static func perform(_ op: String, payload: EventPayload?) {
        switch op {
        case "click":      click(.left)
        case "rightclick": click(.right)
        case "move":
            guard case let .delta(dx, dy)? = payload else { return }
            let cur = NSEvent.mouseLocation
            let to = CGPoint(x: cur.x + dx, y: cur.y - dy) // AppKit y-up → CG y-down
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: to, mouseButton: .left)?.post(tap: .cghidEventTap)
        case "scroll":
            guard case let .delta(dx, dy)? = payload else { return }
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?.post(tap: .cghidEventTap)
        default:
            NSLog("[siriRemote] unknown mouse op '\(op)'")
        }
    }

    private static func click(_ button: CGMouseButton) {
        let pos = CGEvent(source: nil)?.location ?? .zero
        let down: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType   = button == .left ? .leftMouseUp   : .rightMouseUp
        CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: pos, mouseButton: button)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: pos, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }
}

/// Single-quote a string for safe interpolation into a /bin/zsh -c command.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

enum Shell {
    static func run(_ command: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        do { try p.run() } catch { NSLog("[siriRemote] shell failed: \(error)") }
    }
}

enum AppleScriptRunner {
    /// Spawns `osascript` instead of running `NSAppleScript` in-process, and does not wait for it.
    ///
    /// Actions execute on the main thread, which is also where the CGEventTap's run-loop source and
    /// every HID callback are serviced. `NSAppleScript.executeAndReturnError` is synchronous, and an
    /// Apple event to a busy or slow app can block for seconds — long enough for macOS to disable
    /// the tap with `tapDisabledByTimeout`. While it is disabled the remote's Power button reaches
    /// loginwindow and sleeps the Mac, which is the exact failure this app suppresses. Spawning is
    /// a little slower per call but never blocks the thread that must stay responsive.
    /// (`NSAppleScript` is not thread-safe, so moving it to a background queue is not the fix.)
    static func run(_ source: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let errPipe = Pipe()
        p.standardError = errPipe
        p.terminationHandler = { proc in
            guard proc.terminationStatus != 0 else { return }
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            NSLog("[siriRemote] applescript failed (exit \(proc.terminationStatus)): \(msg)")
        }
        do { try p.run() } catch { NSLog("[siriRemote] applescript spawn failed: \(error)") }
    }
}
