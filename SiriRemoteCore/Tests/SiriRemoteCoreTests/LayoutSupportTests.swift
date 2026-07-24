import XCTest
@testable import SiriRemoteCore

/// Covers the read-only helpers the Settings "Layout" tab relies on:
/// `Action.displayLabel`, `Config.resolveBinding(_:in:)`, `defaultModeName`, `appsByMode`.
final class LayoutSupportTests: XCTestCase {

    // MARK: - Action.displayLabel

    func testKeystrokeLabels() {
        XCTAssertEqual(Action.keystroke(keys: "up").displayLabel, "↑")
        XCTAssertEqual(Action.keystroke(keys: "cmd+shift+[").displayLabel, "⌘⇧[")
        XCTAssertEqual(Action.keystroke(keys: "enter").displayLabel, "⏎")
        // Modifier-only chord (hyperkey) → just the modifier symbols, no key.
        XCTAssertEqual(Action.keystroke(keys: "rctrl+rcmd+ropt").displayLabel, "⌃⌘⌥")
    }

    func testRepeatKeyLabel() {
        // Reuses the keystroke symbol formatting for the keys, with a repeat glyph appended.
        XCTAssertEqual(Action.repeatKey(keys: "delete", delay: 0.3, interval: 0.045).displayLabel, "⌫ ⟳")
    }

    func testMediaMouseSpaceModeLabels() {
        XCTAssertEqual(Action.media(key: "playpause").displayLabel, "Play / Pause")
        XCTAssertEqual(Action.media(key: "volup").displayLabel, "Volume +")
        XCTAssertEqual(Action.mouse(op: "click").displayLabel, "Click")
        XCTAssertEqual(Action.space(direction: -1).displayLabel, "Space ←")
        XCTAssertEqual(Action.space(direction: 1).displayLabel, "Space →")
        XCTAssertEqual(Action.mode(to: "music").displayLabel, "Mode: music")
    }

    func testShellAndAppleScriptLabels() {
        XCTAssertEqual(Action.shell(command: "open -a 'Mission Control'").displayLabel, "Mission Control")
        XCTAssertEqual(Action.shell(command: "open -a \"Mission Control\"").displayLabel, "Mission Control")
        XCTAssertEqual(Action.applescript(script: "tell application \"Music\" to next track").displayLabel, "Next track")
        XCTAssertEqual(Action.applescript(script: "tell application \"Music\" to previous track").displayLabel, "Previous track")
        XCTAssertEqual(Action.applescript(script: "tell application \"Music\" to playpause").displayLabel, "Play / Pause")
        XCTAssertEqual(Action.applescript(script: "tell application \"Music\" to set mute to not mute").displayLabel, "Mute")
    }

    // MARK: - Config resolution

    private let cfg = """
    { "settings": { "defaultMode": "global" },
      "appProfiles": { "com.apple.Music": "music", "default": "global" },
      "modes": {
        "global": { "button.siri": { "action": "keystroke", "keys": "rctrl+rcmd+ropt" },
                    "ring.left":   { "action": "keystroke", "keys": "left" } },
        "music":  { "inherits": "global",
                    "ring.left": { "action": "applescript", "script": "tell application \\"Music\\" to previous track" } }
      } }
    """

    private func config() throws -> Config { try ConfigLoader.load(cfg) }

    func testResolveDirectVsInherited() throws {
        let c = try config()
        // Own binding in music → sourceMode is music (Custom).
        XCTAssertEqual(c.resolveBinding("ring.left", in: "music")?.sourceMode, "music")
        // button.siri not in music → inherited from global (Inherited).
        XCTAssertEqual(c.resolveBinding("button.siri", in: "music")?.sourceMode, "global")
        // Unbound anywhere → nil (System).
        XCTAssertNil(c.resolveBinding("button.power", in: "music"))
    }

    func testDefaultModeAndReverseMap() throws {
        let c = try config()
        XCTAssertEqual(c.defaultModeName, "global")
        XCTAssertEqual(c.appsByMode["music"], ["com.apple.Music"])
        XCTAssertNil(c.appsByMode["default"])
    }
}
