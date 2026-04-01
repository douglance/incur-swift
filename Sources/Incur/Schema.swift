/// Schema trait and field metadata for the incur framework.
///
/// This module defines the `IncurSchema` protocol that describes field metadata
/// for args, options, and env vars. The parser, help system, completions, and
/// skill generation all depend on this.
///
/// Ported from `schema.rs`.

/// The type of a field in a schema.
public indirect enum FieldType: Sendable, Equatable {
    case string
    case number
    case boolean
    case array(FieldType)
    case `enum`([String])
    case count
    case value

    /// Returns a human-readable type name for help output.
    public var displayName: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .array: return "array"
        case .enum(let values): return values.joined(separator: "|")
        case .count: return "count"
        case .value: return "value"
        }
    }
}

/// Metadata about a single field in a schema.
public struct FieldMeta: Sendable {
    /// The field name (Swift identifier, in camelCase or snake_case).
    public let name: String
    /// The field's CLI name (kebab-case version of name).
    public let cliName: String
    /// Human-readable description.
    public let description: String?
    /// The field's type.
    public let fieldType: FieldType
    /// Whether the field is required.
    public let required: Bool
    /// Default value, if any.
    public let defaultValue: JSONValue?
    /// Short alias (single char).
    public let alias: Character?
    /// Whether the field is deprecated.
    public let deprecated: Bool
    /// Environment variable name (for Env schemas).
    public let envName: String?

    public init(
        name: String,
        cliName: String? = nil,
        description: String? = nil,
        fieldType: FieldType = .string,
        required: Bool = false,
        defaultValue: JSONValue? = nil,
        alias: Character? = nil,
        deprecated: Bool = false,
        envName: String? = nil
    ) {
        self.name = name
        self.cliName = cliName ?? toKebab(name)
        self.description = description
        self.fieldType = fieldType
        self.required = required
        self.defaultValue = defaultValue
        self.alias = alias
        self.deprecated = deprecated
        self.envName = envName
    }
}

/// Protocol for types that can describe themselves as a schema and parse from raw values.
public protocol IncurSchema {
    /// Returns metadata for all fields in this schema.
    static func fields() -> [FieldMeta]

    /// Parses from a map of raw string/value pairs.
    static func fromRaw(_ raw: OrderedMap) throws -> Self
}

extension IncurSchema {
    /// Returns the names of all fields (for option name lookups).
    public static func fieldNames() -> [String] {
        fields().map(\.name)
    }
}

// MARK: - Case Conversion

/// Converts a snake_case or camelCase name to CLI kebab-case.
public func toKebab(_ name: String) -> String {
    var result = ""
    result.reserveCapacity(name.count)
    for (i, ch) in name.enumerated() {
        if ch == "_" {
            result.append("-")
        } else if ch.isUppercase {
            if i > 0 { result.append("-") }
            result.append(ch.lowercased())
        } else {
            result.append(ch)
        }
    }
    return result
}

/// Converts a CLI kebab-case name back to snake_case.
public func toSnake(_ name: String) -> String {
    name.replacingOccurrences(of: "-", with: "_")
}
