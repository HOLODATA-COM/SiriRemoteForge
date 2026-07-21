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

    /// Presentation inherits along the mode chain INDEPENDENTLY of the binding, field by field.
    ///
    /// A key keeps its identity across modes: `button.playPause` is the play/pause button whether
    /// the active mode talks to Music directly or goes through a guard first. Modes override the
    /// ACTION for their own reasons, and forcing each override to restate the same label and icon
    /// would be pure duplication — and would silently show the wrong icon the day someone forgot.
    /// So a mode that says nothing about how a key presents inherits that from its parent, even
    /// where it does change what the key does. A mode that genuinely presents a key differently
    /// just says so, and the nearer mode wins.
    public func resolvePresentation(_ eventKey: String, in modeName: String) -> Config.Presentation? {
        var name: String? = modeName
        var visited = Set<String>()
        var label: String?
        var icon: String?
        while let current = name, !visited.contains(current), let mode = config.modes[current] {
            visited.insert(current)
            if let p = mode.presentation[eventKey] {
                if label == nil { label = p.label }
                if icon == nil { icon = p.icon }
                if label != nil, icon != nil { break }
            }
            name = mode.inherits
        }
        guard label != nil || icon != nil else { return nil }
        return Config.Presentation(label: label, icon: icon)
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
