import XCTest
@testable import SiriRemoteCore

/// The shipped example config must actually load. The loader tolerates comments and trailing
/// commas, and a malformed file falls back to defaults SILENTLY at runtime — this project has
/// already lost an afternoon to one missing comma — so it is parsed here rather than trusted.
final class ExampleConfigTests: XCTestCase {

    private var exampleURL: URL {
        // …/SiriRemoteCore/Tests/SiriRemoteCoreTests/ThisFile.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // SiriRemoteCoreTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // SiriRemoteCore
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("examples/config.jsonc")
    }

    func testExampleConfigParses() throws {
        let text = try String(contentsOf: exampleURL, encoding: .utf8)
        let config = try ConfigLoader.load(text)
        XCTAssertFalse(config.modes.isEmpty)
        // The default mode must exist, or every key is unbound the moment the app starts.
        XCTAssertNotNil(config.modes[config.settings.defaultMode])
    }

    func testEveryReferencedModeExists() throws {
        let config = try ConfigLoader.load(try String(contentsOf: exampleURL, encoding: .utf8))
        for (app, mode) in config.appProfiles {
            XCTAssertNotNil(config.modes[mode], "appProfiles[\(app)] points at missing mode '\(mode)'")
        }
        for (name, mode) in config.modes {
            if let parent = mode.inherits {
                XCTAssertNotNil(config.modes[parent], "mode '\(name)' inherits missing '\(parent)'")
            }
        }
    }

    func testEveryLayerActionHasItsMode() throws {
        let config = try ConfigLoader.load(try String(contentsOf: exampleURL, encoding: .utf8))
        for (name, mode) in config.modes {
            for (key, action) in mode.bindings {
                guard case .layer(let to) = action else { continue }
                // Without a marker mode the layer cannot hold app-agnostic bindings (step 2 of
                // layer resolution) — see README "Layers".
                XCTAssertNotNil(config.modes[to],
                                "\(name).\(key) toggles layer '\(to)', which has no mode")
            }
        }
    }
}
