import XCTest
@testable import SiriRemoteCore

final class MappingEngineTests: XCTestCase {
    private func engine(_ json: String) throws -> MappingEngine {
        MappingEngine(config: try ConfigLoader.load(json))
    }
    private let cfg = """
    { "settings": { "defaultMode": "global" },
      "appProfiles": { "com.apple.Safari": "web", "default": "global" },
      "modes": {
        "global": { "button.menu": { "action": "keystroke", "keys": "esc" } },
        "web":    { "inherits": "global",
                    "ring.up": { "action": "keystroke", "keys": "cmd+up" } }
      } }
    """

    // Presentation (`label`/`icon`) belongs to the KEY, not to each per-mode action override.
    // A mode that re-binds a key for its own reasons should not have to restate how that key looks.
    private let presentationCfg = """
    { "settings": { "defaultMode": "global" },
      "appProfiles": { "com.apple.Music": "music", "default": "global" },
      "modes": {
        "global": { "button.playPause": { "action": "media", "key": "playpause",
                                          "label": "Play / Pause", "icon": "playpause.fill" },
                    "button.mute":      { "action": "media", "key": "mute", "icon": "speaker.fill" } },
        "music":  { "inherits": "global",
                    "button.playPause": { "action": "applescript", "script": "tell app to playpause" },
                    "button.mute":      { "action": "applescript", "script": "mute", "label": "Silence" } }
      } }
    """

    func testPresentationInheritedThroughOverriddenBinding() throws {
        let e = try engine(presentationCfg)
        e.applyApp(bundleID: "com.apple.Music")
        XCTAssertEqual(e.activeMode, "music")
        // music re-binds the ACTION but says nothing about presentation → inherits global's.
        XCTAssertEqual(e.resolve("button.playPause"), .applescript(script: "tell app to playpause"))
        XCTAssertEqual(e.resolvePresentation("button.playPause")?.label, "Play / Pause")
        XCTAssertEqual(e.resolvePresentation("button.playPause")?.icon, "playpause.fill")
    }

    func testPresentationFieldsInheritIndependently() throws {
        let e = try engine(presentationCfg)
        e.applyApp(bundleID: "com.apple.Music")
        // music overrides only the label; the icon still comes from global.
        XCTAssertEqual(e.resolvePresentation("button.mute")?.label, "Silence")
        XCTAssertEqual(e.resolvePresentation("button.mute")?.icon, "speaker.fill")
    }

    func testPresentationNilWhenNothingInChainDeclaresIt() throws {
        XCTAssertNil(try engine(cfg).resolvePresentation("button.menu"))
    }

    func testStartsAtDefaultMode() throws {
        XCTAssertEqual(try engine(cfg).activeMode, "global")
    }
    func testResolvesDirectBinding() throws {
        XCTAssertEqual(try engine(cfg).resolve("button.menu"), .keystroke(keys: "esc"))
    }
    func testUnboundEventResolvesNil() throws {
        XCTAssertNil(try engine(cfg).resolve("ring.down"))
    }
    func testAppSwitchSetsAppMode() throws {
        let e = try engine(cfg)
        e.applyApp(bundleID: "com.apple.Safari")
        XCTAssertEqual(e.activeMode, "web")
    }
    func testResolvesThroughInheritsChain() throws {
        let e = try engine(cfg)
        e.applyApp(bundleID: "com.apple.Safari")            // active = web
        XCTAssertEqual(e.resolve("ring.up"), .keystroke(keys: "cmd+up"))  // own
        XCTAssertEqual(e.resolve("button.menu"), .keystroke(keys: "esc")) // inherited from global
    }
    func testUnknownAppFallsBackToDefault() throws {
        let e = try engine(cfg)
        e.applyApp(bundleID: "com.unknown.App")
        XCTAssertEqual(e.activeMode, "global")
    }
    func testManualSwitchModeOverrides() throws {
        let e = try engine(cfg)
        e.switchMode(to: "web")
        XCTAssertEqual(e.activeMode, "web")
    }
}
