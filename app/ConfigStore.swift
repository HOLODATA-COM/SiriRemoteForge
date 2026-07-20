//
//  ConfigStore.swift
//  HyperVibe (config engine integration)
//
//  Loads the user config from ~/.config/siriremote/config.jsonc, bootstrapping a
//  commented default on first run. Uses an embedded default string (not a bundled
//  resource) so it works whether launched as a bare binary or an .app.
//

import Foundation

enum ConfigStore {
    static var path: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/siriremote", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.jsonc")
    }

    /// Read the config file, writing the default template on first run.
    static func loadOrBootstrapText() -> String {
        if let text = try? String(contentsOf: path, encoding: .utf8) { return text }
        try? defaultTemplate.write(to: path, atomically: true, encoding: .utf8)
        return defaultTemplate
    }

    /// Parse the on-disk config; falls back to a minimal valid config if it is broken,
    /// so the app never ends up with no engine at all.
    static func loadConfig() -> Config {
        if let cfg = try? ConfigLoader.load(loadOrBootstrapText()) { return cfg }
        NSLog("[siriRemote] config invalid — using empty fallback")
        return (try? ConfigLoader.load(minimalFallback))!
    }

    /// Serialize `config` back to `config.jsonc` (pretty-printed JSON via `ConfigWriter`; comments
    /// are NOT preserved — once edited via the UI the file is machine-managed). Writes atomically
    /// (temp file + rename), so a reader never sees a half-written file.
    ///
    /// The ConfigFileWatcher WILL fire after this write and hot-reload — but it reloads the exact
    /// same values, and nothing in the reload path (`SiriRemoteApp`'s watcher closure) writes the
    /// file, so there is no save→reload→save loop.
    enum SaveError: Error { case existingFileUnparseable }

    static func save(_ config: Config) throws {
        let text = try ConfigWriter.serialize(config)
        // Guard 1: never write a config the loader would reject (would drop the app to the empty
        // fallback while a broken file sits on disk).
        _ = try ConfigLoader.load(text)
        // Guard 2 (data-loss): if the file on disk currently exists but does NOT parse — e.g. a
        // hand-edit typo the app is temporarily running the empty fallback for — REFUSE to overwrite
        // it. The user's real modes/bindings are still in that file; a UI write (built from the
        // fallback) would erase them. The edit is rejected until the user fixes the file.
        if let existing = try? String(contentsOf: path, encoding: .utf8),
           (try? ConfigLoader.load(existing)) == nil {
            throw SaveError.existingFileUnparseable
        }
        // Back up the current good file before overwriting — a one-level safety net.
        if let existing = try? Data(contentsOf: path) {
            try? existing.write(to: path.appendingPathExtension("bak"))
        }
        try text.write(to: path, atomically: true, encoding: .utf8)
    }

    static let minimalFallback =
        "{ \"settings\": { \"defaultMode\": \"global\" }, \"modes\": { \"global\": {} } }"

    /// Shipped default. Bindings here OVERRIDE HyperVibe's native button behavior;
    /// anything left unbound falls through to native (push-to-talk, click/drag, etc.).
    /// Empty by default so nothing native is clobbered until you opt in.
    static let defaultTemplate = """
    {
      // siriRemote config — edit and save; changes hot-reload live.
      // Event keys: ring.up ring.down ring.left ring.right
      //             swipe.up swipe.down swipe.left swipe.right tap.two
      //             button.menu button.tv button.siri button.playPause
      //             button.volumeUp button.volumeDown button.back
      //             button.nextTrack button.prevTrack button.mute button.power
      //   Long-press: add ".hold" to any button/ring key — e.g. button.menu.hold, ring.up.hold.
      //     Multi-stage: also ".hold2" / ".hold3" for deeper holds. Release-to-select — keep
      //     holding to reach a deeper stage; the deepest stage reached fires when you let go.
      // Actions: keystroke(keys) media(key) mouse(op) launch(app|url)
      //          shell(command) applescript(script) mode(to) layer(to)
      //   layer(to): the bound key becomes a layer key — TAP it to toggle that mode sticky
      //     (persists until tapped again), or HOLD it and press other keys for momentary use.
      // A binding OVERRIDES native behavior; unbound buttons stay native.
      "settings": {
        "defaultMode": "global",
        "cursorSpeed": 0.6,          // lower = slower / less sensitive
        "cursorDeadzone": 0.006,     // higher = more jitter ignored, easier to hold & click
        "clickRiseThreshold": 0.1,   // contact rise counted as a press (lower = freezes more readily)
        "pressMoveMax": 0.025,       // finger move above this cancels a stray press-freeze
        "holdThreshold": 0.5,        // seconds held → stage 1 (".hold"). Fires on RELEASE (release-to-select).
        "holdThreshold2": 1.0,       // seconds held → stage 2 (".hold2"), a deeper hold
        "holdThreshold3": 1.6,       // seconds held → stage 3 (".hold3"), the deepest hold
        // Circular scroll (iPod wheel): circle a finger on the OUTER ring to scroll.
        "circularScroll": {
          "enabled": true,
          "minRadius": 0.35,         // only touches this far from center count (outer ring)
          "startThreshold": 0.35,    // radians to rotate before scrolling starts
          "pixelsPerRadian": 107,    // scroll pixels per radian of rotation (speed)
          "scrollEase": 0.3,         // scroll smoothing (smaller = smoother / laggier)
          "invert": false            // flip if it scrolls the wrong way
        }
      },

      // Per-app auto-switch: frontmost app's bundle id -> mode name.
      "appProfiles": {
        // "com.microsoft.VSCode": "vscode",
        // "com.apple.iWork.Keynote": "keynote",
        "default": "global"
      },

      "modes": {
        // Empty by default — nothing is mapped. Add your own bindings, e.g. (uncomment):
        "global": {
          // "ring.up":     { "action": "keystroke", "keys": "up" },
          // "ring.down":   { "action": "keystroke", "keys": "down" },
          // "button.tv":   { "action": "shell", "command": "open -a Safari" },
          // "swipe.left":  { "action": "keystroke", "keys": "cmd+[" },
          // "swipe.right": { "action": "keystroke", "keys": "cmd+]" }
        }
        // Per-app example (uncomment, and add the bundle id to appProfiles above):
        // ,"vscode": { "inherits": "global",
        //   "ring.up": { "action": "keystroke", "keys": "cmd+p" } }
      }
    }
    """
}
