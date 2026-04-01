/// Skill file (SKILL.md) generation for agent discovery.
///
/// Ported from `skill.rs`. Generates Markdown skill files that AI coding
/// agents use to discover and understand CLI commands. Supports compact index
/// generation (`--llms`), full skill file generation, depth-based splitting,
/// and SHA-256 hashing for staleness detection.

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// MARK: - Types

/// Information about a single command, used for skill file generation.
public struct SkillCommandInfo: Sendable {
    /// The command name (may include spaces for subcommands, e.g. "deploy app").
    public let name: String
    /// Human-readable description.
    public let description: String?
    /// Positional argument field metadata.
    public let argsFields: [FieldMeta]
    /// Named option field metadata.
    public let optionsFields: [FieldMeta]
    /// Environment variable field metadata.
    public let envFields: [FieldMeta]
    /// Actionable hint for users.
    public let hint: String?
    /// Usage examples.
    public let examples: [Example]
    /// JSON Schema for command output (as JSONValue).
    public let outputSchema: JSONValue?

    public init(
        name: String,
        description: String? = nil,
        argsFields: [FieldMeta] = [],
        optionsFields: [FieldMeta] = [],
        envFields: [FieldMeta] = [],
        hint: String? = nil,
        examples: [Example] = [],
        outputSchema: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.argsFields = argsFields
        self.optionsFields = optionsFields
        self.envFields = envFields
        self.hint = hint
        self.examples = examples
        self.outputSchema = outputSchema
    }
}

/// A generated skill file with its directory name and content.
public struct SkillFile: Sendable, Equatable {
    /// Directory name relative to output root (empty string for depth 0).
    public let dir: String
    /// Markdown content.
    public let content: String

    public init(dir: String, content: String) {
        self.dir = dir
        self.content = content
    }
}

// MARK: - Public API

/// Generates a compact Markdown command index for `--llms`.
///
/// Produces a table summarizing all commands with their signatures
/// and descriptions.
public func skillIndex(name: String, commands: [SkillCommandInfo], description: String? = nil) -> String {
    var lines = ["# \(name)"]
    if let desc = description {
        lines.append("")
        lines.append(desc)
    }
    lines.append("")
    lines.append("| Command | Description |")
    lines.append("|---------|-------------|")

    for cmd in commands {
        let signature = buildSignature(cli: name, command: cmd)
        let desc = cmd.description ?? ""
        lines.append("| `\(signature)` | \(desc) |")
    }

    lines.append("")
    lines.append("Run `\(name) --llms-full` for full manifest. Run `\(name) <command> --schema` for argument details.")

    return lines.joined(separator: "\n")
}

/// Generates a full Markdown skill file from a CLI name and collected commands.
///
/// When `groups` is non-empty, commands are organized under group headings.
public func skillGenerate(name: String, commands: [SkillCommandInfo], groups: [String: String] = [:]) -> String {
    if groups.isEmpty {
        return commands
            .map { renderCommandBody(cli: name, command: $0, level: 1) }
            .joined(separator: "\n\n")
    }

    var sections = ["# \(name)"]
    var lastGroup: String? = nil

    for cmd in commands {
        let segment = cmd.name.split(separator: " ").first.map(String.init) ?? ""
        if lastGroup != segment {
            lastGroup = segment
            let heading: String
            if let desc = groups[segment] {
                heading = "## \(name) \(segment)\n\n\(desc)"
            } else {
                heading = "## \(name) \(segment)"
            }
            sections.append(heading)
        }
        sections.append(renderCommandBody(cli: name, command: cmd, level: 3))
    }

    return sections.joined(separator: "\n\n")
}

/// Splits commands into multiple skill files grouped by command depth.
///
/// At depth 0, all commands go into a single file. At depth 1, commands are
/// grouped by their first path segment, etc.
public func skillSplit(name: String, commands: [SkillCommandInfo], depth: Int, groups: [String: String] = [:]) -> [SkillFile] {
    if depth == 0 {
        return [SkillFile(
            dir: "",
            content: renderGroup(cli: name, title: name, commands: commands, groups: groups, prefix: name)
        )]
    }

    // Group commands by their first N segments
    var buckets: [(key: String, commands: [SkillCommandInfo])] = []
    var bucketMap: [String: Int] = [:]

    for cmd in commands {
        let segments = cmd.name.split(separator: " ").map(String.init)
        let key = segments.prefix(depth).joined(separator: "-")
        if let idx = bucketMap[key] {
            buckets[idx].commands.append(cmd)
        } else {
            bucketMap[key] = buckets.count
            buckets.append((key: key, commands: [cmd]))
        }
    }

    return buckets.map { bucket in
        let firstCmd = bucket.commands[0]
        let segments = firstCmd.name.split(separator: " ").map(String.init)
        let prefix = segments.prefix(depth).joined(separator: " ")
        let title = "\(name) \(prefix)"
        return SkillFile(
            dir: bucket.key,
            content: renderGroup(cli: name, title: title, commands: bucket.commands, groups: groups, prefix: prefix)
        )
    }
}

/// Computes a SHA-256 hash of command structure for staleness detection.
///
/// Returns the first 16 hex characters of the hash.
public func skillHash(commands: [SkillCommandInfo]) -> String {
    // Build a JSON representation of command structure
    var dataArray: [JSONValue] = []

    for cmd in commands {
        var obj = OrderedMap()
        obj["name"] = .string(cmd.name)
        if let desc = cmd.description {
            obj["description"] = .string(desc)
        }
        if !cmd.argsFields.isEmpty {
            obj["args"] = fieldsToJSON(cmd.argsFields)
        }
        if !cmd.envFields.isEmpty {
            obj["env"] = fieldsToJSON(cmd.envFields)
        }
        if !cmd.optionsFields.isEmpty {
            obj["options"] = fieldsToJSON(cmd.optionsFields)
        }
        if let output = cmd.outputSchema {
            obj["output"] = output
        }
        dataArray.append(.object(obj))
    }

    let jsonValue = JSONValue.array(dataArray)
    let jsonString = jsonValue.toJSON(pretty: false, sortedKeys: true)

    #if canImport(CryptoKit)
    let digest = SHA256.hash(data: Data(jsonString.utf8))
    let bytes = Array(digest.prefix(8))
    return bytes.map { String(format: "%02x", $0) }.joined()
    #else
    // Fallback: simple hash for non-Apple platforms
    var hash: UInt64 = 5381
    for byte in jsonString.utf8 {
        hash = ((hash &<< 5) &+ hash) &+ UInt64(byte)
    }
    return String(format: "%016x", hash)
    #endif
}

/// Renders a command's heading and sections without frontmatter.
public func renderCommandBody(cli: String, command: SkillCommandInfo, level: Int) -> String {
    let fullName = "\(cli) \(command.name)"
    var sections: [String] = []
    let h = String(repeating: "#", count: level)

    var heading = "\(h) \(fullName)"
    if let desc = command.description {
        heading += "\n\n\(desc)"
    }
    sections.append(heading)

    let sub = String(repeating: "#", count: level + 1)

    // Arguments table
    if !command.argsFields.isEmpty {
        var table = "\(sub) Arguments\n\n| Name | Type | Required | Description |\n|------|------|----------|-------------|"
        for field in command.argsFields {
            let typeName = field.fieldType.displayName
            let req = field.required ? "yes" : "no"
            let desc = field.description ?? ""
            table += "\n| `\(field.name)` | `\(typeName)` | \(req) | \(desc) |"
        }
        sections.append(table)
    }

    // Environment Variables table
    if !command.envFields.isEmpty {
        var table = "\(sub) Environment Variables\n\n| Name | Type | Required | Default | Description |\n|------|------|----------|---------|-------------|"
        for field in command.envFields {
            let typeName = field.fieldType.displayName
            let req = field.required ? "yes" : "no"
            let defaultStr = field.defaultValue.map { "`\($0)`" } ?? ""
            let desc = field.description ?? ""
            let envName = field.envName ?? field.name
            table += "\n| `\(envName)` | `\(typeName)` | \(req) | \(defaultStr) | \(desc) |"
        }
        sections.append(table)
    }

    // Options table
    if !command.optionsFields.isEmpty {
        var table = "\(sub) Options\n\n| Flag | Type | Default | Description |\n|------|------|---------|-------------|"
        for field in command.optionsFields {
            let typeName = field.fieldType.displayName
            let defaultStr = field.defaultValue.map { "`\($0)`" } ?? ""
            let rawDesc = field.description ?? ""
            let desc = field.deprecated ? "**Deprecated.** \(rawDesc)" : rawDesc
            table += "\n| `--\(field.cliName)` | `\(typeName)` | \(defaultStr) | \(desc) |"
        }
        sections.append(table)
    }

    // Output section
    if let output = command.outputSchema {
        if let table = schemaToTable(schema: output, prefix: "") {
            sections.append("\(sub) Output\n\n\(table)")
        } else {
            let typeName = resolveTypeName(output)
            sections.append("\(sub) Output\n\nType: `\(typeName)`")
        }
    }

    // Examples
    if !command.examples.isEmpty {
        var exLines: [String] = []
        for ex in command.examples {
            if let desc = ex.description {
                exLines.append("# \(desc)")
            }
            exLines.append("\(cli) \(ex.command)")
            exLines.append("")
        }
        // Remove trailing empty line
        if exLines.last?.isEmpty == true {
            exLines.removeLast()
        }
        sections.append("\(sub) Examples\n\n```sh\n\(exLines.joined(separator: "\n"))\n```")
    }

    // Hint
    if let hint = command.hint {
        sections.append("> \(hint)")
    }

    return sections.joined(separator: "\n\n")
}

/// Renders a JSON Schema object as a Markdown table.
/// Returns `nil` for non-object schemas.
public func schemaToTable(schema: JSONValue, prefix: String) -> String? {
    guard case .object(let obj) = schema else { return nil }
    guard obj["type"]?.stringValue == "object" else { return nil }
    guard case .object(let properties)? = obj["properties"] else { return nil }
    if properties.isEmpty { return nil }

    let required: Set<String>
    if let reqArray = obj["required"]?.arrayValue {
        required = Set(reqArray.compactMap(\.stringValue))
    } else {
        required = []
    }

    var rows: [String] = []
    for (key, prop) in properties {
        let name = prefix.isEmpty ? key : "\(prefix).\(key)"
        let typeName = resolveTypeName(prop)
        let req = required.contains(key) ? "yes" : "no"
        let desc = prop["description"]?.stringValue ?? ""
        rows.append("| `\(name)` | `\(typeName)` | \(req) | \(desc) |")

        // Expand nested objects
        if let propObj = prop.objectValue {
            if propObj["type"]?.stringValue == "object" && propObj["properties"] != nil {
                if let nested = schemaToTable(schema: prop, prefix: name) {
                    // Skip header + separator (first 2 lines)
                    let nestedLines = nested.split(separator: "\n", omittingEmptySubsequences: false)
                    for line in nestedLines.dropFirst(2) {
                        rows.append(String(line))
                    }
                }
            }
            // Expand array item objects
            if propObj["type"]?.stringValue == "array",
               let items = propObj["items"],
               items["type"]?.stringValue == "object" {
                let arrayPrefix = "\(name)[]"
                if let nested = schemaToTable(schema: items, prefix: arrayPrefix) {
                    let nestedLines = nested.split(separator: "\n", omittingEmptySubsequences: false)
                    for line in nestedLines.dropFirst(2) {
                        rows.append(String(line))
                    }
                }
            }
        }
    }

    return "| Field | Type | Required | Description |\n|-------|------|----------|-------------|\n\(rows.joined(separator: "\n"))"
}

/// Converts a title string to a URL slug.
public func slugify(_ title: String) -> String {
    let lower = title.lowercased()
    var slug = ""
    slug.reserveCapacity(lower.count)
    var lastWasDash = false

    for ch in lower {
        if ch.isASCII && (ch.isLetter || ch.isNumber) {
            slug.append(ch)
            lastWasDash = false
        } else if ch == "-" {
            if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        } else {
            if !lastWasDash && !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
    }

    // Trim leading/trailing dashes
    return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

// MARK: - Internal Rendering

/// Builds a command signature with arg placeholders.
private func buildSignature(cli: String, command: SkillCommandInfo) -> String {
    let base = "\(cli) \(command.name)"
    if command.argsFields.isEmpty {
        return base
    }
    let argNames = command.argsFields.map { field -> String in
        if field.required {
            return "<\(field.name)>"
        } else {
            return "[\(field.name)]"
        }
    }
    return "\(base) \(argNames.joined(separator: " "))"
}

/// Renders a group-level frontmatter + command bodies.
private func renderGroup(cli: String, title: String, commands: [SkillCommandInfo], groups: [String: String], prefix: String?) -> String {
    let groupDesc = prefix.flatMap { groups[$0] }
    let childDescs = commands.compactMap(\.description)

    var descParts: [String] = []
    if let gd = groupDesc {
        // Trim trailing period
        let trimmed = gd.hasSuffix(".") ? String(gd.dropLast()) : gd
        descParts.append(trimmed)
    }
    if !childDescs.isEmpty {
        descParts.append(childDescs.joined(separator: ", "))
    }

    let description: String
    if descParts.isEmpty {
        description = "Run `\(title) --help` for usage details."
    } else {
        description = "\(descParts.joined(separator: ". ")). Run `\(title) --help` for usage details."
    }

    let slug = slugify(title)
    let fm = [
        "---",
        "name: \(slug)",
        "description: \(description)",
        "requires_bin: \(cli)",
        "command: \(title)",
        "---",
    ]

    let body = commands
        .map { renderCommandBody(cli: cli, command: $0, level: 1) }
        .joined(separator: "\n\n---\n\n")

    return "\(fm.joined(separator: "\n"))\n\n\(body)"
}

/// Resolves a simple type name from a JSON Schema property.
private func resolveTypeName(_ prop: JSONValue?) -> String {
    guard let prop = prop else { return "unknown" }
    guard case .object(let obj) = prop else { return "unknown" }
    guard let typeVal = obj["type"]?.stringValue else { return "unknown" }
    return typeVal == "integer" ? "number" : typeVal
}

/// Serializes field metadata to JSON for hashing.
private func fieldsToJSON(_ fields: [FieldMeta]) -> JSONValue {
    var props = OrderedMap()
    var required: [JSONValue] = []

    for field in fields {
        var fieldObj = OrderedMap()
        fieldObj["type"] = .string(field.fieldType.displayName)
        if let desc = field.description {
            fieldObj["description"] = .string(desc)
        }
        if let defaultValue = field.defaultValue {
            fieldObj["default"] = defaultValue
        }
        props[field.name] = .object(fieldObj)
        if field.required {
            required.append(.string(field.name))
        }
    }

    var schema = OrderedMap()
    schema["type"] = .string("object")
    schema["properties"] = .object(props)
    if !required.isEmpty {
        schema["required"] = .array(required)
    }
    return .object(schema)
}
