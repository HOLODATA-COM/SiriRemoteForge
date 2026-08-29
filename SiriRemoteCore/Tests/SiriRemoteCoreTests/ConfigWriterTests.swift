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
            .pushToTalk(keys: "f17"),
            .pushToTalk(keys: "cmd+shift+d"),
            .media(key: "playpause"),
            .mouse(op: "rightclick"),
            .launch(app: "Safari", url: nil),
            .launch(app: nil, url: "https://example.com/a/b"),
            .launch(app: "Notes", url: "x-notes://showNote"),
            .shell(command: "open -a \"Mission Control\""),
            .applescript(script: "tell application \"Music\" to playpause"),
            .mode(to: "music"),
            .layer("tvLayer"),
            .layerCycle,
            .space(direction: -1),
            .space(direction: 1),
            .repeatKey(keys: "delete", delay: 0.3, interval: 0.045),
            .repeatKey(keys: "down", delay: 0.5, interval: 0.02),
            .brightness(0),
            .brightness(0.5),
            .brightnessStep(direction: -1),
            .brightnessStep(direction: 1),
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

        // pushToTalk mirrors keystroke's shape exactly, under its own discriminator.
        o = try encodeToObject(.pushToTalk(keys: "f17"))
        XCTAssertEqual(o["action"] as? String, "pushToTalk")
        XCTAssertEqual(o["keys"] as? String, "f17")

        o = try encodeToObject(.space(direction: -1))
        XCTAssertEqual(o["action"] as? String, "space")
        XCTAssertEqual(o["to"] as? String, "left")
        XCTAssertEqual(try encodeToObject(.space(direction: 1))["to"] as? String, "right")

        o = try encodeToObject(.layer("tvLayer"))
        XCTAssertEqual(o["action"] as? String, "layer")
        XCTAssertEqual(o["to"] as? String, "tvLayer")     // layer reuses the `to` key

        o = try encodeToObject(.layerCycle)
        XCTAssertEqual(o["action"] as? String, "layerCycle")
        XCTAssertNil(o["to"])

        o = try encodeToObject(.brightnessStep(direction: -1))
        XCTAssertEqual(o["action"] as? String, "brightnessStep")
        XCTAssertEqual(o["to"] as? String, "down")
        XCTAssertEqual(try encodeToObject(.brightnessStep(direction: 1))["to"] as? String, "up")

        // launch omits an absent optional (encodeIfPresent).
        o = try encodeToObject(.launch(app: "Safari", url: nil))
        XCTAssertEqual(o["app"] as? String, "Safari")
        XCTAssertNil(o["url"])
    }

    /// The exact JSON a user writes for a push-to-talk binding must decode to `.pushToTalk` and
    /// encode back to the same shape — like keystroke, whose wire format it mirrors.
    func testPushToTalkJSONRoundTrips() throws {
        let json = Data(#"{"action":"pushToTalk","keys":"f17"}"#.utf8)
        let decoded = try JSONDecoder().decode(Action.self, from: json)
        XCTAssertEqual(decoded, .pushToTalk(keys: "f17"))

        let o = try encodeToObject(decoded)
        XCTAssertEqual(o["action"] as? String, "pushToTalk")
        XCTAssertEqual(o["keys"] as? String, "f17")
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
        "accelCurve": 1.75,
        "accelerationCurvesLinked": true,
        "doubleTapWindow": 0.2,
        "spacesModeWindow": 5.0,
        "findCursorEnabled": true,
        "interfaceLanguage": "zh",
        "launchAtLoginEnabled": true,
        "automaticUpdateChecksEnabled": false,
        "automaticallyDownloadUpdatesEnabled": false,
        "menuBarIconEnabled": false,
        "statusWidgetEnabled": true,
        "demoRemoteEnabled": true,
        "layerHUDEnabled": false,
        "holdHUDEnabled": true,
        "dragIndicatorEnabled": false,
        "showSetupWizardOnFirstLaunch": false,
        "dictation": {
          "enabled": true,
          "activeMode": "streaming",
          "outputMode": "streaming",
          "layerModes": { "BASE": "existing", "L1": "final" },
          "finalModel": "gpt-transcribe",
          "streamingModel": "gpt-live-transcribe",
          "languageHints": ["zh", "en"],
          "cleanupProvider": "deepseek",
          "openAICleanupModel": "gpt-5.6-luna",
          "deepSeekCleanupModel": "deepseek-v4-flash",
          "autoInsert": true,
          "copyOnFailure": true,
          "restoreClipboardAfterInsert": true,
          "copyLastOnSideButtonDouble": true,
          "feedbackSoundsEnabled": true,
          "feedbackSoundVolume": 0.55,
          "pipelineOverlayEnabled": true,
          "minimumRecordingSeconds": 2,
          "maxRecordingSeconds": 90,
          "dictionary": [{ "term": "HyperVibe", "aliases": ["hyper vibe"] }]
        },
        "layers": [
          { "id": "BASE", "name": "Layer 1", "color": "green", "icon": "house.fill" },
          { "id": "L1", "name": "Layer 2", "color": "#0A84FF", "icon": "hammer.fill" }
        ],
        "icons": {
          "remote.connected": "appletvremote.gen4.fill",
          "voice.copied": "doc.on.doc.fill"
        },
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
        },
        "L1": { "inherits": "global" }
      }
    }
    """

    func testConfigRoundTripsThroughWriter() throws {
        let original = try ConfigLoader.load(representativeConfig)
        XCTAssertEqual(original.settings.layers[1],
                       Config.LayerDefinition(id: "L1", name: "Layer 2", color: "#0A84FF",
                                              icon: "hammer.fill"))
        XCTAssertEqual(original.settings.icons["voice.copied"], "doc.on.doc.fill")
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

    // Window-control and launcher actions carry no parameters, which makes them the easiest kind to
    // get wrong: a missing encode branch loses the binding silently on the next config write-back,
    // and nothing in the app would report it.
    func testParameterlessActionsRoundTrip() throws {
        let source = """
        { "settings": { "defaultMode": "g", "appWheel": ["Music", "Warp"] },
          "appProfiles": { "default": "g" },
          "modes": { "g": {
            "button.a": { "action": "fullscreen" },
            "button.b": { "action": "minimize" },
            "button.c": { "action": "closeWindow" },
            "button.d": { "action": "appWheel" } } } }
        """
        let config = try ConfigLoader.load(source)
        XCTAssertEqual(config.modes["g"]?.bindings["button.a"], .fullscreen)
        XCTAssertEqual(config.modes["g"]?.bindings["button.b"], .minimize)
        XCTAssertEqual(config.modes["g"]?.bindings["button.c"], .closeWindow)
        XCTAssertEqual(config.modes["g"]?.bindings["button.d"], .appWheel)
        XCTAssertEqual(config.settings.appWheel, ["Music", "Warp"])

        let round = try ConfigLoader.load(ConfigWriter.serialize(config))
        XCTAssertEqual(round, config, "a parameterless action was lost on write-back")
    }

    func testAppWheelAndCancelGraceDefaults() throws {
        let config = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g" }, "appProfiles": { "default": "g" },
          "modes": { "g": {} } }
        """)
        XCTAssertEqual(config.settings.appWheel, [], "the launcher must be off until asked for")
        XCTAssertEqual(config.settings.holdCancelGrace, 1.0)
        XCTAssertEqual(config.settings.accelCurve, 1.0)
        XCTAssertFalse(config.settings.accelerationCurvesLinked)
        XCTAssertEqual(try ConfigLoader.load(ConfigWriter.serialize(config)), config)
    }
}
