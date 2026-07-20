import XCTest
@testable import SiriRemoteCore

final class ControllerTests: XCTestCase {

    // MARK: - Events (Task 6)

    func testInputEventCarriesKeyAndPayload() {
        let e = InputEvent(key: "scroll", payload: .delta(dx: 1, dy: -2))
        XCTAssertEqual(e.key, "scroll")
        XCTAssertEqual(e.payload, .delta(dx: 1, dy: -2))
    }

    // MARK: - Controller dispatch (Task 8)

    private final class SpyExecutor: ActionExecutor {
        var executed: [(Action, EventPayload?)] = []
        func execute(_ action: Action, payload: EventPayload?) {
            executed.append((action, payload))
        }
    }
    private func makeController(_ json: String, _ spy: SpyExecutor) throws -> Controller {
        let engine = MappingEngine(config: try ConfigLoader.load(json))
        return Controller(engine: engine, executor: spy)
    }
    private let cfg = """
    { "settings": { "defaultMode": "global" },
      "appProfiles": { "com.apple.Safari": "web", "default": "global" },
      "modes": {
        "global": { "button.menu": { "action": "mode", "to": "web" },
                    "button.tv":   { "action": "shell", "command": "say hi" } },
        "web":    { "ring.up": { "action": "keystroke", "keys": "cmd+up" } }
      } }
    """

    func testDispatchesResolvedAction() throws {
        let spy = SpyExecutor()
        let c = try makeController(cfg, spy)
        c.handle(InputEvent(key: "button.tv"))
        XCTAssertEqual(spy.executed.map(\.0), [.shell(command: "say hi")])
    }
    func testModeActionSwitchesWithoutExecuting() throws {
        let spy = SpyExecutor()
        let engine = MappingEngine(config: try ConfigLoader.load(cfg))
        let c = Controller(engine: engine, executor: spy)
        c.handle(InputEvent(key: "button.menu"))          // action: mode -> web
        XCTAssertTrue(spy.executed.isEmpty)               // not sent to executor
        XCTAssertEqual(engine.activeMode, "web")
        c.handle(InputEvent(key: "ring.up"))              // now resolvable in web
        XCTAssertEqual(spy.executed.map(\.0), [.keystroke(keys: "cmd+up")])
    }
    func testAppChangeReclassifiesMode() throws {
        let spy = SpyExecutor()
        let engine = MappingEngine(config: try ConfigLoader.load(cfg))
        let c = Controller(engine: engine, executor: spy)
        c.frontmostAppChanged(bundleID: "com.apple.Safari")
        XCTAssertEqual(engine.activeMode, "web")
    }
    func testPayloadForwardedToExecutor() throws {
        let spy = SpyExecutor()
        let json = """
        { "settings": { "defaultMode": "g" },
          "modes": { "g": { "scroll": { "action": "mouse", "op": "scroll" } } } }
        """
        let c = try makeController(json, spy)
        c.handle(InputEvent(key: "scroll", payload: .delta(dx: 3, dy: -1)))
        XCTAssertEqual(spy.executed.first?.1, .delta(dx: 3, dy: -1))
    }

    // MARK: - handle() match reporting + reload (Task 12 Step 2b)

    func testHandleReturnsFalseWhenUnbound() throws {
        let c = try makeController(cfg, SpyExecutor())
        XCTAssertFalse(c.handle(InputEvent(key: "button.nope")))
    }
    func testHandleReturnsTrueWhenBound() throws {
        let c = try makeController(cfg, SpyExecutor())
        XCTAssertTrue(c.handle(InputEvent(key: "button.tv")))
    }
    func testHasBinding() throws {
        let c = try makeController(cfg, SpyExecutor())
        XCTAssertTrue(c.hasBinding(for: "button.tv"))
        XCTAssertFalse(c.hasBinding(for: "button.tv.hold"))
    }

    // MARK: - Momentary layer (Feature: LAYER)

    private let layerCfg = """
    { "settings": { "defaultMode": "global" },
      "modes": {
        "global": { "button.tv": { "action": "layer", "to": "tvLayer" },
                    "ring.up":   { "action": "keystroke", "keys": "up" } },
        "tvLayer": { "inherits": "global",
                     "ring.up": { "action": "keystroke", "keys": "cmd+up" },
                     "ring.down": { "action": "keystroke", "keys": "cmd+down" } }
      } }
    """

    func testLayerOverridesResolutionWhileActive() throws {
        let spy = SpyExecutor()
        let c = try makeController(layerCfg, spy)

        // Before pushing: resolve against the app mode (global).
        XCTAssertEqual(c.resolvedAction(for: "ring.up"), .keystroke(keys: "up"))
        // ring.down is only defined in tvLayer, unbound in global.
        XCTAssertFalse(c.hasBinding(for: "ring.down"))

        c.pushLayer("tvLayer")
        // Now resolution runs against the layer (and its inherits chain).
        XCTAssertEqual(c.resolvedAction(for: "ring.up"), .keystroke(keys: "cmd+up"))   // overridden
        XCTAssertTrue(c.hasBinding(for: "ring.down"))                                   // layer-only
        XCTAssertTrue(c.hasBinding(for: "button.tv"))                                   // inherited from global
        c.handle(InputEvent(key: "ring.up"))
        XCTAssertEqual(spy.executed.map(\.0), [.keystroke(keys: "cmd+up")])

        c.popLayer()
        // Reverts to the app mode.
        XCTAssertEqual(c.resolvedAction(for: "ring.up"), .keystroke(keys: "up"))
        XCTAssertFalse(c.hasBinding(for: "ring.down"))
    }

    func testSecondLayerPushReplacesActive() throws {
        let json = """
        { "settings": { "defaultMode": "a" },
          "modes": {
            "a": { "x": { "action": "keystroke", "keys": "a" } },
            "b": { "x": { "action": "keystroke", "keys": "b" } },
            "c": { "x": { "action": "keystroke", "keys": "c" } }
          } }
        """
        let c = try makeController(json, SpyExecutor())
        c.pushLayer("b")
        XCTAssertEqual(c.resolvedAction(for: "x"), .keystroke(keys: "b"))
        c.pushLayer("c")                                                // replaces, not stacks
        XCTAssertEqual(c.resolvedAction(for: "x"), .keystroke(keys: "c"))
        c.popLayer()
        XCTAssertEqual(c.resolvedAction(for: "x"), .keystroke(keys: "a"))   // back to app mode
    }

    /// Per-app layers: while a layer is active, a key resolves to the app-mode's `"<layer>.<key>"`
    /// FIRST (so the same layer differs per app), then falls back to the standalone layer mode.
    func testLayerComposesPerApp() throws {
        let json = """
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "com.apple.Terminal": "term", "com.google.Chrome": "web", "default": "global" },
          "modes": {
            "global": { "button.tv": { "action": "layer", "to": "L1" } },
            "term":   { "inherits": "global", "L1.ring.left": { "action": "keystroke", "keys": "cmd+shift+left" } },
            "web":    { "inherits": "global", "L1.ring.left": { "action": "keystroke", "keys": "cmd+1" } },
            "L1":     { "inherits": "global", "ring.left": { "action": "keystroke", "keys": "default" } }
          } }
        """
        let spy = SpyExecutor()
        let c = try makeController(json, spy)
        c.pushLayer("L1")

        // In the Terminal app, L1's ring.left is the terminal-specific binding.
        c.frontmostAppChanged(bundleID: "com.apple.Terminal")
        XCTAssertEqual(c.resolvedAction(for: "ring.left"), .keystroke(keys: "cmd+shift+left"))

        // In Chrome, the SAME layer key does something different.
        c.frontmostAppChanged(bundleID: "com.google.Chrome")
        XCTAssertEqual(c.resolvedAction(for: "ring.left"), .keystroke(keys: "cmd+1"))

        // In an app with no per-app override, falls back to the standalone L1 mode's binding.
        c.frontmostAppChanged(bundleID: "com.unknown.app")
        XCTAssertEqual(c.resolvedAction(for: "ring.left"), .keystroke(keys: "default"))
    }

    func testReloadSwapsConfig() throws {
        let engine = MappingEngine(config: try ConfigLoader.load(cfg))
        let c = Controller(engine: engine, executor: SpyExecutor())
        XCTAssertTrue(c.handle(InputEvent(key: "button.tv")))    // bound in cfg
        let cfg2 = "{ \"settings\": { \"defaultMode\": \"g\" }, \"modes\": { \"g\": {} } }"
        c.reload(config: try ConfigLoader.load(cfg2))
        XCTAssertFalse(c.handle(InputEvent(key: "button.tv")))   // no longer bound
    }
}
