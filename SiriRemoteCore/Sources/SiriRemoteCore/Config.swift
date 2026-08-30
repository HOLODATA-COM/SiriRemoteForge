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
        /// Seconds AFTER the deepest bound stage past which releasing fires NOTHING — an escape
        /// hatch for a hold started by mistake, applied to every key rather than bound per key so
        /// it is always there. 0 = off.
        ///
        /// Relative rather than absolute on purpose: keys differ in how deep their stages go, and a
        /// fixed wall would leave a key whose deepest stage is 0.5 s with seconds of dead zone.
        public var holdCancelGrace: Double
        /// Apps on the radial launcher, in clockwise order from the top. Summoned by holding the
        /// layer key; empty disables it. Names as they appear in /Applications, e.g. "Google Chrome".
        public var appWheel: [String]
        /// Ordered layer cycle. `BASE` represents the ordinary, unlayered bindings; every other id
        /// names a mode in `modes`. The layer key walks this array and wraps at the end. Presentation
        /// lives beside identity so reordering, renaming, recolouring, and choosing an icon is one edit.
        public var layers: [LayerDefinition]
        /// JSON-owned symbols for App UI states that are not ordinary action bindings. Binding
        /// icons still live beside their actions; this small keyed table covers remote connection
        /// and native Voice phases without hard-coding presentation choices across controllers.
        public var icons: [String: String]
        public var clickRiseThreshold: Double
        public var pressMoveMax: Double
        // Velocity-based cursor acceleration (layered on top of cursorSpeed).
        public var accelMin: Double
        public var accelMax: Double
        public var accelLowSpeed: Double
        public var accelHighSpeed: Double
        /// Dimensionless exponent applied after smoothstep. 1 = symmetric, >1 keeps the precise
        /// end longer, <1 reaches the fast end sooner.
        public var accelCurve: Double
        /// Settings-UI preference. When true, pointer and circular scroll keep the same
        /// dimensionless `accelCurve`; their gains, thresholds, and base speeds remain independent.
        public var accelerationCurvesLinked: Bool
        // Double-tap: window for a 2nd tap to fire a `<key>.double` binding.
        public var doubleTapWindow: Double
        // Spaces Mode: inactivity window (seconds) after which armed desktop-switching disarms.
        public var spacesModeWindow: Double
        // Find-my-cursor: show a highlight when the cursor is shaken (rapid back-and-forth).
        public var findCursorEnabled: Bool
        /// Runtime-switchable app language ("en" or "zh"). Optional only for migration: older
        /// config files inherit the machine's last locally stored language until the next GUI save.
        public var interfaceLanguage: String?
        /// Desired SMAppService registration. Optional preserves the existing OS registration for
        /// older config files instead of unexpectedly disabling launch-at-login during migration.
        public var launchAtLoginEnabled: Bool?
        /// Check the public appcast on a background schedule. This is deliberately stored
        /// in config.jsonc (rather than a second UserDefaults preference) so every user-facing
        /// setting has one source of truth and can be provisioned before first launch.
        public var automaticUpdateChecksEnabled: Bool
        /// Download a verified Full Setup package after a background check finds one. Installing
        /// system components still requires the normal one-time macOS administrator approval.
        public var automaticallyDownloadUpdatesEnabled: Bool
        /// Whether the menu-bar status item is visible. The app remains reachable by reopening the
        /// application bundle, which opens Settings even when this is false.
        public var menuBarIconEnabled: Bool
        /// Always-on desktop widget that shows the active layer while idle and briefly animates
        /// the current app/action. Users can turn it off, but it is part of the default experience.
        public var statusWidgetEnabled: Bool
        /// Presentation-only floating Siri Remote visualiser. Off by default; when enabled it
        /// mirrors physical button and touch input without intercepting normal actions.
        public var demoRemoteEnabled: Bool
        /// Transient layer-switch and remote connection/disconnection cards.
        public var layerHUDEnabled: Bool
        /// The larger release-to-select progress HUD shown while a button is held. Kept separate
        /// from the compact always-on widget so either presentation can be disabled independently.
        public var holdHUDEnabled: Bool
        /// Small cursor-adjacent badge shown while sticky drag is active.
        public var dragIndicatorEnabled: Bool
        /// Whether a fresh install automatically opens the setup guide. Completion is deliberately
        /// machine-local state; this value controls the policy, not whether another Mac finished it.
        public var showSetupWizardOnFirstLaunch: Bool
        /// Focus the app under the cursor, but ONLY when its window is fullscreen — a fullscreen
        /// window owns its whole Space, so focusing it raises nothing and disturbs no window
        /// stack. Off by default: it changes which app receives input.
        public var focusFollowsCursor: Bool
        /// App-owned push-to-talk transcription. API credentials are deliberately NOT represented
        /// here: this JSON is user-readable and commonly shared, while secrets live in Keychain.
        public var dictation: DictationSettings
    }
    public struct Mode: Equatable {
        public var inherits: String?
        public var bindings: [String: Action]
        /// Optional display overrides, keyed by the SAME event key as `bindings`. Kept parallel
        /// rather than folded into `Action` so every existing consumer of `bindings` is untouched:
        /// this is presentation, and nothing that dispatches an action needs to know about it.
        public var presentation: [String: Presentation]
        /// Per-binding hold delay in seconds (`"after": 1.2`), keyed like `bindings`. Overrides the
        /// global `holdThreshold`/`2`/`3` for that ONE binding.
        ///
        /// The global thresholds are shared by every key, so tuning one button's timing moved every
        /// other button bound to the same stage — which twice forced a binding onto a stage it did
        /// not belong on, purely to leave another key's timing alone. Stages are ordered by their
        /// EFFECTIVE delay, so `.hold` need not be the earliest.
        public var holdDelay: [String: Double]
        public init(inherits: String?, bindings: [String: Action],
                    presentation: [String: Presentation] = [:],
                    holdDelay: [String: Double] = [:]) {
            self.inherits = inherits
            self.bindings = bindings
            self.presentation = presentation
            self.holdDelay = holdDelay
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

    /// One entry in the ordered layer cycle. `name`, `color`, and `icon` are presentation-only; `id` is the
    /// stable value used for binding resolution (`BASE`, `L1`, ...). The app accepts system colour
    /// names and #RRGGBB/#RRGGBBAA while the core deliberately keeps the value platform-neutral.
    public struct LayerDefinition: Codable, Equatable {
        public var id: String
        public var name: String?
        public var color: String?
        public var icon: String?
        public init(id: String, name: String? = nil, color: String? = nil,
                    icon: String? = nil) {
            self.id = id
            self.name = name
            self.color = color
            self.icon = icon
        }
    }

    public enum DictationOutputMode: String, Codable, CaseIterable, Hashable {
        /// Record the complete utterance, use the high-accuracy model, then optionally polish it.
        case final
        /// Emit low-latency transcript deltas while the user is still speaking; no LLM rewrite.
        case streaming
    }

    /// Voice is a global operating mode, independent from the remote's configurable Layers.
    /// `external` deliberately leaves the side button with the ordinary JSON binding engine;
    /// the two native modes claim it for HyperVibe's own transcription pipeline.
    public enum DictationMode: String, Codable, CaseIterable, Hashable {
        case external
        case final
        case streaming

        public var outputMode: DictationOutputMode? {
            switch self {
            case .external: return nil
            case .final: return .final
            case .streaming: return .streaming
            }
        }

        public var next: Self {
            switch self {
            case .external: return .final
            case .final: return .streaming
            case .streaming: return .external
            }
        }
    }

    /// Per-layer side-button policy. `inherit` keeps the global `outputMode`; `existing` leaves the
    /// side button entirely with the ordinary JSON binding engine, so enabling native Voice cannot
    /// silently replace an existing Typeless/shortcut workflow on that layer.
    public enum DictationLayerMode: String, Codable, CaseIterable, Hashable {
        case inherit
        case existing
        case final
        case streaming
    }

    public enum DictationCleanupProvider: String, Codable, CaseIterable {
        case none
        case openAI = "openai"
        case deepSeek = "deepseek"
    }

    /// Selection editing always needs an instruction-following model. It is intentionally separate
    /// from transcript cleanup: Live Voice may skip cleanup while still rewriting selected text.
    public enum DictationSelectionEditProvider: String, Codable, CaseIterable {
        case openAI = "openai"
        case deepSeek = "deepseek"
    }

    /// A canonical spelling plus common recognition variants. Canonical terms are sent as model
    /// keyword hints; aliases are also corrected deterministically on-device after transcription.
    public struct DictationTerm: Codable, Equatable {
        public var term: String
        public var aliases: [String]

        public init(term: String, aliases: [String] = []) {
            self.term = term
            self.aliases = aliases
        }

        private enum CodingKeys: String, CodingKey { case term, aliases }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            term = try container.decode(String.self, forKey: .term)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
        }
    }

    /// Complete, shareable voice-input behaviour. Secrets and transcript history stay out of it.
    public struct DictationSettings: Codable, Equatable {
        public var enabled: Bool
        /// The one Voice route used on every Layer. It can be changed from Settings or by holding
        /// Mute and tapping the side button; unlike the legacy `layerModes`, changing Layer never
        /// changes this value.
        public var activeMode: DictationMode
        /// Decode/encode compatibility for configurations written before `activeMode`. Native
        /// sessions still freeze their concrete output mode into this field before a turn begins.
        public var outputMode: DictationOutputMode
        /// Deprecated compatibility data. It remains Codable so older public configurations round
        /// trip without data loss, but routing is intentionally global and no longer reads it.
        public var layerModes: [String: DictationLayerMode]
        public var finalModel: String
        public var streamingModel: String
        public var languageHints: [String]
        public var cleanupProvider: DictationCleanupProvider
        /// When enabled, a non-empty Accessibility selection changes Voice from insertion into a
        /// strict select → speak instruction → replace transaction. Accessibility is authoritative;
        /// custom editors that expose no AX selection may use a reversible Copy probe. A readable
        /// but read-only selection can still be rewritten, with the completed result copied rather
        /// than silently discarded.
        public var selectionEditingEnabled: Bool
        public var selectionEditProvider: DictationSelectionEditProvider
        public var openAICleanupModel: String
        public var deepSeekCleanupModel: String
        public var autoInsert: Bool
        /// Deprecated compatibility field. Generated text is now always copied when direct
        /// delivery fails, so decoded/constructed false values are intentionally normalised true.
        public var copyOnFailure: Bool
        public var restoreClipboardAfterInsert: Bool
        public var copyLastOnSideButtonDouble: Bool
        /// A short, paired acoustic cue when native Voice actually opens and after capture closes.
        /// Quick side-button taps never play it because they never promote into dictation.
        public var feedbackSoundsEnabled: Bool
        /// Linear playback gain for both halves of the paired cue, in the closed range 0...1.
        public var feedbackSoundVolume: Double
        /// Independent temporary Voice capsule. This remains available when the always-on Layer
        /// status widget is disabled; its machine-local dragged position stays in UserDefaults.
        public var pipelineOverlayEnabled: Bool
        /// Audio shorter than this never leaves the local capture buffer and never reaches the
        /// caret. Keeping this in JSON makes the accidental-speech gate explicit and shareable.
        public var minimumRecordingSeconds: Double
        public var maxRecordingSeconds: Double
        public var dictionary: [DictationTerm]

        public init(
            enabled: Bool = false,
            activeMode: DictationMode? = nil,
            outputMode: DictationOutputMode = .final,
            layerModes: [String: DictationLayerMode] = [:],
            finalModel: String = "gpt-transcribe",
            streamingModel: String = "gpt-live-transcribe",
            languageHints: [String] = ["zh", "en"],
            cleanupProvider: DictationCleanupProvider = .deepSeek,
            selectionEditingEnabled: Bool = true,
            selectionEditProvider: DictationSelectionEditProvider = .deepSeek,
            openAICleanupModel: String = "gpt-5.6-luna",
            deepSeekCleanupModel: String = "deepseek-v4-flash",
            autoInsert: Bool = true,
            copyOnFailure: Bool = true,
            restoreClipboardAfterInsert: Bool = true,
            copyLastOnSideButtonDouble: Bool = true,
            feedbackSoundsEnabled: Bool = true,
            feedbackSoundVolume: Double = 0.55,
            pipelineOverlayEnabled: Bool = true,
            minimumRecordingSeconds: Double = 1,
            maxRecordingSeconds: Double = 120,
            dictionary: [DictationTerm] = []
        ) {
            self.enabled = enabled
            self.activeMode = activeMode ?? (outputMode == .streaming ? .streaming : .final)
            self.outputMode = outputMode
            self.layerModes = layerModes
            self.finalModel = finalModel
            self.streamingModel = streamingModel
            self.languageHints = languageHints
            self.cleanupProvider = cleanupProvider
            self.selectionEditingEnabled = selectionEditingEnabled
            self.selectionEditProvider = selectionEditProvider
            self.openAICleanupModel = openAICleanupModel
            self.deepSeekCleanupModel = deepSeekCleanupModel
            self.autoInsert = autoInsert
            _ = copyOnFailure
            self.copyOnFailure = true
            self.restoreClipboardAfterInsert = restoreClipboardAfterInsert
            self.copyLastOnSideButtonDouble = copyLastOnSideButtonDouble
            self.feedbackSoundsEnabled = feedbackSoundsEnabled
            self.feedbackSoundVolume = feedbackSoundVolume
            self.pipelineOverlayEnabled = pipelineOverlayEnabled
            self.minimumRecordingSeconds = minimumRecordingSeconds
            self.maxRecordingSeconds = maxRecordingSeconds
            self.dictionary = dictionary
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, activeMode, outputMode, layerModes, finalModel, streamingModel, languageHints
            case cleanupProvider, selectionEditingEnabled, selectionEditProvider
            case openAICleanupModel, deepSeekCleanupModel
            case autoInsert, copyOnFailure, restoreClipboardAfterInsert
            case copyLastOnSideButtonDouble, feedbackSoundsEnabled, feedbackSoundVolume
            case pipelineOverlayEnabled, minimumRecordingSeconds, maxRecordingSeconds, dictionary
        }

        /// New voice options are additive. Decode each field independently so an older or hand-
        /// written partial JSON block inherits current safe defaults instead of making the entire
        /// configuration unreadable after an upgrade.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Self.init()
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
                ?? defaults.enabled
            outputMode = try container.decodeIfPresent(DictationOutputMode.self, forKey: .outputMode)
                ?? defaults.outputMode
            // A missing activeMode is an old configuration. Its former global outputMode is the
            // only deterministic migration target; per-Layer overrides are retained but ignored.
            activeMode = try container.decodeIfPresent(DictationMode.self, forKey: .activeMode)
                ?? (outputMode == .streaming ? .streaming : .final)
            layerModes = try container.decodeIfPresent(
                [String: DictationLayerMode].self, forKey: .layerModes
            ) ?? defaults.layerModes
            finalModel = try container.decodeIfPresent(String.self, forKey: .finalModel)
                ?? defaults.finalModel
            streamingModel = try container.decodeIfPresent(String.self, forKey: .streamingModel)
                ?? defaults.streamingModel
            languageHints = try container.decodeIfPresent([String].self, forKey: .languageHints)
                ?? defaults.languageHints
            cleanupProvider = try container.decodeIfPresent(
                DictationCleanupProvider.self, forKey: .cleanupProvider
            ) ?? defaults.cleanupProvider
            selectionEditingEnabled = try container.decodeIfPresent(
                Bool.self, forKey: .selectionEditingEnabled
            ) ?? defaults.selectionEditingEnabled
            selectionEditProvider = try container.decodeIfPresent(
                DictationSelectionEditProvider.self, forKey: .selectionEditProvider
            ) ?? defaults.selectionEditProvider
            openAICleanupModel = try container.decodeIfPresent(
                String.self, forKey: .openAICleanupModel
            ) ?? defaults.openAICleanupModel
            deepSeekCleanupModel = try container.decodeIfPresent(
                String.self, forKey: .deepSeekCleanupModel
            ) ?? defaults.deepSeekCleanupModel
            autoInsert = try container.decodeIfPresent(Bool.self, forKey: .autoInsert)
                ?? defaults.autoInsert
            // Decode the legacy value to preserve schema/type validation, but clipboard recovery is
            // now a non-optional loss-prevention invariant.
            _ = try container.decodeIfPresent(Bool.self, forKey: .copyOnFailure)
            copyOnFailure = true
            restoreClipboardAfterInsert = try container.decodeIfPresent(
                Bool.self, forKey: .restoreClipboardAfterInsert
            ) ?? defaults.restoreClipboardAfterInsert
            copyLastOnSideButtonDouble = try container.decodeIfPresent(
                Bool.self, forKey: .copyLastOnSideButtonDouble
            ) ?? defaults.copyLastOnSideButtonDouble
            feedbackSoundsEnabled = try container.decodeIfPresent(
                Bool.self, forKey: .feedbackSoundsEnabled
            ) ?? defaults.feedbackSoundsEnabled
            feedbackSoundVolume = try container.decodeIfPresent(
                Double.self, forKey: .feedbackSoundVolume
            ) ?? defaults.feedbackSoundVolume
            pipelineOverlayEnabled = try container.decodeIfPresent(
                Bool.self, forKey: .pipelineOverlayEnabled
            ) ?? defaults.pipelineOverlayEnabled
            maxRecordingSeconds = try container.decodeIfPresent(
                Double.self, forKey: .maxRecordingSeconds
            ) ?? defaults.maxRecordingSeconds
            // An older hand-authored config may have set a one-second maximum before the minimum
            // gate existed. Preserve its ability to load instead of introducing a migration error;
            // an explicitly authored minimum is still validated against the maximum below.
            minimumRecordingSeconds = try container.decodeIfPresent(
                Double.self, forKey: .minimumRecordingSeconds
            ) ?? min(defaults.minimumRecordingSeconds, maxRecordingSeconds)
            dictionary = try container.decodeIfPresent(
                [DictationTerm].self, forKey: .dictionary
            ) ?? defaults.dictionary
        }

        /// Select a global Voice mode and retire any per-Layer overrides from the next JSON save.
        /// Keeping the legacy outputMode synchronized makes downgrading to an older build behave as
        /// closely as possible for the two native routes.
        public mutating func selectMode(_ mode: DictationMode) {
            activeMode = mode
            if let nativeMode = mode.outputMode { outputMode = nativeMode }
            layerModes.removeAll()
        }

        /// Resolve the global side-button route. The layer argument remains source-compatible for
        /// callers and third-party integrations, but intentionally has no effect. `nil` means
        /// "do not claim it": RemoteInputHandler then runs the existing configured action without
        /// paying any native-dictation work on the physical press path.
        public func resolvedOutputMode(for layerID: String?) -> DictationOutputMode? {
            _ = layerID
            guard enabled else { return nil }
            return activeMode.outputMode
        }

        /// Keep both native transports warm even while External is selected. A mode switch is a
        /// control-plane event and the next side-button hold must not pay a DNS/TLS/WebSocket
        /// handshake. There are still only two sessions regardless of the number of Layers.
        public func outputModesToPrewarm(layerIDs: [String]) -> Set<DictationOutputMode> {
            _ = layerIDs
            guard enabled else { return [] }
            return Set(DictationOutputMode.allCases)
        }

        /// Freeze the selected global choice into a session-local settings value. A mode switch
        /// while somebody is speaking therefore cannot change that utterance halfway through.
        public func resolvedSettings(for layerID: String?) -> Self? {
            guard let mode = resolvedOutputMode(for: layerID) else { return nil }
            var copy = self
            copy.outputMode = mode
            return copy
        }
    }

    /// Decode-only compatibility with the short-lived `settings.layerHUD` dictionary schema.
    /// ConfigWriter emits the ordered `layers` form, so the next UI save upgrades old files.
    public struct LayerHUDStyle: Codable, Equatable {
        public var label: String?
        public var color: String?
        public var icon: String?
        public init(label: String? = nil, color: String? = nil, icon: String? = nil) {
            self.label = label
            self.color = color
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

    /// Add a mode and append it to the ordered layer cycle. The editor uses this instead of
    /// `addMode` for its Layer path so a newly-created layer is immediately selectable and
    /// cycleable. Invalid/reserved/duplicate ids and an 11th entry are safe no-ops.
    func addLayer(id: String, name: String? = nil, color: String? = nil,
                  icon: String? = nil,
                  inherits: String?) -> Config {
        guard id != "BASE", !id.isEmpty,
              id == id.trimmingCharacters(in: .whitespacesAndNewlines),
              !settings.layers.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame })
        else { return self }
        var copy = self
        if copy.settings.layers.isEmpty {
            copy.settings.layers = [LayerDefinition(id: "BASE", name: "Layer 1", color: "green")]
        }
        guard copy.settings.layers.count < 10 else { return self }
        if copy.modes[id] == nil {
            copy.modes[id] = Mode(inherits: inherits, bindings: [:])
        }
        copy.settings.layers.append(LayerDefinition(id: id, name: name, color: color,
                                                    icon: icon))
        return copy
    }

    /// Remove a mode, the appProfiles pointing at it, and any dangling `inherits` references to it
    /// (other modes that inherited it are re-parented to nil, so the result still loads). Refuses to
    /// remove the default mode — deleting it would leave the config with no valid default.
    func removeMode(_ name: String) -> Config {
        guard name != settings.defaultMode else { return self }
        var copy = self
        copy.modes.removeValue(forKey: name)
        copy.settings.layers.removeAll {
            $0.id.caseInsensitiveCompare(name) == .orderedSame && $0.id != "BASE"
        }
        copy.settings.dictation.layerModes.removeValue(forKey: name)
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
        case holdThreshold2, holdThreshold3, holdCancelGrace, appWheel, layers, layerHUD, icons
        case clickRiseThreshold, pressMoveMax
        case accelMin, accelMax, accelLowSpeed, accelHighSpeed, accelCurve
        case accelerationCurvesLinked
        case doubleTapWindow
        case spacesModeWindow
        case findCursorEnabled
        case interfaceLanguage, launchAtLoginEnabled
        case automaticUpdateChecksEnabled, automaticallyDownloadUpdatesEnabled
        case menuBarIconEnabled
        case statusWidgetEnabled, demoRemoteEnabled
        case layerHUDEnabled, holdHUDEnabled, dragIndicatorEnabled
        case showSetupWizardOnFirstLaunch
        case focusFollowsCursor
        case dictation
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
        holdCancelGrace = try c.decodeIfPresent(Double.self, forKey: .holdCancelGrace) ?? 1.0
        appWheel = try c.decodeIfPresent([String].self, forKey: .appWheel) ?? []
        if let ordered = try c.decodeIfPresent([Config.LayerDefinition].self, forKey: .layers) {
            layers = ordered
        } else if let legacy = try c.decodeIfPresent([String: Config.LayerHUDStyle].self,
                                                     forKey: .layerHUD) {
            layers = Self.migrateLegacyLayerHUD(legacy)
        } else {
            layers = []
        }
        icons = try c.decodeIfPresent([String: String].self, forKey: .icons) ?? [:]
        clickRiseThreshold = try c.decodeIfPresent(Double.self, forKey: .clickRiseThreshold) ?? 0.1
        pressMoveMax = try c.decodeIfPresent(Double.self, forKey: .pressMoveMax) ?? 0.025
        accelMin = try c.decodeIfPresent(Double.self, forKey: .accelMin) ?? 0.4
        accelMax = try c.decodeIfPresent(Double.self, forKey: .accelMax) ?? 2.6
        accelLowSpeed = try c.decodeIfPresent(Double.self, forKey: .accelLowSpeed) ?? 0.008
        accelHighSpeed = try c.decodeIfPresent(Double.self, forKey: .accelHighSpeed) ?? 0.06
        accelCurve = try c.decodeIfPresent(Double.self, forKey: .accelCurve) ?? 1.0
        accelerationCurvesLinked = try c.decodeIfPresent(Bool.self,
                                                         forKey: .accelerationCurvesLinked) ?? false
        doubleTapWindow = try c.decodeIfPresent(Double.self, forKey: .doubleTapWindow) ?? 0.3
        spacesModeWindow = try c.decodeIfPresent(Double.self, forKey: .spacesModeWindow) ?? 5.0
        findCursorEnabled = try c.decodeIfPresent(Bool.self, forKey: .findCursorEnabled) ?? true
        interfaceLanguage = try c.decodeIfPresent(String.self, forKey: .interfaceLanguage)
        launchAtLoginEnabled = try c.decodeIfPresent(Bool.self, forKey: .launchAtLoginEnabled)
        automaticUpdateChecksEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .automaticUpdateChecksEnabled
        ) ?? true
        automaticallyDownloadUpdatesEnabled = try c.decodeIfPresent(
            Bool.self, forKey: .automaticallyDownloadUpdatesEnabled
        ) ?? true
        menuBarIconEnabled = try c.decodeIfPresent(Bool.self, forKey: .menuBarIconEnabled) ?? true
        statusWidgetEnabled = try c.decodeIfPresent(Bool.self, forKey: .statusWidgetEnabled) ?? true
        demoRemoteEnabled = try c.decodeIfPresent(Bool.self, forKey: .demoRemoteEnabled) ?? false
        layerHUDEnabled = try c.decodeIfPresent(Bool.self, forKey: .layerHUDEnabled) ?? true
        holdHUDEnabled = try c.decodeIfPresent(Bool.self, forKey: .holdHUDEnabled) ?? true
        dragIndicatorEnabled = try c.decodeIfPresent(Bool.self, forKey: .dragIndicatorEnabled) ?? true
        showSetupWizardOnFirstLaunch = try c.decodeIfPresent(
            Bool.self, forKey: .showSetupWizardOnFirstLaunch
        ) ?? true
        focusFollowsCursor = try c.decodeIfPresent(Bool.self, forKey: .focusFollowsCursor) ?? false
        dictation = try c.decodeIfPresent(Config.DictationSettings.self, forKey: .dictation)
            ?? Config.DictationSettings()
    }

    /// Dictionaries have no user-authored order, so legacy entries receive the only deterministic
    /// ordering their ids imply: BASE, numbered L layers, then any custom ids alphabetically.
    private static func migrateLegacyLayerHUD(
        _ legacy: [String: Config.LayerHUDStyle]
    ) -> [Config.LayerDefinition] {
        func rank(_ raw: String) -> (group: Int, number: Int) {
            let value = raw.uppercased()
            if value == "BASE" { return (0, 0) }
            if value.hasPrefix("L"), let number = Int(value.dropFirst()), number > 0 {
                return (1, number)
            }
            return (2, 0)
        }
        let ids = legacy.keys.sorted { lhs, rhs in
            let a = rank(lhs), b = rank(rhs)
            if a.group != b.group { return a.group < b.group }
            if a.number != b.number { return a.number < b.number }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        var migrated = ids.map { rawID in
            let style = legacy[rawID]!
            let id = rawID.caseInsensitiveCompare("BASE") == .orderedSame ? "BASE" : rawID
            return Config.LayerDefinition(id: id, name: style.label, color: style.color,
                                          icon: style.icon)
        }
        if !migrated.isEmpty, migrated[0].id != "BASE" {
            migrated.insert(Config.LayerDefinition(id: "BASE"), at: 0)
        }
        return migrated
    }
}

extension Config.Mode: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var inherits: String? = nil
        var bindings: [String: Action] = [:]
        var presentation: [String: Config.Presentation] = [:]
        var holdDelay: [String: Double] = [:]
        for key in c.allKeys {
            if key.stringValue == "inherits" {
                inherits = try c.decode(String.self, forKey: key)
            } else {
                bindings[key.stringValue] = try c.decode(Action.self, forKey: key)
                // `label` / `icon` live alongside `action` in the same object, so they are read
                // from the same container; absent keys simply leave no entry here.
                let p = try c.decode(Config.Presentation.self, forKey: key)
                if p.label != nil || p.icon != nil { presentation[key.stringValue] = p }
                if let after = try c.decode(HoldDelayField.self, forKey: key).after {
                    holdDelay[key.stringValue] = after
                }
            }
        }
        self.inherits = inherits
        self.bindings = bindings
        self.presentation = presentation
        self.holdDelay = holdDelay
    }
}

/// Reads just the `after` field out of a binding object, alongside `action` and `label`/`icon`.
private struct HoldDelayField: Decodable {
    let after: Double?
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
        try c.encode(holdCancelGrace, forKey: .holdCancelGrace)
        try c.encode(appWheel, forKey: .appWheel)
        try c.encode(layers, forKey: .layers)
        try c.encode(icons, forKey: .icons)
        try c.encode(clickRiseThreshold, forKey: .clickRiseThreshold)
        try c.encode(pressMoveMax, forKey: .pressMoveMax)
        try c.encode(accelMin, forKey: .accelMin)
        try c.encode(accelMax, forKey: .accelMax)
        try c.encode(accelLowSpeed, forKey: .accelLowSpeed)
        try c.encode(accelHighSpeed, forKey: .accelHighSpeed)
        try c.encode(accelCurve, forKey: .accelCurve)
        try c.encode(accelerationCurvesLinked, forKey: .accelerationCurvesLinked)
        try c.encode(doubleTapWindow, forKey: .doubleTapWindow)
        try c.encode(spacesModeWindow, forKey: .spacesModeWindow)
        try c.encode(findCursorEnabled, forKey: .findCursorEnabled)
        try c.encodeIfPresent(interfaceLanguage, forKey: .interfaceLanguage)
        try c.encodeIfPresent(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try c.encode(automaticUpdateChecksEnabled, forKey: .automaticUpdateChecksEnabled)
        try c.encode(automaticallyDownloadUpdatesEnabled,
                     forKey: .automaticallyDownloadUpdatesEnabled)
        try c.encode(menuBarIconEnabled, forKey: .menuBarIconEnabled)
        try c.encode(statusWidgetEnabled, forKey: .statusWidgetEnabled)
        try c.encode(demoRemoteEnabled, forKey: .demoRemoteEnabled)
        try c.encode(layerHUDEnabled, forKey: .layerHUDEnabled)
        try c.encode(holdHUDEnabled, forKey: .holdHUDEnabled)
        try c.encode(dragIndicatorEnabled, forKey: .dragIndicatorEnabled)
        try c.encode(showSetupWizardOnFirstLaunch, forKey: .showSetupWizardOnFirstLaunch)
        try c.encode(focusFollowsCursor, forKey: .focusFollowsCursor)
        try c.encode(dictation, forKey: .dictation)
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
            let p = presentation[key]
            let after = holdDelay[key]
            if p != nil || after != nil {
                try c.encode(BindingWithExtras(action: action,
                                               presentation: p ?? Config.Presentation(),
                                               after: after), forKey: dk)
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

/// Writes `action` and its non-action fields FLAT into one object, so a round-tripped config keeps
/// `label`/`icon`/`after` sitting next to `action` exactly as a human would write them.
private struct BindingWithExtras: Encodable {
    let action: Action
    let presentation: Config.Presentation
    let after: Double?

    private enum K: String, CodingKey { case label, icon, after }

    func encode(to encoder: Encoder) throws {
        try action.encode(to: encoder)          // emits {"action": …, params…}
        var c = encoder.container(keyedBy: K.self)
        try c.encodeIfPresent(presentation.label, forKey: .label)
        try c.encodeIfPresent(presentation.icon, forKey: .icon)
        try c.encodeIfPresent(after, forKey: .after)
    }
}
