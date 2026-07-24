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

    // MARK: - A layer is a modifier, not a separate keyboard

    // A key the layer says nothing about must keep doing what it does UNLAYERED, in the CURRENT
    // app. Holding a layer must never turn a bound key into a dead one.
    private let layerFallbackCfg = """
    { "settings": { "defaultMode": "global" },
      "appProfiles": { "dev.warp.Warp-Stable": "terminal", "default": "global" },
      "modes": {
        "global":   { "ring.up":    { "action": "keystroke", "keys": "up" },
                      "L1.ring.up": { "action": "keystroke", "keys": "cmd+up" },
                      "ring.left":  { "action": "keystroke", "keys": "left",
                                      "label": "Left" } },
        "terminal": { "inherits": "global",
                      "button.menu": { "action": "repeatKey", "keys": "delete",
                                       "delay": 0.3, "interval": 0.045 },
                      "ring.left":   { "action": "keystroke", "keys": "cmd+shift+left",
                                       "label": "Prev Tab" } },
        "L1":       { "inherits": "global",
                      "button.siri": { "action": "keystroke", "keys": "f1" } }
      } }
    """

    private func layerFallbackController() throws -> Controller {
        try makeController(layerFallbackCfg, SpyExecutor())
    }

    func testLayerFallsBackToCurrentAppsBaseBinding() throws {
        let c = try layerFallbackController()
        c.frontmostAppChanged(bundleID: "dev.warp.Warp-Stable")
        let repeatDelete = Action.repeatKey(keys: "delete", delay: 0.3, interval: 0.045)
        XCTAssertEqual(c.resolvedAction(for: "button.menu"), repeatDelete)
        // L1 says nothing about this key. "global" binds nothing there either, so before the
        // fallback existed the Back button went DEAD while the layer was held.
        c.pushLayer("L1")
        XCTAssertEqual(c.resolvedAction(for: "button.menu"), repeatDelete)
        XCTAssertTrue(c.hasBinding(for: "button.menu"))
    }

    func testLayerModeInheritsDoesNotShadowTheAppsBaseBinding() throws {
        let c = try layerFallbackController()
        c.frontmostAppChanged(bundleID: "dev.warp.Warp-Stable")
        c.pushLayer("L1")
        // "L1" declares `"inherits": "global"`. Walking that chain would answer with GLOBAL's
        // plain "left" and shadow the terminal's own tab switch. It must not.
        XCTAssertEqual(c.resolvedAction(for: "ring.left"), .keystroke(keys: "cmd+shift+left"))
    }

    func testNamespacedLayerBindingStillWinsOverTheFallback() throws {
        let c = try layerFallbackController()
        c.pushLayer("L1")
        XCTAssertEqual(c.resolvedAction(for: "ring.up"), .keystroke(keys: "cmd+up"))
        c.popLayer()
        XCTAssertEqual(c.resolvedAction(for: "ring.up"), .keystroke(keys: "up"))
    }

    func testLayerModesOwnBindingBeatsTheFallback() throws {
        let c = try layerFallbackController()
        c.frontmostAppChanged(bundleID: "dev.warp.Warp-Stable")
        c.pushLayer("L1")
        // Bound only inside the "L1" mode itself → an app-agnostic layer binding.
        XCTAssertEqual(c.resolvedAction(for: "button.siri"), .keystroke(keys: "f1"))
    }

    func testPresentationComesFromTheBindingThatActuallyFires() throws {
        let c = try layerFallbackController()
        c.frontmostAppChanged(bundleID: "dev.warp.Warp-Stable")
        c.pushLayer("L1")
        // Falls through to the terminal's own ring.left, so it must carry THAT binding's label —
        // not global's "Left", which belongs to a different binding of the same key.
        XCTAssertEqual(c.resolvedPresentation(for: "ring.left")?.label, "Prev Tab")
    }

    // The four cells of "app x layer". 1 and 3 walk the app's inherits chain, so the two
    // "any app" cells are reached THROUGH that chain rather than as extra steps — which is why a
    // mode that does not inherit global does not see global, by design.
    private let quadrantCfg = """
    { "settings": { "defaultMode": "global" },
      "appProfiles": { "dev.warp.Warp-Stable": "terminal", "loner": "island", "default": "global" },
      "modes": {
        "global":   { "ring.up":      { "action": "keystroke", "keys": "up" },
                      "L1.ring.up":   { "action": "keystroke", "keys": "cmd+up" },
                      "ring.down":    { "action": "keystroke", "keys": "down" },
                      "L1.ring.down": { "action": "keystroke", "keys": "cmd+down" } },
        "terminal": { "inherits": "global",
                      "ring.up":      { "action": "keystroke", "keys": "ctrl+up" },
                      "L1.ring.up":   { "action": "keystroke", "keys": "opt+up" } },
        "island":   { "ring.left":    { "action": "keystroke", "keys": "left" } },
        "L1":       {}
      } }
    """

    func testCellThisAppThisLayer() throws {
        let c = try makeController(quadrantCfg, SpyExecutor())
        c.frontmostAppChanged(bundleID: "dev.warp.Warp-Stable")
        c.pushLayer("L1")
        XCTAssertEqual(c.resolvedAction(for: "ring.up"), .keystroke(keys: "opt+up"))
    }

    func testCellAnyAppThisLayerReachedThroughInherits() throws {
        let c = try makeController(quadrantCfg, SpyExecutor())
        c.frontmostAppChanged(bundleID: "dev.warp.Warp-Stable")
        c.pushLayer("L1")
        // "L1.ring.down" exists only in global; terminal inherits global, so step 1 finds it.
        XCTAssertEqual(c.resolvedAction(for: "ring.down"), .keystroke(keys: "cmd+down"))
    }

    func testCellThisAppNoLayer() throws {
        let c = try makeController(quadrantCfg, SpyExecutor())
        c.frontmostAppChanged(bundleID: "dev.warp.Warp-Stable")
        XCTAssertEqual(c.resolvedAction(for: "ring.up"), .keystroke(keys: "ctrl+up"))
    }

    // The cell the four-way question is really about: a key bound ONLY in global's base, with an
    // app mode active and a layer held. Step 3 walks the app's inherits chain into global.
    func testCellAnyAppNoLayerReachedThroughInherits() throws {
        let cfg = """
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "dev.warp.Warp-Stable": "terminal", "default": "global" },
          "modes": {
            "global":   { "ring.right": { "action": "keystroke", "keys": "right" } },
            "terminal": { "inherits": "global" },
            "L1":       { "inherits": "global" }
          } }
        """
        let c = try makeController(cfg, SpyExecutor())
        c.frontmostAppChanged(bundleID: "dev.warp.Warp-Stable")
        c.pushLayer("L1")
        XCTAssertEqual(c.resolvedAction(for: "ring.right"), .keystroke(keys: "right"))
        XCTAssertTrue(c.hasBinding(for: "ring.right"))
    }

    // A mode with NO `inherits` is deliberately standalone: it does not see global, layered or not.
    // Resolution must not smuggle in a hidden global fallback behind the author's back.
    func testStandaloneModeDoesNotSeeGlobal() throws {
        let c = try makeController(quadrantCfg, SpyExecutor())
        c.frontmostAppChanged(bundleID: "loner")
        XCTAssertNil(c.resolvedAction(for: "ring.up"))
        c.pushLayer("L1")
        XCTAssertNil(c.resolvedAction(for: "ring.up"))
        XCTAssertEqual(c.resolvedAction(for: "ring.left"), .keystroke(keys: "left"))
    }

    // A button is ONE thing, not four. Its variants live under separate keys, so a per-key fallback
    // let the unlayered ones leak in underneath a layer that had rebound the button.
    private let claimCfg = """
    { "settings": { "defaultMode": "global" },
      "appProfiles": { "default": "global" },
      "modes": {
        "global": { "button.playPause":       { "action": "media", "key": "playpause" },
                    "button.playPause.hold2": { "action": "launch", "app": "Music" },
                    "button.menu":            { "action": "keystroke", "keys": "esc" },
                    "button.menu.hold2":      { "action": "keystroke", "keys": "cmd+w" },
                    "L1.button.playPause":      { "action": "keystroke", "keys": "cmd+c" },
                    "L1.button.playPause.hold": { "action": "keystroke", "keys": "cmd+x" } },
        "L1":     { "inherits": "global" }
      } }
    """

    func testLayerClaimsEveryVariantOfAButtonItRebinds() throws {
        let c = try makeController(claimCfg, SpyExecutor())
        c.pushLayer("L1")
        XCTAssertEqual(c.resolvedAction(for: "button.playPause"), .keystroke(keys: "cmd+c"))
        XCTAssertEqual(c.resolvedAction(for: "button.playPause.hold"), .keystroke(keys: "cmd+x"))
        // The layer says nothing about .hold2. That silence is deliberate — the base binding, which
        // opens Music at 1.0s, must NOT show through.
        XCTAssertNil(c.resolvedAction(for: "button.playPause.hold2"))
        XCTAssertFalse(c.hasBinding(for: "button.playPause.hold2"))
    }

    func testAButtonTheLayerIgnoresStillFallsThroughEntirely() throws {
        let c = try makeController(claimCfg, SpyExecutor())
        c.pushLayer("L1")
        // L1 binds no variant of button.menu, so the whole family still resolves unlayered —
        // holding a layer must not deaden a button it has nothing to say about.
        XCTAssertEqual(c.resolvedAction(for: "button.menu"), .keystroke(keys: "esc"))
        XCTAssertEqual(c.resolvedAction(for: "button.menu.hold2"), .keystroke(keys: "cmd+w"))
    }

    func testClaimAppliesWhenOnlyADeeperVariantIsBound() throws {
        let cfg = """
        { "settings": { "defaultMode": "global" }, "appProfiles": { "default": "global" },
          "modes": {
            "global": { "ring.up":       { "action": "keystroke", "keys": "up" },
                        "ring.up.double": { "action": "keystroke", "keys": "cmd+shift+t" },
                        "L1.ring.up.hold": { "action": "keystroke", "keys": "f5" } },
            "L1":     { "inherits": "global" } } }
        """
        let c = try makeController(cfg, SpyExecutor())
        c.pushLayer("L1")
        XCTAssertEqual(c.resolvedAction(for: "ring.up.hold"), .keystroke(keys: "f5"))
        // Claiming only `.hold` still claims the button: neither the base nor `.double` leaks in.
        XCTAssertNil(c.resolvedAction(for: "ring.up"))
        XCTAssertNil(c.resolvedAction(for: "ring.up.double"))
    }

    func testTripleResolvesAndInheritsLikeAnyOtherVariant() throws {
        let cfg = """
        { "settings": { "defaultMode": "global" },
          "appProfiles": { "com.google.Chrome": "browser", "default": "global" },
          "modes": {
            "global":  { "ring.up":        { "action": "keystroke", "keys": "up" },
                         "ring.up.double": { "action": "keystroke", "keys": "cmd+t" },
                         "ring.up.triple": { "action": "keystroke", "keys": "cmd+shift+t" } },
            "browser": { "inherits": "global",
                         "ring.up.triple": { "action": "keystroke", "keys": "cmd+shift+n" } } } }
        """
        let c = try makeController(cfg, SpyExecutor())
        XCTAssertEqual(c.resolvedAction(for: "ring.up.triple"), .keystroke(keys: "cmd+shift+t"))
        // A mode overriding only the triple leaves the shallower counts alone.
        c.frontmostAppChanged(bundleID: "com.google.Chrome")
        XCTAssertEqual(c.resolvedAction(for: "ring.up.triple"), .keystroke(keys: "cmd+shift+n"))
        XCTAssertEqual(c.resolvedAction(for: "ring.up.double"), .keystroke(keys: "cmd+t"))
        XCTAssertEqual(c.resolvedAction(for: "ring.up"), .keystroke(keys: "up"))
    }

    func testClaimAppliesWhenOnlyTheTripleIsBound() throws {
        // `.triple` has to join the variant family, or a layer binding only the triple would let
        // the base and `.double` leak through from outside the layer.
        let cfg = """
        { "settings": { "defaultMode": "global" }, "appProfiles": { "default": "global" },
          "modes": {
            "global": { "ring.up":         { "action": "keystroke", "keys": "up" },
                        "ring.up.double":  { "action": "keystroke", "keys": "cmd+t" },
                        "L1.ring.up.triple": { "action": "keystroke", "keys": "f7" } },
            "L1":     { "inherits": "global" } } }
        """
        let c = try makeController(cfg, SpyExecutor())
        c.pushLayer("L1")
        XCTAssertEqual(c.resolvedAction(for: "ring.up.triple"), .keystroke(keys: "f7"))
        XCTAssertNil(c.resolvedAction(for: "ring.up"))
        XCTAssertNil(c.resolvedAction(for: "ring.up.double"))
    }

    // Per-binding `after` exists because the three thresholds are global: tuning one button's
    // timing used to move every other button bound to the same stage.
    private let delayCfg = """
    { "settings": { "defaultMode": "global", "holdThreshold": 0.5,
                    "holdThreshold2": 1.0, "holdThreshold3": 1.6 },
      "appProfiles": { "default": "global" },
      "modes": { "global": {
        "button.menu":        { "action": "keystroke", "keys": "esc" },
        "button.menu.hold":   { "action": "closeWindow", "after": 0.5 },
        "button.menu.hold2":  { "action": "minimize", "after": 1.2 },
        "button.other.hold2": { "action": "fullscreen" } } } }
    """

    func testPerBindingDelayOverridesTheGlobalThreshold() throws {
        let c = try makeController(delayCfg, SpyExecutor())
        XCTAssertEqual(c.resolvedHoldDelay(for: "button.menu.hold"), 0.5)
        XCTAssertEqual(c.resolvedHoldDelay(for: "button.menu.hold2"), 1.2,
                       "the binding's own delay must win over holdThreshold2 (1.0)")
    }

    func testAbsentDelayFallsBackToTheGlobalThreshold() throws {
        let c = try makeController(delayCfg, SpyExecutor())
        XCTAssertNil(c.resolvedHoldDelay(for: "button.other.hold2"),
                     "nil means 'use the global threshold' — it must not invent a value")
    }

    func testDelayComesFromTheBindingThatFires() throws {
        // A layer rebinding a stage must bring its OWN delay, not inherit the one underneath.
        let cfg = """
        { "settings": { "defaultMode": "global" }, "appProfiles": { "default": "global" },
          "modes": {
            "global": { "ring.up.hold":    { "action": "fullscreen", "after": 2.0 },
                        "L1.ring.up.hold": { "action": "minimize", "after": 0.4 } },
            "L1":     { "inherits": "global" } } }
        """
        let c = try makeController(cfg, SpyExecutor())
        XCTAssertEqual(c.resolvedHoldDelay(for: "ring.up.hold"), 2.0)
        c.pushLayer("L1")
        XCTAssertEqual(c.resolvedHoldDelay(for: "ring.up.hold"), 0.4)
    }

    func testDelaySurvivesAWriteBack() throws {
        let config = try ConfigLoader.load(delayCfg)
        let round = try ConfigLoader.load(ConfigWriter.serialize(config))
        XCTAssertEqual(round, config, "`after` was lost on write-back")
        XCTAssertEqual(round.modes["global"]?.holdDelay["button.menu.hold2"], 1.2)
    }
}
