import Foundation

public struct Config: Equatable {
    // `var` so the Settings/Tuning UI can write slider values back into the config (config stays
    // the single source of truth; see `withSettingsUpdated`).
    public var settings: Settings
    public var appProfiles: [String: String]
    public var modes: [String: Mode]

    public struct Settings: Equatable {
        public var defaultMode: String
        public var swipeVelocity: Double
        public var cursorSpeed: Double
        public var cursorDeadzone: Double
        public var circularScroll: CircularScrollConfig
        // Multi-stage long-press thresholds (seconds). Stage 1 = holdThreshold (`<key>.hold`),
        // stage 2 = holdThreshold2 (`<key>.hold2`), stage 3 = holdThreshold3 (`<key>.hold3`).
        // Release-to-select: the deepest stage whose threshold elapsed fires on release.
        public var holdThreshold: Double
        public var holdThreshold2: Double
        public var holdThreshold3: Double
        public var clickRiseThreshold: Double
        public var pressMoveMax: Double
        // Velocity-based cursor acceleration (layered on top of cursorSpeed).
        public var accelMin: Double
        public var accelMax: Double
        public var accelLowSpeed: Double
        public var accelHighSpeed: Double
        // Double-tap: window for a 2nd tap to fire a `<key>.double` binding.
        public var doubleTapWindow: Double
        // Spaces Mode: inactivity window (seconds) after which armed desktop-switching disarms.
        public var spacesModeWindow: Double
        // Find-my-cursor: show a highlight when the cursor is shaken (rapid back-and-forth).
        public var findCursorEnabled: Bool
    }
    public struct Mode: Equatable {
        public var inherits: String?
        public var bindings: [String: Action]
        /// Optional display overrides, keyed by the SAME event key as `bindings`. Kept parallel
        /// rather than folded into `Action` so every existing consumer of `bindings` is untouched:
        /// this is presentation, and nothing that dispatches an action needs to know about it.
        public var presentation: [String: Presentation]
        public init(inherits: String?, bindings: [String: Action],
                    presentation: [String: Presentation] = [:]) {
            self.inherits = inherits
            self.bindings = bindings
            self.presentation = presentation
        }
    }

    /// How a binding should be shown on screen (the hold-progress HUD, the Layout tab).
    /// `label` overrides the derived `Action.displayLabel`; `icon` is an SF Symbol name.
    /// Both optional — everything still falls back to sensible derivation.
    public struct Presentation: Equatable {
        public var label: String?
        public var icon: String?
        public init(label: String? = nil, icon: String? = nil) {
            self.label = label
            self.icon = icon
        }
    }
}

// MARK: - Editing (value-semantic mutators; each returns a new Config for the editor to save)

public extension Config {
    /// Set (or, if `action` is nil, remove) a binding in `mode`. Creates `mode` if missing,
    /// inheriting the default mode so a new app/layer mode falls through to global.
    func setBinding(_ key: String, to action: Action?, inMode mode: String) -> Config {
        var copy = self
        if copy.modes[mode] == nil {
            let parent = copy.modes[settings.defaultMode] != nil ? settings.defaultMode : nil
            copy.modes[mode] = Mode(inherits: parent, bindings: [:])
        }
        if let action = action {
            copy.modes[mode]?.bindings[key] = action
        } else {
            copy.modes[mode]?.bindings.removeValue(forKey: key)
        }
        return copy
    }

    /// Set the `inherits` parent of a mode (nil clears it).
    func setInherits(_ parent: String?, ofMode mode: String) -> Config {
        var copy = self
        guard copy.modes[mode] != nil else { return copy }
        copy.modes[mode]?.inherits = parent
        return copy
    }

    /// Add an empty mode (no-op if it already exists).
    func addMode(_ name: String, inherits: String?) -> Config {
        var copy = self
        if copy.modes[name] == nil {
            copy.modes[name] = Mode(inherits: inherits, bindings: [:])
        }
        return copy
    }

    /// Remove a mode, the appProfiles pointing at it, and any dangling `inherits` references to it
    /// (other modes that inherited it are re-parented to nil, so the result still loads). Refuses to
    /// remove the default mode — deleting it would leave the config with no valid default.
    func removeMode(_ name: String) -> Config {
        guard name != settings.defaultMode else { return self }
        var copy = self
        copy.modes.removeValue(forKey: name)
        for (bundle, m) in copy.appProfiles where m == name { copy.appProfiles.removeValue(forKey: bundle) }
        for (other, mode) in copy.modes where mode.inherits == name { copy.modes[other]?.inherits = nil }
        return copy
    }

    /// Return a copy with the `settings` block mutated in place. Used by the Tuning UI to persist
    /// slider values into the config (config remains the single source of truth for tuning).
    func withSettingsUpdated(_ transform: (inout Settings) -> Void) -> Config {
        var copy = self
        transform(&copy.settings)
        return copy
    }

    /// Map a bundle id to a mode (nil removes the mapping).
    func setAppProfile(bundleID: String, mode: String?) -> Config {
        var copy = self
        if let mode = mode {
            copy.appProfiles[bundleID] = mode
        } else {
            copy.appProfiles.removeValue(forKey: bundleID)
        }
        return copy
    }
}

public extension Config {
    /// A binding resolved through the `inherits` chain, plus the mode that actually defines it
    /// (so a mode's own binding — "Custom" — can be told apart from an inherited one).
    struct Resolution: Equatable {
        public let action: Action
        public let sourceMode: String
        public init(action: Action, sourceMode: String) {
            self.action = action
            self.sourceMode = sourceMode
        }
    }

    /// The effective default mode: an explicit `appProfiles["default"]` wins, else `settings.defaultMode`.
    /// Matches how `MappingEngine.applyApp` falls back for an unknown app.
    var defaultModeName: String {
        appProfiles["default"] ?? settings.defaultMode
    }

    /// Reverse of `appProfiles`: mode name → the bundle ids that select it (excludes "default").
    var appsByMode: [String: [String]] {
        var out: [String: [String]] = [:]
        for (bundleID, mode) in appProfiles where bundleID != "default" {
            out[mode, default: []].append(bundleID)
        }
        return out
    }

    /// Resolve `key` starting at `modeName`, walking the `inherits` chain (same order as
    /// `MappingEngine.resolve`). Returns the bound action and the mode it was defined in, or nil
    /// if unbound anywhere in the chain.
    func resolveBinding(_ key: String, in modeName: String) -> Resolution? {
        var name: String? = modeName
        var visited = Set<String>()
        while let current = name, !visited.contains(current), let mode = modes[current] {
            visited.insert(current)
            if let action = mode.bindings[key] {
                return Resolution(action: action, sourceMode: current)
            }
            name = mode.inherits
        }
        return nil
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    init(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { nil }
}

extension Config: Decodable {
    private enum K: String, CodingKey { case settings, appProfiles, modes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        settings = try c.decode(Settings.self, forKey: .settings)
        appProfiles = try c.decodeIfPresent([String: String].self, forKey: .appProfiles) ?? [:]
        modes = try c.decode([String: Mode].self, forKey: .modes)
    }
}

extension Config.Settings: Decodable {
    private enum K: String, CodingKey {
        case defaultMode, swipeVelocity, cursorSpeed, cursorDeadzone, circularScroll, holdThreshold
        case holdThreshold2, holdThreshold3
        case clickRiseThreshold, pressMoveMax
        case accelMin, accelMax, accelLowSpeed, accelHighSpeed
        case doubleTapWindow
        case spacesModeWindow
        case findCursorEnabled
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        defaultMode = try c.decode(String.self, forKey: .defaultMode)
        swipeVelocity = try c.decodeIfPresent(Double.self, forKey: .swipeVelocity) ?? 0.5
        cursorSpeed = try c.decodeIfPresent(Double.self, forKey: .cursorSpeed) ?? 0.6
        cursorDeadzone = try c.decodeIfPresent(Double.self, forKey: .cursorDeadzone) ?? 0.006
        circularScroll = try c.decodeIfPresent(CircularScrollConfig.self, forKey: .circularScroll)
            ?? .default
        holdThreshold = try c.decodeIfPresent(Double.self, forKey: .holdThreshold) ?? 0.5
        holdThreshold2 = try c.decodeIfPresent(Double.self, forKey: .holdThreshold2) ?? 1.0
        holdThreshold3 = try c.decodeIfPresent(Double.self, forKey: .holdThreshold3) ?? 1.6
        clickRiseThreshold = try c.decodeIfPresent(Double.self, forKey: .clickRiseThreshold) ?? 0.1
        pressMoveMax = try c.decodeIfPresent(Double.self, forKey: .pressMoveMax) ?? 0.025
        accelMin = try c.decodeIfPresent(Double.self, forKey: .accelMin) ?? 0.4
        accelMax = try c.decodeIfPresent(Double.self, forKey: .accelMax) ?? 2.6
        accelLowSpeed = try c.decodeIfPresent(Double.self, forKey: .accelLowSpeed) ?? 0.008
        accelHighSpeed = try c.decodeIfPresent(Double.self, forKey: .accelHighSpeed) ?? 0.06
        doubleTapWindow = try c.decodeIfPresent(Double.self, forKey: .doubleTapWindow) ?? 0.3
        spacesModeWindow = try c.decodeIfPresent(Double.self, forKey: .spacesModeWindow) ?? 5.0
        findCursorEnabled = try c.decodeIfPresent(Bool.self, forKey: .findCursorEnabled) ?? true
    }
}

extension Config.Mode: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var inherits: String? = nil
        var bindings: [String: Action] = [:]
        var presentation: [String: Config.Presentation] = [:]
        for key in c.allKeys {
            if key.stringValue == "inherits" {
                inherits = try c.decode(String.self, forKey: key)
            } else {
                bindings[key.stringValue] = try c.decode(Action.self, forKey: key)
                // `label` / `icon` live alongside `action` in the same object, so they are read
                // from the same container; absent keys simply leave no entry here.
                let p = try c.decode(Config.Presentation.self, forKey: key)
                if p.label != nil || p.icon != nil { presentation[key.stringValue] = p }
            }
        }
        self.inherits = inherits
        self.bindings = bindings
        self.presentation = presentation
    }
}

// MARK: - Encodable (config write-back; mirrors the Decodable side above)
// Every field is emitted so `ConfigLoader.load(ConfigWriter.serialize(c)) == c` for any `c`,
// regardless of which values happen to equal the decode defaults.

extension Config: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(settings, forKey: .settings)
        try c.encode(appProfiles, forKey: .appProfiles)
        try c.encode(modes, forKey: .modes)
    }
}

extension Config.Settings: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(defaultMode, forKey: .defaultMode)
        try c.encode(swipeVelocity, forKey: .swipeVelocity)
        try c.encode(cursorSpeed, forKey: .cursorSpeed)
        try c.encode(cursorDeadzone, forKey: .cursorDeadzone)
        try c.encode(circularScroll, forKey: .circularScroll)
        try c.encode(holdThreshold, forKey: .holdThreshold)
        try c.encode(holdThreshold2, forKey: .holdThreshold2)
        try c.encode(holdThreshold3, forKey: .holdThreshold3)
        try c.encode(clickRiseThreshold, forKey: .clickRiseThreshold)
        try c.encode(pressMoveMax, forKey: .pressMoveMax)
        try c.encode(accelMin, forKey: .accelMin)
        try c.encode(accelMax, forKey: .accelMax)
        try c.encode(accelLowSpeed, forKey: .accelLowSpeed)
        try c.encode(accelHighSpeed, forKey: .accelHighSpeed)
        try c.encode(doubleTapWindow, forKey: .doubleTapWindow)
        try c.encode(spacesModeWindow, forKey: .spacesModeWindow)
        try c.encode(findCursorEnabled, forKey: .findCursorEnabled)
    }
}

extension Config.Mode: Encodable {
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        if let inherits = inherits {
            try c.encode(inherits, forKey: DynamicKey(stringValue: "inherits"))
        }
        for (key, action) in bindings {
            let dk = DynamicKey(stringValue: key)
            if let p = presentation[key] {
                try c.encode(BindingWithPresentation(action: action, presentation: p), forKey: dk)
            } else {
                try c.encode(action, forKey: dk)
            }
        }
    }
}

extension Config.Presentation: Decodable {
    private enum K: String, CodingKey { case label, icon }
    public init(from decoder: Decoder) throws {
        // A binding object may legitimately have neither key; that is not an error.
        guard let c = try? decoder.container(keyedBy: K.self) else {
            label = nil; icon = nil; return
        }
        label = try c.decodeIfPresent(String.self, forKey: .label)
        icon  = try c.decodeIfPresent(String.self, forKey: .icon)
    }
}

/// Writes `action` and its display overrides FLAT into one object, so a round-tripped config keeps
/// `label`/`icon` sitting next to `action` exactly as a human would write them.
private struct BindingWithPresentation: Encodable {
    let action: Action
    let presentation: Config.Presentation

    private enum K: String, CodingKey { case label, icon }

    func encode(to encoder: Encoder) throws {
        try action.encode(to: encoder)          // emits {"action": …, params…}
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(presentation.label, forKey: .label)
        try c.encodeIfPresent(presentation.icon, forKey: .icon)
    }
}
