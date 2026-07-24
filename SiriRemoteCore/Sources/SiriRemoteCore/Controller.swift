public protocol ActionExecutor: AnyObject {
    func execute(_ action: Action, payload: EventPayload?)
}

/// Ties input events to the engine and executor. `mode` actions are handled
/// internally (they switch the engine's active mode) and never reach the executor.
public final class Controller {
    private var engine: MappingEngine
    private let executor: ActionExecutor

    /// The active layer (from a `.layer` button — held momentary or tap-toggled sticky). While set,
    /// a key `K` resolves PER-APP first — the layer-namespaced key `"<layer>.K"` looked up in the
    /// active app mode's `inherits` chain — so the same layer can do different things in different
    /// apps (e.g. `L1.ring.left` = switch tab in a terminal mode, something else in a browser mode).
    /// It then falls back to the standalone layer mode `<layer>` for app-agnostic layer bindings,
    /// and finally to the key's UNLAYERED binding in the current app — see `site`.
    private var activeLayer: String?

    public init(engine: MappingEngine, executor: ActionExecutor) {
        self.engine = engine
        self.executor = executor
    }

    /// Push a momentary layer (e.g. from a held `.layer` button). A second push simply replaces
    /// the active layer — there is only ever one at a time.
    public func pushLayer(_ name: String) {
        activeLayer = name
    }

    /// Pop the momentary layer, reverting resolution to the active app mode.
    public func popLayer() {
        activeLayer = nil
    }

    /// The layer mode currently overriding resolution, or nil when resolving against the app mode.
    public var currentLayer: String? { activeLayer }

    /// A resolved binding together with the presentation of that SAME binding. Kept as one value so
    /// the label and icon can never come from a different binding that merely shares the key.
    private struct Site {
        let action: Action
        let presentation: Config.Presentation?
        /// Per-binding override for when this hold stage fires; nil means use the global threshold.
        let holdDelay: Double?
    }

    /// Resolve `key`, most specific first:
    ///
    ///   1. `"<layer>.<key>"` in the active app mode's chain — this app, in this layer.
    ///   2. `key` among the layer mode's OWN bindings — any app, in this layer.
    ///   3. `key` in the active app mode's chain — this app, WITHOUT the layer, UNLESS the layer
    ///      has claimed the button (see `layerClaims`).
    ///
    /// Step 3 is the point: a layer is a modifier, not a separate keyboard. A key the layer says
    /// nothing about keeps doing whatever it does unlayered, IN THE CURRENT APP — holding the layer
    /// must never turn a bound key into a dead one. Before this existed, holding L1 in a terminal
    /// left the Back button dead, because `global` binds nothing there and the terminal's own
    /// `repeatKey` was never consulted.
    ///
    /// The claim rule on step 3 exists because a button is ONE thing, not four. Its variants live
    /// under separate keys — `button.playPause`, `.hold`, `.hold2`, `.double` — so a per-key
    /// fallback let the unlayered variants leak in underneath a layer that had rebound the button:
    /// binding `L1.button.playPause` to Copy and its `.hold` to Cut still left the base `.hold2`
    /// opening Music at 1.0s. Nothing in the layer's own bindings would explain that. A layer now
    /// either takes a button over or leaves it alone; the alternative — writing explicit
    /// do-nothing bindings for every variant — is the boilerplate resolution rules exist to avoid.
    ///
    /// Step 2 deliberately does NOT walk the layer mode's inherits chain. Layer modes are declared
    /// as `"L1": { "inherits": "global" }`, so walking it would answer with GLOBAL's base binding
    /// and shadow step 3's app-specific one — the exact bug described above.
    ///
    /// There is no fourth step for "any app, without the layer". Steps 1 and 3 walk the app mode's
    /// `inherits` chain, which is what reaches `global` — so a key bound only in global's base
    /// still resolves under a layer in a terminal. Keeping that in `inherits` rather than hard-wiring
    /// a global fallback is what lets a mode opt out: a mode with no `inherits` is standalone and
    /// genuinely sees nothing else, layered or not.
    private func site(_ key: String) -> Site? {
        guard let layer = activeLayer else {
            guard let action = engine.resolve(key) else { return nil }
            return Site(action: action, presentation: engine.resolvePresentation(key),
                        holdDelay: engine.resolveHoldDelay(key))
        }
        let namespaced = "\(layer).\(key)"
        if let action = engine.resolve(namespaced) {
            return Site(action: action, presentation: engine.resolvePresentation(namespaced),
                        holdDelay: engine.resolveHoldDelay(namespaced))
        }
        if let action = engine.resolveOwn(key, in: layer) {
            return Site(action: action, presentation: engine.resolveOwnPresentation(key, in: layer),
                        holdDelay: engine.resolveOwnHoldDelay(key, in: layer))
        }
        // The layer owns this button but says nothing about THIS variant — a deliberate silence,
        // not a gap to be filled from underneath.
        if layerClaims(key, in: layer) { return nil }
        guard let action = engine.resolve(key) else { return nil }
        return Site(action: action, presentation: engine.resolvePresentation(key),
                    holdDelay: engine.resolveHoldDelay(key))
    }

    /// The variants one physical button can carry. Resolution treats them as one family.
    /// `.taphold*` is a SECOND hold menu reached by tap-then-press-and-hold (see RemoteInputHandler),
    /// parallel to the plain-hold `.hold*` ladder. Longer suffixes must precede their prefixes so
    /// `baseKey` strips `.taphold2` before `.taphold`, and `.taphold` before `.hold` would mis-strip
    /// — `.taphold*` are listed ahead of the `.hold*` group for that reason.
    private static let variantSuffixes = [".taphold3", ".taphold2", ".taphold",
                                          ".hold3", ".hold2", ".hold", ".double", ".triple"]

    /// `button.playPause.hold2` → `button.playPause`.
    private static func baseKey(_ key: String) -> String {
        for suffix in variantSuffixes where key.hasSuffix(suffix) {
            return String(key.dropLast(suffix.count))
        }
        return key
    }

    /// Has this layer bound ANY variant of this button, per-app or app-agnostically?
    private func layerClaims(_ key: String, in layer: String) -> Bool {
        let base = Controller.baseKey(key)
        let family = [base] + Controller.variantSuffixes.map { base + $0 }
        return family.contains { variant in
            engine.resolve("\(layer).\(variant)") != nil || engine.resolveOwn(variant, in: layer) != nil
        }
    }

    private func resolve(_ key: String) -> Action? { site(key)?.action }

    /// Display overrides for `key`, taken from the very binding `resolve` would fire.
    public func resolvedPresentation(for key: String) -> Config.Presentation? {
        site(key)?.presentation
    }

    /// When this hold stage should fire, if its binding says so. Nil means fall back to the global
    /// threshold for that stage. Read from the SAME binding `resolve` would dispatch.
    public func resolvedHoldDelay(for key: String) -> Double? {
        site(key)?.holdDelay
    }

    /// Resolve and dispatch. Returns `true` if a binding matched (action dispatched or mode
    /// switched), `false` if the active mode has no binding for this event — letting the caller
    /// fall back to native behavior. While a layer is active, resolves against the layer instead.
    @discardableResult
    public func handle(_ event: InputEvent) -> Bool {
        guard let action = resolve(event.key) else { return false }
        if case let .mode(to) = action {
            engine.switchMode(to: to)
            return true
        }
        executor.execute(action, payload: event.payload)
        return true
    }

    public func frontmostAppChanged(bundleID: String) {
        engine.applyApp(bundleID: bundleID)
    }

    /// Whether the active mode/layer (or its inherits chain) binds this event. Used to decide if a
    /// button needs long-press discrimination (only defer the tap if a `.hold*` binding exists).
    public func hasBinding(for eventKey: String) -> Bool {
        resolve(eventKey) != nil
    }

    /// The action bound to `eventKey` in the active mode/layer (walking the inherits chain), without
    /// dispatching it — so the input handler can inspect the resolved action (e.g. detect a
    /// `.repeatKey`/`.layer` that needs press/release-driven handling). Same resolution as `handle`.
    public func resolvedAction(for eventKey: String) -> Action? {
        resolve(eventKey)
    }

    /// Hot-swap the config (e.g. after the config file changes on disk).
    public func reload(config: Config) {
        engine = MappingEngine(config: config)
    }
}
