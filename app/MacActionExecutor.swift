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
    static func run(_ source: String) {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err = err { NSLog("[siriRemote] applescript failed: \(err)") }
    }
}
