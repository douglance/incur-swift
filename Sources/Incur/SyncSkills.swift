/// Skill file synchronization — generates and installs skill files from commands.
///
/// Ported from `sync_skills.rs`. Generates SKILL.md files from the command
/// tree, installs them to agent directories, and tracks a hash for staleness
/// detection so repeated syncs are no-ops when commands haven't changed.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Types

/// Options for `syncSkills`.
public struct SyncOptions: Sendable {
    /// Working directory for resolving include globs. Defaults to current dir.
    public let cwd: URL?
    /// Grouping depth for skill files. Defaults to `1`.
    public let depth: Int?
    /// CLI description, used as the top-level group description.
    public let description: String?
    /// Install globally (`true`) or project-local (`false`). Defaults to `true`.
    public let global: Bool
    /// Glob patterns for directories containing additional SKILL.md files to include.
    public let include: [String]?

    public init(
        cwd: URL? = nil,
        depth: Int? = nil,
        description: String? = nil,
        global: Bool = true,
        include: [String]? = nil
    ) {
        self.cwd = cwd
        self.depth = depth
        self.description = description
        self.global = global
        self.include = include
    }
}

/// A synced skill entry.
public struct SyncedSkill: Sendable {
    /// Skill directory name.
    public let name: String
    /// Description extracted from skill frontmatter.
    public let description: String?
    /// Whether this skill was included from a local file (not generated from commands).
    public let external: Bool

    public init(name: String, description: String? = nil, external: Bool = false) {
        self.name = name
        self.description = description
        self.external = external
    }
}

/// Result of a sync operation.
public struct SyncResult: Sendable {
    /// Synced skills with metadata.
    public let skills: [SyncedSkill]
    /// Canonical install paths.
    public let paths: [URL]
    /// Per-agent install details (non-universal agents only).
    public let agents: [AgentInstall]

    public init(skills: [SyncedSkill] = [], paths: [URL] = [], agents: [AgentInstall] = []) {
        self.skills = skills
        self.paths = paths
        self.agents = agents
    }
}

/// Stored metadata for staleness detection.
private struct SyncMeta: Codable {
    let hash: String
    let skills: [String]
    let at: String

    init(hash: String, skills: [String], at: String = "") {
        self.hash = hash
        self.skills = skills
        self.at = at
    }
}

// MARK: - Public API

/// Generates skill files from commands and installs them to agent directories.
///
/// Creates a temporary directory, writes SKILL.md files, installs them via
/// `installSkills`, cleans up stale skills from previous syncs, and
/// writes a hash file for future staleness detection.
public func syncSkills(
    name: String,
    commands: [SkillCommandInfo],
    options: SyncOptions
) async throws -> SyncResult {
    let depth = options.depth ?? 1
    let isGlobal = options.global

    let cwd = options.cwd ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    // Build groups from description
    var groups: [String: String] = [:]
    if let desc = options.description {
        groups[name] = desc
    }

    let files = skillSplit(name: name, commands: commands, depth: depth, groups: groups)

    // Create temp directory
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("incur-skills-\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    defer {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    return try syncInner(
        name: name,
        commands: commands,
        files: files,
        tmpDir: tmpDir,
        cwd: cwd,
        isGlobal: isGlobal,
        include: options.include
    )
}

/// Reads the stored skills hash for a CLI. Returns `nil` if no hash exists.
public func readSkillsHash(name: String) -> String? {
    readMeta(name: name)?.hash
}

// MARK: - Internal Sync

private func syncInner(
    name: String,
    commands: [SkillCommandInfo],
    files: [SkillFile],
    tmpDir: URL,
    cwd: URL,
    isGlobal: Bool,
    include: [String]?
) throws -> SyncResult {
    var skills: [SyncedSkill] = []

    for file in files {
        let filePath: URL
        if file.dir.isEmpty {
            filePath = tmpDir.appendingPathComponent("SKILL.md")
        } else {
            filePath = tmpDir.appendingPathComponent(file.dir).appendingPathComponent("SKILL.md")
        }
        let parent = filePath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let content = "\(file.content)\n"
        try? content.write(to: filePath, atomically: true, encoding: .utf8)

        let desc = extractDescription(content)
        let skillName = file.dir.isEmpty ? name : file.dir
        skills.append(SyncedSkill(name: skillName, description: desc, external: false))
    }

    // Include additional SKILL.md files matched by patterns
    if let patterns = include {
        for pattern in patterns {
            let isRoot = pattern == "_root"
            let searchPath: URL
            if isRoot {
                searchPath = cwd.appendingPathComponent("SKILL.md")
            } else {
                searchPath = cwd.appendingPathComponent(pattern).appendingPathComponent("SKILL.md")
            }

            if FileManager.default.fileExists(atPath: searchPath.path) {
                if let content = try? String(contentsOf: searchPath, encoding: .utf8) {
                    let skillName: String
                    if isRoot {
                        skillName = extractSkillName(content: content) ?? name
                    } else {
                        skillName = searchPath
                            .deletingLastPathComponent()
                            .lastPathComponent
                    }

                    let dest = tmpDir.appendingPathComponent(skillName).appendingPathComponent("SKILL.md")
                    let destParent = dest.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: destParent, withIntermediateDirectories: true)
                    try? content.write(to: dest, atomically: true, encoding: .utf8)

                    if !skills.contains(where: { $0.name == skillName }) {
                        let desc = extractDescription(content)
                        skills.append(SyncedSkill(name: skillName, description: desc, external: true))
                    }
                }
            }
        }
    }

    // Install via agents module
    let installResult = try installSkills(
        sourceDir: tmpDir,
        options: InstallOptions(
            cwd: cwd,
            global: isGlobal
        )
    )

    // Remove stale skills from previous installs
    let currentNames: Set<String> = Set(installResult.paths.compactMap { $0.lastPathComponent })

    if let prevMeta = readMeta(name: name) {
        for old in prevMeta.skills {
            if !currentNames.contains(old) {
                try? removeSkill(
                    name: old,
                    options: RemoveOptions(global: isGlobal, cwd: cwd)
                )
            }
        }
    }

    // Write hash for staleness detection
    let hash = skillHash(commands: commands)
    let skillNames = Array(currentNames)
    writeMeta(name: name, hash: hash, skills: skillNames)

    return SyncResult(
        skills: skills,
        paths: installResult.paths,
        agents: installResult.agents
    )
}

// MARK: - Metadata Persistence

/// Returns the metadata file path for a CLI.
private func metaPath(name: String) -> URL {
    let dataHome: URL
    if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"],
       !xdg.isEmpty {
        dataHome = URL(fileURLWithPath: xdg)
    } else {
        dataHome = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share")
    }
    return dataHome
        .appendingPathComponent("incur")
        .appendingPathComponent("\(name).json")
}

/// Writes the skills metadata for staleness detection and cleanup.
private func writeMeta(name: String, hash: String, skills: [String]) {
    let file = metaPath(name: name)
    let parent = file.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    let meta = SyncMeta(hash: hash, skills: skills, at: chronoNow())

    let encoder = JSONEncoder()
    if let data = try? encoder.encode(meta),
       var json = String(data: data, encoding: .utf8) {
        json += "\n"
        try? json.write(to: file, atomically: true, encoding: .utf8)
    }
}

/// Reads the stored metadata for a CLI.
private func readMeta(name: String) -> SyncMeta? {
    let file = metaPath(name: name)
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(SyncMeta.self, from: data)
}

// MARK: - Helpers

/// Extracts the `description:` frontmatter value from SKILL.md content.
private func extractDescription(_ content: String) -> String? {
    for line in content.components(separatedBy: .newlines) {
        if let rest = line.stripSyncPrefix("description:") {
            let desc = rest.trimmingCharacters(in: .whitespaces)
            if !desc.isEmpty {
                return desc
            }
        }
    }
    return nil
}

/// Returns a basic timestamp string without pulling in external dependencies.
private func chronoNow() -> String {
    let interval = Date().timeIntervalSince1970
    return "\(Int(interval))s"
}

// MARK: - Private String Extension

private extension String {
    func stripSyncPrefix(_ prefix: String) -> String? {
        if hasPrefix(prefix) {
            return String(dropFirst(prefix.count))
        }
        return nil
    }
}
