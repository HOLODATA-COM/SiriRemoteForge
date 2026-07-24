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
