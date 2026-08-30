import Foundation

public enum ConfigError: Error, Equatable {
    case parse(String)
    case validation(String)
}

public enum ConfigLoader {
    public static func load(_ text: String) throws -> Config {
        let data = Data(JSONC.strip(text).utf8)
        let config: Config
        do {
            config = try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.parse(String(describing: error))
        }
        try validate(config)
        return config
    }

    static func validate(_ c: Config) throws {
        guard c.modes[c.settings.defaultMode] != nil else {
            throw ConfigError.validation("defaultMode '\(c.settings.defaultMode)' not in modes")
        }
        if let language = c.settings.interfaceLanguage, !["en", "zh"].contains(language) {
            throw ConfigError.validation(
                "settings.interfaceLanguage must be 'en' or 'zh' (got '\(language)')"
            )
        }
        let dictation = c.settings.dictation
        if dictation.enabled {
            guard !dictation.finalModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.validation("settings.dictation.finalModel must not be empty")
            }
            guard !dictation.streamingModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ConfigError.validation("settings.dictation.streamingModel must not be empty")
            }
            switch dictation.cleanupProvider {
            case .none:
                break
            case .openAI:
                guard !dictation.openAICleanupModel
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigError.validation(
                        "settings.dictation.openAICleanupModel must not be empty"
                    )
                }
            case .deepSeek:
                guard !dictation.deepSeekCleanupModel
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigError.validation(
                        "settings.dictation.deepSeekCleanupModel must not be empty"
                    )
                }
            }
            if dictation.selectionEditingEnabled {
                switch dictation.selectionEditProvider {
                case .openAI:
                    guard !dictation.openAICleanupModel
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ConfigError.validation(
                            "settings.dictation.openAICleanupModel must not be empty"
                        )
                    }
                case .deepSeek:
                    guard !dictation.deepSeekCleanupModel
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw ConfigError.validation(
                            "settings.dictation.deepSeekCleanupModel must not be empty"
                        )
                    }
                }
            }
        }
        guard (1...600).contains(dictation.maxRecordingSeconds) else {
            throw ConfigError.validation(
                "settings.dictation.maxRecordingSeconds must be between 1 and 600"
            )
        }
        guard dictation.minimumRecordingSeconds.isFinite,
              (0...30).contains(dictation.minimumRecordingSeconds) else {
            throw ConfigError.validation(
                "settings.dictation.minimumRecordingSeconds must be between 0 and 30"
            )
        }
        guard dictation.minimumRecordingSeconds <= dictation.maxRecordingSeconds else {
            throw ConfigError.validation(
                "settings.dictation.minimumRecordingSeconds must not exceed maxRecordingSeconds"
            )
        }
        guard dictation.feedbackSoundVolume.isFinite,
              (0...1).contains(dictation.feedbackSoundVolume) else {
            throw ConfigError.validation(
                "settings.dictation.feedbackSoundVolume must be between 0 and 1"
            )
        }
        guard dictation.dictionary.count <= 500 else {
            throw ConfigError.validation("settings.dictation.dictionary supports at most 500 terms")
        }
        var canonicalTerms = Set<String>()
        for entry in dictation.dictionary {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, term == entry.term else {
                throw ConfigError.validation(
                    "settings.dictation.dictionary contains an empty or padded term"
                )
            }
            guard !term.contains("\n"), !term.contains("\r") else {
                throw ConfigError.validation(
                    "settings.dictation.dictionary terms cannot contain newlines"
                )
            }
            guard canonicalTerms.insert(term.lowercased()).inserted else {
                throw ConfigError.validation(
                    "settings.dictation.dictionary contains duplicate term '\(term)'"
                )
            }
        }
        let layers = c.settings.layers
        let usesLayerCycle = c.modes.values.contains { mode in
            mode.bindings.values.contains { $0 == .layerCycle }
        }
        guard layers.count <= 10 else {
            throw ConfigError.validation("settings.layers supports at most 10 layers")
        }
        if !layers.isEmpty {
            guard layers[0].id == "BASE" else {
                throw ConfigError.validation("settings.layers must start with id 'BASE'")
            }
            var seen = Set<String>()
            for layer in layers {
                let id = layer.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, id == layer.id else {
                    throw ConfigError.validation("settings.layers contains an empty or padded id")
                }
                let canonical = id.lowercased()
                guard seen.insert(canonical).inserted else {
                    throw ConfigError.validation("settings.layers contains duplicate id '\(id)'")
                }
                if usesLayerCycle, id != "BASE", c.modes[id] == nil {
                    throw ConfigError.validation("settings.layers id '\(id)' is not in modes")
                }
                if let icon = layer.icon {
                    guard !icon.isEmpty, icon == icon.trimmingCharacters(in: .whitespacesAndNewlines),
                          icon.count <= 128 else {
                        throw ConfigError.validation(
                            "settings.layers['\(id)'].icon must be a non-empty SF Symbol name"
                        )
                    }
                }
            }
        }
        for (key, icon) in c.settings.icons {
            guard !key.isEmpty, key == key.trimmingCharacters(in: .whitespacesAndNewlines),
                  key.count <= 128, !icon.isEmpty,
                  icon == icon.trimmingCharacters(in: .whitespacesAndNewlines),
                  icon.count <= 128 else {
                throw ConfigError.validation(
                    "settings.icons keys and values must be non-empty, unpadded names"
                )
            }
        }
        for (app, mode) in c.appProfiles where c.modes[mode] == nil {
            throw ConfigError.validation("appProfiles['\(app)'] -> unknown mode '\(mode)'")
        }
        for (name, mode) in c.modes {
            var visited: Set<String> = [name]
            var cursor = mode.inherits
            while let m = cursor {
                guard c.modes[m] != nil else {
                    throw ConfigError.validation("mode '\(name)' inherits unknown '\(m)'")
                }
                if visited.contains(m) {
                    throw ConfigError.validation("inherits cycle involving '\(m)'")
                }
                visited.insert(m)
                cursor = c.modes[m]?.inherits
            }
        }
    }
}
