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
