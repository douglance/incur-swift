/// Help text generation for the incur framework.
///
/// Generates formatted help output for both router CLIs (command groups)
/// and leaf commands.
///
/// Ported from `help.rs`.

/// Summary of a command for display in help text.
public struct CommandSummary: Sendable {
    public let name: String
    public let description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// Options for formatting router help (command groups).
public struct FormatRootOptions: Sendable {
    public let aliases: [String]?
    public let configFlag: String?
    public let commands: [CommandSummary]
    public let description: String?
    public let root: Bool
    public let version: String?

    public init(
        aliases: [String]? = nil,
        configFlag: String? = nil,
        commands: [CommandSummary] = [],
        description: String? = nil,
        root: Bool = false,
        version: String? = nil
    ) {
        self.aliases = aliases
        self.configFlag = configFlag
        self.commands = commands
        self.description = description
        self.root = root
        self.version = version
    }
}

/// Options for formatting leaf command help.
public struct FormatCommandOptions: Sendable {
    public let aliases: [String]?
    public let argsFields: [FieldMeta]
    public let configFlag: String?
    public let commands: [CommandSummary]
    public let description: String?
    public let envFields: [FieldMeta]
    public let examples: [Example]
    public let hint: String?
    public let hideGlobalOptions: Bool
    public let optionsFields: [FieldMeta]
    public let optionAliases: [String: Character]
    public let root: Bool
    public let version: String?

    public init(
        aliases: [String]? = nil,
        argsFields: [FieldMeta] = [],
        configFlag: String? = nil,
        commands: [CommandSummary] = [],
        description: String? = nil,
        envFields: [FieldMeta] = [],
        examples: [Example] = [],
        hint: String? = nil,
        hideGlobalOptions: Bool = false,
        optionsFields: [FieldMeta] = [],
        optionAliases: [String: Character] = [:],
        root: Bool = false,
        version: String? = nil
    ) {
        self.aliases = aliases
        self.argsFields = argsFields
        self.configFlag = configFlag
        self.commands = commands
        self.description = description
        self.envFields = envFields
        self.examples = examples
        self.hint = hint
        self.hideGlobalOptions = hideGlobalOptions
        self.optionsFields = optionsFields
        self.optionAliases = optionAliases
        self.root = root
        self.version = version
    }
}

// MARK: - Public API

/// Formats help text for a router CLI or command group.
public func formatRootHelp(name: String, options: FormatRootOptions) -> String {
    var lines: [String] = []

    // Header
    let title = options.version.map { "\(name)@\($0)" } ?? name
    if let desc = options.description {
        lines.append("\(title) \u{2014} \(desc)")
    } else {
        lines.append(title)
    }
    lines.append("")

    // Synopsis
    lines.append("Usage: \(name) <command>")
    if let aliases = options.aliases, !aliases.isEmpty {
        lines.append("Aliases: \(aliases.joined(separator: ", "))")
    }

    // Commands
    if !options.commands.isEmpty {
        lines.append("")
        lines.append("Commands:")
        let maxLen = options.commands.map(\.name.count).max() ?? 0
        for cmd in options.commands {
            if let desc = cmd.description {
                let padding = String(repeating: " ", count: maxLen - cmd.name.count)
                lines.append("  \(cmd.name)\(padding)  \(desc)")
            } else {
                lines.append("  \(cmd.name)")
            }
        }
    }

    // Global options
    lines.append(contentsOf: globalOptionsLines(root: options.root, configFlag: options.configFlag))

    return lines.joined(separator: "\n")
}

/// Formats help text for a leaf command.
public func formatCommandHelp(name: String, options: FormatCommandOptions) -> String {
    var lines: [String] = []

    // Header
    let title = options.version.map { "\(name)@\($0)" } ?? name
    if let desc = options.description {
        lines.append("\(title) \u{2014} \(desc)")
    } else {
        lines.append(title)
    }
    lines.append("")

    // Synopsis
    let synopsis = buildSynopsis(name: name, argsFields: options.argsFields)
    let optionsSuffix = options.optionsFields.isEmpty ? "" : " [options]"
    let commandsSuffix = options.commands.isEmpty ? "" : " | <command>"
    lines.append("Usage: \(synopsis)\(optionsSuffix)\(commandsSuffix)")
    if let aliases = options.aliases, !aliases.isEmpty {
        lines.append("Aliases: \(aliases.joined(separator: ", "))")
    }

    // Arguments
    if !options.argsFields.isEmpty {
        let entries = options.argsFields.map { ($0.name, $0.description ?? "") }
        if !entries.isEmpty {
            lines.append("")
            lines.append("Arguments:")
            let maxLen = entries.map(\.0.count).max() ?? 0
            for (fieldName, desc) in entries {
                let padding = String(repeating: " ", count: maxLen - fieldName.count)
                lines.append("  \(fieldName)\(padding)  \(desc)")
            }
        }
    }

    // Options
    if !options.optionsFields.isEmpty {
        struct OptionEntry {
            let flag: String
            let description: String
            let defaultValue: String?
            let deprecated: Bool
        }

        let entries: [OptionEntry] = options.optionsFields.map { f in
            let typeName = f.fieldType.displayName
            let short = options.optionAliases[f.name]
            let flag: String
            if let ch = short {
                flag = "--\(f.cliName), -\(ch) <\(typeName)>"
            } else {
                flag = "--\(f.cliName) <\(typeName)>"
            }
            return OptionEntry(
                flag: flag,
                description: f.description ?? "",
                defaultValue: f.defaultValue.map { "\($0)" },
                deprecated: f.deprecated
            )
        }

        if !entries.isEmpty {
            lines.append("")
            lines.append("Options:")
            let maxLen = entries.map(\.flag.count).max() ?? 0
            for entry in entries {
                let padding = String(repeating: " ", count: maxLen - entry.flag.count)
                let prefix = entry.deprecated ? "[deprecated] " : ""
                let desc: String
                if let dv = entry.defaultValue {
                    desc = "\(prefix)\(entry.description) (default: \(dv))"
                } else {
                    desc = "\(prefix)\(entry.description)"
                }
                lines.append("  \(entry.flag)\(padding)  \(desc)")
            }
        }
    }

    // Examples
    if !options.examples.isEmpty {
        lines.append("")
        lines.append("Examples:")
        let maxLen = options.examples.map { ex in
            ex.command.isEmpty ? name.count : name.count + 1 + ex.command.count
        }.max() ?? 0
        for ex in options.examples {
            let cmd = ex.command.isEmpty ? name : "\(name) \(ex.command)"
            if let desc = ex.description {
                let padding = String(repeating: " ", count: maxLen - cmd.count)
                lines.append("  \(cmd)\(padding)  # \(desc)")
            } else {
                lines.append("  \(cmd)")
            }
        }
    }

    // Hint
    if let hint = options.hint {
        lines.append("")
        lines.append(hint)
    }

    // Subcommands
    if !options.commands.isEmpty {
        lines.append("")
        lines.append("Commands:")
        let maxLen = options.commands.map(\.name.count).max() ?? 0
        for cmd in options.commands {
            if let desc = cmd.description {
                let padding = String(repeating: " ", count: maxLen - cmd.name.count)
                lines.append("  \(cmd.name)\(padding)  \(desc)")
            } else {
                lines.append("  \(cmd.name)")
            }
        }
    }

    // Global options
    if !options.hideGlobalOptions {
        lines.append(contentsOf: globalOptionsLines(root: options.root, configFlag: options.configFlag))
    }

    // Environment Variables
    if !options.envFields.isEmpty {
        struct EnvEntry {
            let name: String
            let description: String
            let defaultValue: String?
        }

        let entries: [EnvEntry] = options.envFields.map { f in
            EnvEntry(
                name: f.envName ?? f.name,
                description: f.description ?? "",
                defaultValue: f.defaultValue.map { "\($0)" }
            )
        }

        if !entries.isEmpty {
            lines.append("")
            lines.append("Environment Variables:")
            let maxLen = entries.map(\.name.count).max() ?? 0
            for entry in entries {
                let padding = String(repeating: " ", count: maxLen - entry.name.count)
                var parts = [entry.description]
                if let dv = entry.defaultValue {
                    parts.append("default: \(dv)")
                }
                let desc = parts.count > 1
                    ? "\(parts[0]) (\(parts.dropFirst().joined(separator: ", ")))"
                    : parts[0]
                lines.append("  \(entry.name)\(padding)  \(desc)")
            }
        }
    }

    return lines.joined(separator: "\n")
}

// MARK: - Internal helpers

/// Builds the synopsis string with `<required>` and `[optional]` placeholders.
private func buildSynopsis(name: String, argsFields: [FieldMeta]) -> String {
    if argsFields.isEmpty { return name }

    var parts = [name]
    for field in argsFields {
        let label: String
        if case .enum(let values) = field.fieldType {
            label = values.joined(separator: "|")
        } else {
            label = field.name
        }
        parts.append(field.required ? "<\(label)>" : "[\(label)]")
    }
    return parts.joined(separator: " ")
}

/// Renders the global options block (built-in flags).
private func globalOptionsLines(root: Bool, configFlag: String?) -> [String] {
    var lines: [String] = []

    // Integrations section (root only)
    if root {
        let builtins = [
            ("completions", "Generate shell completion script"),
            ("mcp add", "Register as MCP server"),
            ("skills add", "Sync skill files to agents"),
        ]
        let maxCmd = builtins.map(\.0.count).max() ?? 0
        lines.append("")
        lines.append("Integrations:")
        for (name, desc) in builtins {
            let padding = String(repeating: " ", count: maxCmd - name.count)
            lines.append("  \(name)\(padding)  \(desc)")
        }
    }

    // Global flags
    var flags: [(String, String)] = []

    if let cfg = configFlag {
        flags.append(("--\(cfg) <path>", "Load JSON option defaults from a file"))
    }

    flags.append(("--filter-output <keys>", "Filter output by key paths (e.g. foo,bar.baz,a[0,3])"))
    flags.append(("--format <toon|json|yaml|md|jsonl|table|csv>", "Output format"))
    flags.append(("--help", "Show help"))
    flags.append(("--llms, --llms-full", "Print LLM-readable manifest"))

    if root {
        flags.append(("--mcp", "Start as MCP stdio server"))
    }

    if root, configFlag != nil {
        flags.append(("--config-schema", "Show JSON Schema for config file"))
    }

    if let cfg = configFlag {
        flags.append(("--no-\(cfg)", "Disable JSON option defaults for this run"))
    }

    flags.append(("--schema", "Show JSON Schema for command"))
    flags.append(("--token-count", "Print token count of output (instead of output)"))
    flags.append(("--token-limit <n>", "Limit output to n tokens"))
    flags.append(("--token-offset <n>", "Skip first n tokens of output"))
    flags.append(("--verbose", "Show full output envelope"))

    if root {
        flags.append(("--version", "Show version"))
    }

    flags.sort { $0.0 < $1.0 }

    let maxLen = flags.map(\.0.count).max() ?? 0

    lines.append("")
    lines.append("Global Options:")
    for (flag, desc) in flags {
        let padding = String(repeating: " ", count: maxLen - flag.count)
        lines.append("  \(flag)\(padding)  \(desc)")
    }

    return lines
}
