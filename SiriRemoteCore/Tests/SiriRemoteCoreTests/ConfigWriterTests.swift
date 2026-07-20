import XCTest
@testable import SiriRemoteCore

/// Round-trip tests for config write-back: `Encodable` must be the exact inverse of `Decodable`,
/// so `ConfigLoader.load(ConfigWriter.serialize(c)) == c`.
final class ConfigWriterTests: XCTestCase {

    // MARK: - Action: encode + decode round-trips (every case)

    private func roundTrip(_ action: Action) throws -> Action {
        let data = try JSONEncoder().encode(action)
        return try JSONDecoder().decode(Action.self, from: data)
    }

    func testActionRoundTripsForEveryCase() throws {
        let cases: [Action] = [
            .keystroke(keys: "cmd+shift+["),
            .keystroke(keys: "rctrl+rcmd+ropt"),          // modifier-only hyperkey chord
            .media(key: "playpause"),
            .mouse(op: "rightclick"),
            .launch(app: "Safari", url: nil),
            .launch(app: nil, url: "https://example.com/a/b"),
            .launch(app: "Notes", url: "x-notes://showNote"),
            .shell(command: "open -a \"Mission Control\""),
            .applescript(script: "tell application \"Music\" to playpause"),
            .mode(to: "music"),
            .layer("tvLayer"),
            .space(direction: -1),
            .space(direction: 1),
            .repeatKey(keys: "delete", delay: 0.3, interval: 0.045),
            .repeatKey(keys: "down", delay: 0.5, interval: 0.02),
            .brightness(0),
            .brightness(0.5),
        ]
        for action in cases {
            XCTAssertEqual(try roundTrip(action), action, "round trip failed for \(action)")
        }
    }

    /// The serialized shape must use the same keys the decoder reads — notably `layer` and `space`
    /// reuse the `to` key, and the discriminator is always `action`.
    private func encodeToObject(_ action: Action) throws -> [String: Any] {
        let data = try JSONEncoder().encode(action)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testActionSerializedShapes() throws {
        var o = try encodeToObject(.keystroke(keys: "cmd+up"))
        XCTAssertEqual(o["action"] as? String, "keystroke")
        XCTAssertEqual(o["keys"] as? String, "cmd+up")

        o = try encodeToObject(.space(direction: -1))
        XCTAssertEqual(o["action"] as? String, "space")
        XCTAssertEqual(o["to"] as? String, "left")
        XCTAssertEqual(try encodeToObject(.space(direction: 1))["to"] as? String, "right")

        o = try encodeToObject(.layer("tvLayer"))
        XCTAssertEqual(o["action"] as? String, "layer")
        XCTAssertEqual(o["to"] as? String, "tvLayer")     // layer reuses the `to` key

        // launch omits an absent optional (encodeIfPresent).
        o = try encodeToObject(.launch(app: "Safari", url: nil))
        XCTAssertEqual(o["app"] as? String, "Safari")
        XCTAssertNil(o["url"])
    }

    // MARK: - Config: full round-trip through ConfigWriter + ConfigLoader

    /// A representative live-ish config exercising every action type, inheritance, holds/doubles,
    /// a momentary layer mode, appProfiles, and non-default settings (incl. circularScroll).
    private let representativeConfig = """
    {
      "settings": {
        "defaultMode": "global",
        "swipeVelocity": 0.6,
        "cursorSpeed": 1.8,
        "cursorDeadzone": 0.006,
        "clickRiseThreshold": 0.1,
        "pressMoveMax": 0.025,
        "holdThreshold": 0.5,
        "holdThreshold2": 1.0,
        "holdThreshold3": 1.6,
        "accelMin": 0.14,
        "accelMax": 6.0,
        "accelLowSpeed": 0.007,
        "accelHighSpeed": 0.06,
        "doubleTapWindow": 0.2,
        "spacesModeWindow": 5.0,
        "findCursorEnabled": true,
        "circularScroll": {
          "enabled": true, "minRadius": 0.35, "startThreshold": 0.35,
          "pixelsPerRadian": 160, "scrollEase": 0.3, "invert": false
        }
      },
      "appProfiles": {
        "com.apple.Music": "music",
        "com.google.Chrome": "browser",
        "dev.warp.Warp-Stable": "terminal",
        "default": "global"
      },
      "modes": {
        "global": {
          "ring.up":            { "action": "keystroke", "keys": "up" },
          "ring.down":          { "action": "keystroke", "keys": "down" },
          "ring.left":          { "action": "space", "to": "left" },
          "ring.right":         { "action": "space", "to": "right" },
          "ring.up.hold":       { "action": "shell", "command": "open -a \\"Mission Control\\"" },
          "button.siri":        { "action": "keystroke", "keys": "rctrl+rcmd+ropt" },
          "button.siri.double": { "action": "keystroke", "keys": "enter" },
          "button.tv.hold":     { "action": "layer", "to": "tvLayer" },
          "button.playPause":   { "action": "media", "key": "playpause" },
          "tap.two":            { "action": "mouse", "op": "rightclick" },
          "button.power":       { "action": "brightness", "value": 0 },
          "button.tv":          { "action": "launch", "app": "Safari" }
        },
        "music": {
          "inherits": "global",
          "ring.left":        { "action": "applescript", "script": "tell application \\"Music\\" to previous track" },
          "ring.right":       { "action": "applescript", "script": "tell application \\"Music\\" to next track" },
          "button.playPause": { "action": "applescript", "script": "tell application \\"Music\\" to playpause" }
        },
        "browser": {
          "inherits": "global",
          "button.menu": { "action": "keystroke", "keys": "cmd+shift+left" },
          "button.tv":   { "action": "launch", "url": "https://apple.com" }
        },
        "terminal": {
          "inherits": "global",
          "button.menu": { "action": "repeatKey", "keys": "delete", "delay": 0.3, "interval": 0.045 }
        },
        "tvLayer": {
          "ring.up":   { "action": "media", "key": "volup" },
          "ring.down": { "action": "media", "key": "voldown" }
        }
      }
    }
    """

    func testConfigRoundTripsThroughWriter() throws {
        let original = try ConfigLoader.load(representativeConfig)
        let written = try ConfigWriter.serialize(original)
        let reparsed = try ConfigLoader.load(written)
        XCTAssertEqual(reparsed, original)
    }

    /// The serialized text must be strict JSON that re-parses unchanged (no reliance on comment
    /// stripping) and must survive a second write→load cycle identically (stable output).
    func testWrittenConfigIsStableAndValid() throws {
        let original = try ConfigLoader.load(representativeConfig)
        let firstWrite = try ConfigWriter.serialize(original)
        let secondWrite = try ConfigWriter.serialize(try ConfigLoader.load(firstWrite))
        XCTAssertEqual(firstWrite, secondWrite, "writer output should be deterministic / stable")
        // Sanity: strict-JSON parseable directly (i.e. no comments emitted).
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(firstWrite.utf8)))
    }

    /// The shipped default template must also survive write-back (empty modes, appProfiles present).
    func testEmptyishConfigRoundTrips() throws {
        let original = try ConfigLoader.load("""
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "default": "global" },
          "modes": { "global": {} } }
        """)
        let reparsed = try ConfigLoader.load(try ConfigWriter.serialize(original))
        XCTAssertEqual(reparsed, original)
    }
}
