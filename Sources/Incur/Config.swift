/// Config file loading for the incur framework.
///
/// Supports loading JSON config files that provide default option values
/// for commands. The config tree mirrors the command tree structure:
///
/// ```json
/// {
///   "commands": {
///     "deploy": {
///       "options": {
///         "environment": "staging"
///       }
///     }
///   }
/// }
/// ```
///
/// Ported from `config.rs`.

import Foundation

/// Loads config defaults from a JSON file at the given path.
///
/// Reads the file, parses it as JSON, and returns the top-level value.
/// Returns an error if the file cannot be read, contains invalid JSON,
/// or the top-level value is not an object.
public func loadConfig(path: String) throws -> JSONValue {
    let url = URL(fileURLWithPath: path)
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch {
        throw ConfigError(message: "Failed to read config file '\(path)': \(error.localizedDescription)")
    }

    guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else {
        throw ConfigError(message: "Invalid JSON config file '\(path)'")
    }

    guard case .object = parsed else {
        throw ConfigError(message: "Invalid config file: expected a top-level object in '\(path)'")
    }

    return parsed
}

/// Resolves the config file path from an explicit flag value or default search locations.
///
/// If `explicit` is non-nil, expands `~` to the home directory and resolves
/// relative to the current working directory.
///
/// If `explicit` is nil, searches `files` in order and returns the first
/// existing file path.
///
/// Returns `nil` if no config file is found.
public func resolveConfigPath(explicit: String?, files: [String]) -> String? {
    if let explicit {
        return resolvePath(explicit)
    }

    for file in files {
        let resolved = resolvePath(file)
        if FileManager.default.fileExists(atPath: resolved) {
            return resolved
        }
    }

    return nil
}

/// Extracts command-specific option defaults from a parsed config tree.
///
/// Walks the nested config structure following the command path segments.
/// For a command path like `"users list"`, looks for:
///
/// ```json
/// { "commands": { "users": { "commands": { "list": { "options": { ... } } } } } }
/// ```
///
/// If the command path equals the CLI name (root command), looks for `options`
/// at the top level.
///
/// Returns `nil` if the command section or its `options` key is not found,
/// or if the options object is empty.
public func extractCommandSection(config: JSONValue, cliName: String, commandPath: String) throws -> OrderedMap? {
    // If the command path is the CLI name itself (root command),
    // look for options at the top level.
    let segments: [String]
    if commandPath == cliName {
        segments = []
    } else {
        segments = commandPath.split(separator: " ").map(String.init)
    }

    var node = config

    for seg in segments {
        guard case .object(let obj) = node else {
            throw ConfigError(message: "Invalid config section for '\(commandPath)': expected an object")
        }

        guard let commands = obj["commands"] else {
            return nil
        }

        guard case .object(let commandsObj) = commands else {
            throw ConfigError(message: "Invalid config 'commands' for '\(commandPath)': expected an object")
        }

        guard let next = commandsObj[seg] else {
            return nil
        }

        node = next
    }

    guard case .object(let obj) = node else {
        throw ConfigError(message: "Invalid config section for '\(commandPath)': expected an object")
    }

    guard let options = obj["options"] else {
        return nil
    }

    guard case .object(let optionsMap) = options else {
        throw ConfigError(message: "Invalid config 'options' for '\(commandPath)': expected an object")
    }

    if optionsMap.isEmpty {
        return nil
    }

    return optionsMap
}

/// Resolves a file path, expanding `~` to the user's home directory.
private func resolvePath(_ filePath: String) -> String {
    if filePath.hasPrefix("~/") || filePath == "~" {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + String(filePath.dropFirst(1))
    }

    // If absolute, return as-is
    if filePath.hasPrefix("/") {
        return filePath
    }

    // Resolve relative to current working directory
    let cwd = FileManager.default.currentDirectoryPath
    return (cwd as NSString).appendingPathComponent(filePath)
}

/// Error thrown when config loading fails.
public struct ConfigError: Error, Sendable, LocalizedError {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
