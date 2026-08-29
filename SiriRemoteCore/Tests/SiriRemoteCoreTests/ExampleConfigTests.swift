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

    private var authorURL: URL {
        exampleURL.deletingLastPathComponent().appendingPathComponent("config.author.jsonc")
    }

    func testExampleConfigParses() throws {
        let text = try String(contentsOf: exampleURL, encoding: .utf8)
        let config = try ConfigLoader.load(text)
        XCTAssertFalse(config.modes.isEmpty)
        // The default mode must exist, or every key is unbound the moment the app starts.
        XCTAssertNotNil(config.modes[config.settings.defaultMode])
    }

    func testAuthorConfigParses() throws {
        let text = try String(contentsOf: authorURL, encoding: .utf8)
        let config = try ConfigLoader.load(text)
        XCTAssertEqual(config.settings.layers.map(\.id), ["BASE", "L1", "L2"])
        XCTAssertEqual(config.modes["global"]?.bindings["button.tv"], .layerCycle)
        XCTAssertEqual(config.modes["L2"]?.bindings["button.volumeUp"],
                       .brightnessStep(direction: 1))
        XCTAssertEqual(config.modes["L2"]?.bindings["button.volumeDown"],
                       .brightnessStep(direction: -1))
    }

    func testMusicLaunchUsesItsOwnShortHoldDelay() throws {
        for url in [exampleURL, authorURL] {
            let config = try ConfigLoader.load(try String(contentsOf: url, encoding: .utf8))
            XCTAssertEqual(config.modes["global"]?.holdDelay["button.playPause.hold2"], 0.3)
            // This is deliberately binding-local: Select drag, Back and every other stage-one
            // action must keep the shared 0.5-second threshold.
            XCTAssertEqual(config.settings.holdThreshold, 0.5)
        }
    }

    func testAuthorBrowserBackMenuStartsWithDeleteThenBack() throws {
        let config = try ConfigLoader.load(try String(contentsOf: authorURL, encoding: .utf8))
        XCTAssertEqual(config.appProfiles["com.google.Chrome"], "browser")
        XCTAssertEqual(config.appProfiles["com.apple.Safari"], "browser")

        let engine = MappingEngine(config: config)
        for bundleID in ["com.google.Chrome", "com.apple.Safari"] {
            engine.applyApp(bundleID: bundleID)
            XCTAssertEqual(engine.activeMode, "browser")
            XCTAssertEqual(engine.resolve("button.menu"), .keystroke(keys: "delete"))
            XCTAssertEqual(engine.resolve("button.menu.taphold"), .keystroke(keys: "cmd+["))
            XCTAssertEqual(engine.resolveHoldDelay("button.menu.taphold"), 0.5)
            XCTAssertEqual(engine.resolve("button.menu.taphold2"), .closeWindow)
            XCTAssertEqual(engine.resolveHoldDelay("button.menu.taphold2"), 1.0)
            XCTAssertNotNil(engine.resolve("button.menu.taphold3"))
            XCTAssertEqual(engine.resolveHoldDelay("button.menu.taphold3"), 1.7)
        }
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
