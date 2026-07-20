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
    /// It then falls back to the standalone layer mode `<layer>` for app-agnostic layer bindings.
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

    /// Resolve `key`. With no layer active: the active app mode. With a layer active: first the
    /// per-app namespaced key `"<layer>.<key>"` in the active app mode's chain (so a layer composes
    /// with the app), then the standalone layer mode (app-agnostic layer bindings).
    private func resolve(_ key: String) -> Action? {
        guard let layer = activeLayer else { return engine.resolve(key) }
        return engine.resolve("\(layer).\(key)") ?? engine.resolve(key, in: layer)
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
