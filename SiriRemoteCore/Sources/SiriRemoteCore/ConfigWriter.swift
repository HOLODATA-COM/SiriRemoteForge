import Foundation

/// Serializes an in-memory `Config` back to pretty-printed JSON for `~/.config/siriremote/config.jsonc`.
/// The inverse of `ConfigLoader.load`: `ConfigLoader.load(try ConfigWriter.serialize(c)) == c` for
/// any `c`.
///
/// Comments are NOT preserved — once the config is edited through the in-app editor the file is
/// machine-managed. The output is strict JSON (a subset of JSONC), so `JSONC.strip` re-parses it
/// unchanged. The file IO (atomic write to disk) lives in the app target (`ConfigStore.save`); this
/// type is the pure, testable serialization step.
public enum ConfigWriter {
    /// A shared encoder tuned for a clean, stable, human-diffable config file:
    /// `.prettyPrinted` (readable), `.sortedKeys` (deterministic output → tidy diffs / no churn),
    /// `.withoutEscapingSlashes` (URLs and paths in `launch`/`shell` stay legible).
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Encode `config` to JSON bytes (no trailing newline).
    public static func data(_ config: Config) throws -> Data {
        try encoder().encode(config)
    }

    /// Encode `config` to a pretty-printed JSON string, ready to write to `config.jsonc`.
    public static func serialize(_ config: Config) throws -> String {
        String(decoding: try data(config), as: UTF8.self)
    }
}
