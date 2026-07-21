public final class MappingEngine {
    private let config: Config
    public private(set) var activeMode: String

    public init(config: Config) {
        self.config = config
        self.activeMode = config.settings.defaultMode
    }

    /// Look up the action bound to `eventKey` in the active mode, walking the inherits chain.
    public func resolve(_ eventKey: String) -> Action? {
        resolve(eventKey, in: activeMode)
    }

    /// Look up `eventKey` starting at an arbitrary `modeName`, walking its inherits chain. Used by
    /// the Controller to resolve against a momentary layer instead of the active app mode.
    public func resolve(_ eventKey: String, in modeName: String) -> Action? {
        var name: String? = modeName
        var visited = Set<String>()
        while let current = name, !visited.contains(current), let mode = config.modes[current] {
            visited.insert(current)
            if let action = mode.bindings[eventKey] { return action }
            name = mode.inherits
        }
        return nil
    }

    /// Presentation for `eventKey`, resolved along the SAME inherits chain as `resolve` so the
    /// label/icon always belong to the binding that would actually fire.
    public func resolvePresentation(_ eventKey: String) -> Config.Presentation? {
        resolvePresentation(eventKey, in: activeMode)
    }

    public func resolvePresentation(_ eventKey: String, in modeName: String) -> Config.Presentation? {
        var name: String? = modeName
        var visited = Set<String>()
        while let current = name, !visited.contains(current), let mode = config.modes[current] {
            visited.insert(current)
            // Stop at the mode that owns the BINDING, so an override in a nearer mode without a
            // label does not fall through and pick up a farther mode's label.
            if mode.bindings[eventKey] != nil { return mode.presentation[eventKey] }
            name = mode.inherits
        }
        return nil
    }

    /// Frontmost app changed: reset active mode to that app's configured mode (or default).
    public func applyApp(bundleID: String) {
        activeMode = config.appProfiles[bundleID]
            ?? config.appProfiles["default"]
            ?? config.settings.defaultMode
    }

    /// Manual, temporary mode switch (from a `mode` action). Reset on next app change.
    public func switchMode(to mode: String) {
        activeMode = mode
    }
}
