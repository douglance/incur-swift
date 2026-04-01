/// MCP server registration with AI coding agents.
///
/// Ported from `sync_mcp.rs`. Registers the CLI binary as an MCP (Model
/// Context Protocol) server by writing agent-specific configuration files.

import Foundation

// MARK: - Types

/// Options for `registerMcp`.
public struct RegisterOptions: Sendable {
    /// Target specific agents (e.g. "claude-code", "cursor").
    /// Empty means register with all detected agents.
    public let agents: [String]?
    /// Override the command agents will run.
    /// Defaults to `<exe_path> --mcp`.
    public let command: String?
    /// Install globally. Defaults to `true`.
    public let global: Bool

    public init(agents: [String]? = nil, command: String? = nil, global: Bool = true) {
        self.agents = agents
        self.command = command
        self.global = global
    }
}

/// Result of a register operation.
public struct RegisterResult: Sendable {
    /// Agents the server was registered with.
    public let agents: [String]
    /// The command that was registered.
    public let command: String

    public init(agents: [String] = [], command: String = "") {
        self.agents = agents
        self.command = command
    }
}

// MARK: - Public API

/// Registers the CLI as an MCP server with detected coding agents.
///
/// For Swift binaries, the command defaults to the current executable path
/// with `--mcp` appended. Currently supports direct registration with Amp
/// (via its `settings.json`) and Claude Code (via `.claude.json`).
public func registerMcp(
    name: String,
    options: RegisterOptions
) async throws -> RegisterResult {
    let command: String
    if let cmd = options.command {
        command = cmd
    } else {
        let exe = CommandLine.arguments.first ?? name
        command = "\(exe) --mcp"
    }

    let targetAgents = options.agents ?? []
    var registeredAgents: [String] = []

    // Register with Amp directly (writes to ~/.config/amp/settings.json)
    if targetAgents.isEmpty || targetAgents.contains("amp") {
        if registerAmp(name: name, command: command) {
            registeredAgents.append("Amp")
        }
    }

    // Register with Claude Code (writes to ~/.claude.json or project .claude.json)
    if targetAgents.isEmpty
        || targetAgents.contains("claude-code")
        || targetAgents.contains("claude") {
        if registerClaudeCode(name: name, command: command, global: options.global) {
            registeredAgents.append("Claude Code")
        }
    }

    return RegisterResult(agents: registeredAgents, command: command)
}

// MARK: - Agent-Specific Registration

/// Registers an MCP server in Amp's `settings.json`.
public func registerAmp(name: String, command: String) -> Bool {
    let configPath = ampConfigPath()
    let fm = FileManager.default

    var config: [String: Any]
    if fm.fileExists(atPath: configPath.path) {
        guard let data = try? Data(contentsOf: configPath),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        config = parsed
    } else {
        config = [:]
    }

    let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
    guard let cmd = parts.first else { return false }
    let args: [String]
    if parts.count > 1 {
        args = parts[1].split(separator: " ").map(String.init)
    } else {
        args = []
    }

    var servers = (config["amp.mcpServers"] as? [String: Any]) ?? [:]
    servers[name] = [
        "command": cmd,
        "args": args,
    ] as [String: Any]
    config["amp.mcpServers"] = servers

    // Write back
    let parent = configPath.deletingLastPathComponent()
    if !fm.fileExists(atPath: parent.path) {
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    guard let jsonData = try? JSONSerialization.data(
        withJSONObject: config,
        options: [.prettyPrinted, .sortedKeys]
    ) else { return false }

    guard var jsonString = String(data: jsonData, encoding: .utf8) else { return false }
    jsonString += "\n"

    return (try? jsonString.write(to: configPath, atomically: true, encoding: .utf8)) != nil
}

/// Registers an MCP server with Claude Code's configuration.
public func registerClaudeCode(name: String, command: String, global: Bool) -> Bool {
    let configPath: URL
    if global {
        configPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    } else {
        configPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".claude.json")
    }

    let fm = FileManager.default
    var config: [String: Any]
    if fm.fileExists(atPath: configPath.path) {
        if let data = try? Data(contentsOf: configPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        } else {
            config = [:]
        }
    } else {
        config = [:]
    }

    let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
    guard let cmd = parts.first else { return false }
    let args: [String]
    if parts.count > 1 {
        args = parts[1].split(separator: " ").map(String.init)
    } else {
        args = []
    }

    var servers = (config["mcpServers"] as? [String: Any]) ?? [:]
    servers[name] = [
        "command": cmd,
        "args": args,
    ] as [String: Any]
    config["mcpServers"] = servers

    let parent = configPath.deletingLastPathComponent()
    if !fm.fileExists(atPath: parent.path) {
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    guard let jsonData = try? JSONSerialization.data(
        withJSONObject: config,
        options: [.prettyPrinted, .sortedKeys]
    ) else { return false }

    guard var jsonString = String(data: jsonData, encoding: .utf8) else { return false }
    jsonString += "\n"

    return (try? jsonString.write(to: configPath, atomically: true, encoding: .utf8)) != nil
}

// MARK: - Path Helpers

/// Returns the path to Amp's settings.json.
public func ampConfigPath() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".config/amp/settings.json")
}
