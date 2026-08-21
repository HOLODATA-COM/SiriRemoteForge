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
