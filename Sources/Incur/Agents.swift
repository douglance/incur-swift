/// Agent configuration and skill installation for AI coding agents.
///
/// Ported from `agents.rs`. Defines 21 agent configurations and
/// provides install/remove/detect operations that manage skill files across
/// the canonical `.agents/skills/` directory and agent-specific locations.

import Foundation

// MARK: - Types

/// Configuration for a single AI coding agent.
public struct Agent: Sendable {
    /// Display name (e.g. "Claude Code").
    public let name: String
    /// Absolute path to the global skills directory.
    public let globalSkillsDir: URL
    /// Project-relative skills directory path (e.g. ".claude/skills").
    public let projectSkillsDir: String
    /// Whether this agent uses the canonical `.agents/skills` path.
    public let universal: Bool
    /// Detection function: returns true if the agent is installed.
    public let detect: @Sendable () -> Bool

    public init(
        name: String,
        globalSkillsDir: URL,
        projectSkillsDir: String,
        universal: Bool,
        detect: @escaping @Sendable () -> Bool
    ) {
        self.name = name
        self.globalSkillsDir = globalSkillsDir
        self.projectSkillsDir = projectSkillsDir
        self.universal = universal
        self.detect = detect
    }
}

/// How a skill was installed for a non-universal agent.
public enum InstallMode: Sendable, Equatable {
    case symlink
    case copy
}

/// Details about a single agent's install for a skill.
public struct AgentInstall: Sendable {
    /// Agent display name.
    public let agent: String
    /// Installed path.
    public let path: URL
    /// Whether it was symlinked or copied.
    public let mode: InstallMode

    public init(agent: String, path: URL, mode: InstallMode) {
        self.agent = agent
        self.path = path
        self.mode = mode
    }
}

/// Result of an install operation.
public struct InstallResult: Sendable {
    /// Canonical install paths.
    public let paths: [URL]
    /// Per-agent install details (non-universal agents only).
    public let agents: [AgentInstall]

    public init(paths: [URL] = [], agents: [AgentInstall] = []) {
        self.paths = paths
        self.agents = agents
    }
}

/// Options for `installSkills`.
public struct InstallOptions: Sendable {
    /// Override detected agents (defaults to auto-detection).
    public let agents: [Agent]?
    /// Working directory for project-local installs. Defaults to current dir.
    public let cwd: URL?
    /// Install globally (`true`) or project-local (`false`). Defaults to `true`.
    public let global: Bool

    public init(agents: [Agent]? = nil, cwd: URL? = nil, global: Bool = true) {
        self.agents = agents
        self.cwd = cwd
        self.global = global
    }
}

/// Options for `removeSkill`.
public struct RemoveOptions: Sendable {
    /// Remove globally. Defaults to `true`.
    public let global: Bool
    /// Working directory for project-local removes.
    public let cwd: URL?

    public init(global: Bool = true, cwd: URL? = nil) {
        self.global = global
        self.cwd = cwd
    }
}

// MARK: - Environment Helpers

private func homeDir() -> URL {
    URL(fileURLWithPath: NSHomeDirectory())
}

private func configHome() -> URL {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
       !xdg.isEmpty {
        return URL(fileURLWithPath: xdg)
    }
    return homeDir().appendingPathComponent(".config")
}

private func claudeHome() -> URL {
    if let dir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
        .trimmingCharacters(in: .whitespaces),
       !dir.isEmpty {
        return URL(fileURLWithPath: dir)
    }
    return homeDir().appendingPathComponent(".claude")
}

private func codexHome() -> URL {
    if let dir = ProcessInfo.processInfo.environment["CODEX_HOME"]?
        .trimmingCharacters(in: .whitespaces),
       !dir.isEmpty {
        return URL(fileURLWithPath: dir)
    }
    return homeDir().appendingPathComponent(".codex")
}

// MARK: - Agent Definitions

/// Returns all known agent definitions (21 total).
public func allAgents() -> [Agent] {
    let home = homeDir()
    let config = configHome()
    let claude = claudeHome()
    let codex = codexHome()

    return [
        // ---- Universal agents (projectSkillsDir = ".agents/skills") ----
        Agent(
            name: "Amp",
            globalSkillsDir: config.appendingPathComponent("agents/skills"),
            projectSkillsDir: ".agents/skills",
            universal: true,
            detect: { FileManager.default.fileExists(atPath: configHome().appendingPathComponent("amp").path) }
        ),
        Agent(
            name: "Cline",
            globalSkillsDir: home.appendingPathComponent(".agents/skills"),
            projectSkillsDir: ".agents/skills",
            universal: true,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".cline").path) }
        ),
        Agent(
            name: "Codex",
            globalSkillsDir: codex.appendingPathComponent("skills"),
            projectSkillsDir: ".agents/skills",
            universal: true,
            detect: { FileManager.default.fileExists(atPath: codexHome().path) }
        ),
        Agent(
            name: "Cursor",
            globalSkillsDir: home.appendingPathComponent(".cursor/skills"),
            projectSkillsDir: ".agents/skills",
            universal: true,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".cursor").path) }
        ),
        Agent(
            name: "Gemini CLI",
            globalSkillsDir: home.appendingPathComponent(".gemini/skills"),
            projectSkillsDir: ".agents/skills",
            universal: true,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".gemini").path) }
        ),
        Agent(
            name: "GitHub Copilot",
            globalSkillsDir: home.appendingPathComponent(".copilot/skills"),
            projectSkillsDir: ".agents/skills",
            universal: true,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".copilot").path) }
        ),
        Agent(
            name: "Kimi CLI",
            globalSkillsDir: config.appendingPathComponent("agents/skills"),
            projectSkillsDir: ".agents/skills",
            universal: true,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".kimi").path) }
        ),
        Agent(
            name: "OpenCode",
            globalSkillsDir: config.appendingPathComponent("opencode/skills"),
            projectSkillsDir: ".agents/skills",
            universal: true,
            detect: { FileManager.default.fileExists(atPath: configHome().appendingPathComponent("opencode").path) }
        ),
        // ---- Non-universal agents ----
        Agent(
            name: "Claude Code",
            globalSkillsDir: claude.appendingPathComponent("skills"),
            projectSkillsDir: ".claude/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: claudeHome().path) }
        ),
        Agent(
            name: "Windsurf",
            globalSkillsDir: home.appendingPathComponent(".codeium/windsurf/skills"),
            projectSkillsDir: ".windsurf/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".codeium/windsurf").path) }
        ),
        Agent(
            name: "Continue",
            globalSkillsDir: home.appendingPathComponent(".continue/skills"),
            projectSkillsDir: ".continue/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".continue").path) }
        ),
        Agent(
            name: "Roo",
            globalSkillsDir: home.appendingPathComponent(".roo/skills"),
            projectSkillsDir: ".roo/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".roo").path) }
        ),
        Agent(
            name: "Kilo",
            globalSkillsDir: home.appendingPathComponent(".kilocode/skills"),
            projectSkillsDir: ".kilocode/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".kilocode").path) }
        ),
        Agent(
            name: "Goose",
            globalSkillsDir: config.appendingPathComponent("goose/skills"),
            projectSkillsDir: ".goose/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: configHome().appendingPathComponent("goose").path) }
        ),
        Agent(
            name: "Augment",
            globalSkillsDir: home.appendingPathComponent(".augment/skills"),
            projectSkillsDir: ".augment/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".augment").path) }
        ),
        Agent(
            name: "Trae",
            globalSkillsDir: home.appendingPathComponent(".trae/skills"),
            projectSkillsDir: ".trae/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".trae").path) }
        ),
        Agent(
            name: "Junie",
            globalSkillsDir: home.appendingPathComponent(".junie/skills"),
            projectSkillsDir: ".junie/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".junie").path) }
        ),
        Agent(
            name: "Crush",
            globalSkillsDir: config.appendingPathComponent("crush/skills"),
            projectSkillsDir: ".crush/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: configHome().appendingPathComponent("crush").path) }
        ),
        Agent(
            name: "Kiro CLI",
            globalSkillsDir: home.appendingPathComponent(".kiro/skills"),
            projectSkillsDir: ".kiro/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".kiro").path) }
        ),
        Agent(
            name: "Qwen Code",
            globalSkillsDir: home.appendingPathComponent(".qwen/skills"),
            projectSkillsDir: ".qwen/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".qwen").path) }
        ),
        Agent(
            name: "OpenHands",
            globalSkillsDir: home.appendingPathComponent(".openhands/skills"),
            projectSkillsDir: ".openhands/skills",
            universal: false,
            detect: { FileManager.default.fileExists(atPath: homeDir().appendingPathComponent(".openhands").path) }
        ),
    ]
}

/// Returns only agents that are detected as installed on this system.
public func detectAgents() -> [Agent] {
    allAgents().filter { $0.detect() }
}

// MARK: - Skill Discovery

/// A discovered skill directory.
private struct DiscoveredSkill {
    /// Sanitized skill name.
    let name: String
    /// Absolute path to the skill directory.
    let dir: URL
    /// Whether this is a root-level SKILL.md (not in a subdirectory).
    let root: Bool
}

/// Recursively discovers skill directories (those containing a `SKILL.md`).
///
/// Returns an array of `(name, path)` tuples for each discovered skill.
public func discoverSkills(rootDir: URL) throws -> [(name: String, path: URL)] {
    var results: [DiscoveredSkill] = []
    visitSkills(dir: rootDir, results: &results)

    // Root-level SKILL.md
    let rootSkillPath = rootDir.appendingPathComponent("SKILL.md")
    if FileManager.default.fileExists(atPath: rootSkillPath.path) {
        if let content = try? String(contentsOf: rootSkillPath, encoding: .utf8) {
            let name = sanitizeName(extractSkillName(content: content) ?? "skill")
            if !results.contains(where: { $0.name == name }) {
                results.append(DiscoveredSkill(name: name, dir: rootDir, root: true))
            }
        }
    }

    return results.map { ($0.name, $0.dir) }
}

private func visitSkills(dir: URL, results: inout [DiscoveredSkill]) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
        at: dir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else { return }

    for entry in entries {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
            continue
        }

        let skillPath = entry.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: skillPath.path) {
            if let content = try? String(contentsOf: skillPath, encoding: .utf8) {
                let entryName = entry.lastPathComponent
                let name = sanitizeName(extractSkillName(content: content) ?? entryName)
                results.append(DiscoveredSkill(name: name, dir: entry, root: false))
            }
        }
        visitSkills(dir: entry, results: &results)
    }
}

// MARK: - Install

/// Installs skill directories to the canonical location and creates symlinks
/// for detected non-universal agents.
///
/// Copies each discovered skill (directory containing `SKILL.md`) into
/// `<base>/.agents/skills/<name>/`, then symlinks from each non-universal
/// agent's skill directory. Falls back to copy if symlink creation fails.
public func installSkills(sourceDir: URL, options: InstallOptions) throws -> InstallResult {
    let isGlobal = options.global
    let cwd = options.cwd ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let base = isGlobal ? homeDir() : cwd
    let canonicalBase = base.appendingPathComponent(".agents/skills")
    let detected = options.agents ?? detectAgents()

    var paths: [URL] = []
    var agents: [AgentInstall] = []

    let discovered = discoverSkillsInternal(rootDir: sourceDir)

    for skill in discovered {
        let canonicalDir = canonicalBase.appendingPathComponent(skill.name)

        // Copy to canonical location
        rmForce(canonicalDir)
        try? FileManager.default.createDirectory(at: canonicalDir, withIntermediateDirectories: true)

        if skill.root {
            // Single SKILL.md at root — just copy the file
            let src = skill.dir.appendingPathComponent("SKILL.md")
            let dst = canonicalDir.appendingPathComponent("SKILL.md")
            try? FileManager.default.copyItem(at: src, to: dst)
        } else {
            // Copy entire directory
            copyDirRecursive(src: skill.dir, dst: canonicalDir)
        }
        paths.append(canonicalDir)

        // Create symlinks for non-universal agents
        for agent in detected {
            if agent.universal { continue }

            let agentSkillsDir = isGlobal
                ? agent.globalSkillsDir
                : cwd.appendingPathComponent(agent.projectSkillsDir)
            let agentDir = agentSkillsDir.appendingPathComponent(skill.name)

            // Skip if agent dir resolves to canonical (no symlink needed)
            if agentDir.standardizedFileURL == canonicalDir.standardizedFileURL {
                continue
            }

            // Try symlink first
            do {
                rmForce(agentDir)
                let parent = agentDir.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

                let resolvedParent = resolveParent(parent)
                let resolvedTarget = resolveParent(canonicalDir)
                let relPath = diffPaths(target: resolvedTarget, base: resolvedParent)

                try FileManager.default.createSymbolicLink(
                    atPath: agentDir.path,
                    withDestinationPath: relPath
                )
                agents.append(AgentInstall(agent: agent.name, path: agentDir, mode: .symlink))
            } catch {
                // Fallback to copy
                rmForce(agentDir)
                copyDirRecursive(src: canonicalDir, dst: agentDir)
                agents.append(AgentInstall(agent: agent.name, path: agentDir, mode: .copy))
            }
        }
    }

    return InstallResult(paths: paths, agents: agents)
}

/// Internal discovery that returns DiscoveredSkill structs.
private func discoverSkillsInternal(rootDir: URL) -> [DiscoveredSkill] {
    var results: [DiscoveredSkill] = []
    visitSkills(dir: rootDir, results: &results)

    let rootSkillPath = rootDir.appendingPathComponent("SKILL.md")
    if FileManager.default.fileExists(atPath: rootSkillPath.path) {
        if let content = try? String(contentsOf: rootSkillPath, encoding: .utf8) {
            let name = sanitizeName(extractSkillName(content: content) ?? "skill")
            if !results.contains(where: { $0.name == name }) {
                results.append(DiscoveredSkill(name: name, dir: rootDir, root: true))
            }
        }
    }

    return results
}

// MARK: - Remove

/// Removes a skill by name from the canonical location and all detected
/// agent directories.
public func removeSkill(name: String, options: RemoveOptions) throws {
    let isGlobal = options.global
    let cwd = options.cwd ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let base = isGlobal ? homeDir() : cwd
    let canonicalDir = base.appendingPathComponent(".agents/skills/\(name)")
    rmForce(canonicalDir)

    for agent in detectAgents() {
        if agent.universal { continue }
        let agentSkillsDir = isGlobal
            ? agent.globalSkillsDir
            : cwd.appendingPathComponent(agent.projectSkillsDir)
        let agentDir = agentSkillsDir.appendingPathComponent(name)
        rmForce(agentDir)
    }
}

// MARK: - Frontmatter Parsing

/// Extracts the skill name from SKILL.md frontmatter (`name: ...`).
public func extractSkillName(content: String) -> String? {
    for line in content.components(separatedBy: .newlines) {
        if let rest = line.stripPrefix("name:") {
            let name = rest.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                return name
            }
        }
    }
    return nil
}

/// Sanitizes a skill name for use as a directory name.
public func sanitizeName(_ name: String) -> String {
    var sanitized = name.trimmingCharacters(in: .whitespaces)
    sanitized = sanitized.replacingOccurrences(of: "/", with: "-")
    sanitized = sanitized.replacingOccurrences(of: "\\", with: "-")
    sanitized = sanitized.replacingOccurrences(of: "..", with: "")
    if sanitized.count > 255 {
        sanitized = String(sanitized.prefix(255))
    }
    return sanitized
}

// MARK: - Filesystem Helpers

/// Removes a file, directory, or symlink (including broken symlinks).
func rmForce(_ target: URL) {
    let fm = FileManager.default
    let path = target.path

    // Check symlink first (lstat equivalent)
    var isSymlink = false
    if let attrs = try? fm.attributesOfItem(atPath: path),
       let type = attrs[.type] as? FileAttributeType,
       type == .typeSymbolicLink {
        isSymlink = true
    }

    if isSymlink {
        try? fm.removeItem(atPath: path)
    } else {
        try? fm.removeItem(at: target)
    }
}

/// Resolves parent directories through symlinks.
private func resolveParent(_ dir: URL) -> URL {
    let path = dir.path
    let fm = FileManager.default

    // Try to resolve the full path
    if let resolved = try? fm.destinationOfSymbolicLink(atPath: path) {
        return URL(fileURLWithPath: resolved)
    }

    // Try resolving via standardized path
    let resolved = (path as NSString).resolvingSymlinksInPath
    if resolved != path {
        return URL(fileURLWithPath: resolved)
    }

    return dir
}

/// Recursively copies a directory.
func copyDirRecursive(src: URL, dst: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: dst, withIntermediateDirectories: true)

    guard let entries = try? fm.contentsOfDirectory(
        at: src,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    ) else { return }

    for entry in entries {
        let dstPath = dst.appendingPathComponent(entry.lastPathComponent)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
            copyDirRecursive(src: entry, dst: dstPath)
        } else {
            try? fm.copyItem(at: entry, to: dstPath)
        }
    }
}

/// Computes a relative path from `base` to `target`.
public func diffPaths(target: URL, base: URL) -> String {
    let targetComponents = target.standardizedFileURL.pathComponents
    let baseComponents = base.standardizedFileURL.pathComponents

    // Find common prefix length
    var common = 0
    for i in 0..<min(targetComponents.count, baseComponents.count) {
        if targetComponents[i] == baseComponents[i] {
            common += 1
        } else {
            break
        }
    }

    var parts: [String] = []

    // Go up from base to the common ancestor
    for _ in common..<baseComponents.count {
        parts.append("..")
    }

    // Then descend into target
    for i in common..<targetComponents.count {
        parts.append(targetComponents[i])
    }

    return parts.joined(separator: "/")
}

// MARK: - Private String Extension

private extension String {
    func stripPrefix(_ prefix: String) -> String? {
        if hasPrefix(prefix) {
            return String(dropFirst(prefix.count))
        }
        return nil
    }
}
