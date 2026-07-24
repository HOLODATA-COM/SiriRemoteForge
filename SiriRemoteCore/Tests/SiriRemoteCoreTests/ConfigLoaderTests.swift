import XCTest
@testable import SiriRemoteCore

final class ConfigLoaderTests: XCTestCase {
    private func decodeAction(_ json: String) throws -> Action {
        try JSONDecoder().decode(Action.self, from: Data(json.utf8))
    }

    // MARK: - Action decoding (Task 3)

    func testDecodesKeystroke() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"keystroke\",\"keys\":\"cmd+up\"}"),
                       .keystroke(keys: "cmd+up"))
    }
    func testDecodesShell() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"shell\",\"command\":\"open -a Safari\"}"),
                       .shell(command: "open -a Safari"))
    }
    func testDecodesModeSwitch() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"mode\",\"to\":\"media\"}"),
                       .mode(to: "media"))
    }
    func testDecodesLayer() throws {
        // `layer` reuses the `to` key (same as `mode`) to name the momentary layer mode.
        XCTAssertEqual(try decodeAction("{\"action\":\"layer\",\"to\":\"tvLayer\"}"),
                       .layer("tvLayer"))
        XCTAssertEqual(Action.layer("tvLayer").displayLabel, "Layer: tvLayer")
    }
    func testUnknownActionThrows() {
        XCTAssertThrowsError(try decodeAction("{\"action\":\"nope\"}"))
    }
    func testDecodesRepeatKeyWithDefaults() throws {
        // delay/interval are optional and fall back to 0.3 / 0.045.
        XCTAssertEqual(try decodeAction("{\"action\":\"repeatKey\",\"keys\":\"delete\"}"),
                       .repeatKey(keys: "delete", delay: 0.3, interval: 0.045))
    }
    func testDecodesRepeatKeyWithExplicitTiming() throws {
        XCTAssertEqual(try decodeAction(
            "{\"action\":\"repeatKey\",\"keys\":\"delete\",\"delay\":0.5,\"interval\":0.02}"),
                       .repeatKey(keys: "delete", delay: 0.5, interval: 0.02))
    }
    func testDecodesBrightnessWithValue() throws {
        XCTAssertEqual(try decodeAction("{\"action\":\"brightness\",\"value\":0.5}"),
                       .brightness(0.5))
    }
    func testDecodesBrightnessDefaultsToZero() throws {
        // value is optional and falls back to 0 (minimum) — used by button.power to dim.
        XCTAssertEqual(try decodeAction("{\"action\":\"brightness\"}"),
                       .brightness(0))
    }

    // MARK: - Config decoding (Task 4)

    func testDecodesConfigWithModeAndInherits() throws {
        let json = """
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "com.apple.Safari": "web", "default": "global" },
          "modes": {
            "global": { "button.menu": { "action": "mode", "to": "web" } },
            "web":    { "inherits": "global",
                        "ring.up": { "action": "keystroke", "keys": "cmd+up" } }
          } }
        """
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.settings.defaultMode, "global")
        XCTAssertEqual(cfg.settings.swipeVelocity, 0.5)          // default applied
        XCTAssertEqual(cfg.appProfiles["com.apple.Safari"], "web")
        XCTAssertEqual(cfg.modes["web"]?.inherits, "global")
        XCTAssertEqual(cfg.modes["web"]?.bindings["ring.up"], .keystroke(keys: "cmd+up"))
        XCTAssertNil(cfg.modes["web"]?.bindings["inherits"])     // inherits is not a binding
    }

    // MARK: - ConfigLoader load + validation (Task 5)

    func testLoadStripsCommentsAndValidates() throws {
        let text = """
        { // my config
          "settings": { "defaultMode": "global" },
          "modes": { "global": {} } }
        """
        let cfg = try ConfigLoader.load(text)
        XCTAssertEqual(cfg.settings.defaultMode, "global")
    }
    func testDefaultModeMustExist() {
        let text = "{ \"settings\": { \"defaultMode\": \"nope\" }, \"modes\": { \"global\": {} } }"
        XCTAssertThrowsError(try ConfigLoader.load(text)) { error in
            XCTAssertEqual(error as? ConfigError, .validation("defaultMode 'nope' not in modes"))
        }
    }
    func testAppProfileMustPointToExistingMode() {
        let text = """
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "com.apple.Safari": "ghost" },
          "modes": { "global": {} } }
        """
        XCTAssertThrowsError(try ConfigLoader.load(text)) { error in
            XCTAssertEqual(error as? ConfigError,
                           .validation("appProfiles['com.apple.Safari'] -> unknown mode 'ghost'"))
        }
    }
    func testCursorSettingsDefaultsAndOverrides() throws {
        let defaults = try ConfigLoader.load(
            "{ \"settings\": { \"defaultMode\": \"g\" }, \"modes\": { \"g\": {} } }")
        XCTAssertEqual(defaults.settings.cursorSpeed, 0.6)
        XCTAssertEqual(defaults.settings.cursorDeadzone, 0.006)

        let overridden = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "cursorSpeed": 0.35, "cursorDeadzone": 0.01 },
          "modes": { "g": {} } }
        """)
        XCTAssertEqual(overridden.settings.cursorSpeed, 0.35)
        XCTAssertEqual(overridden.settings.cursorDeadzone, 0.01)
    }

    func testHoldStageThresholdsDefaultsAndOverrides() throws {
        // Multi-stage long-press thresholds: stage 1 = holdThreshold (0.5), stage 2 = holdThreshold2
        // (1.0), stage 3 = holdThreshold3 (1.6). All optional, decodeIfPresent with those defaults.
        let defaults = try ConfigLoader.load(
            "{ \"settings\": { \"defaultMode\": \"g\" }, \"modes\": { \"g\": {} } }")
        XCTAssertEqual(defaults.settings.holdThreshold, 0.5)
        XCTAssertEqual(defaults.settings.holdThreshold2, 1.0)
        XCTAssertEqual(defaults.settings.holdThreshold3, 1.6)

        let overridden = try ConfigLoader.load("""
        { "settings": { "defaultMode": "g", "holdThreshold": 0.4, "holdThreshold2": 0.9, "holdThreshold3": 1.4 },
          "modes": { "g": {} } }
        """)
        XCTAssertEqual(overridden.settings.holdThreshold, 0.4)
        XCTAssertEqual(overridden.settings.holdThreshold2, 0.9)
        XCTAssertEqual(overridden.settings.holdThreshold3, 1.4)
    }

    func testInheritsCycleRejected() {
        let text = """
        { "settings": { "defaultMode": "a" },
          "modes": { "a": { "inherits": "b" }, "b": { "inherits": "a" } } }
        """
        XCTAssertThrowsError(try ConfigLoader.load(text))
    }
}
