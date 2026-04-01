/// Output envelope types for the incur framework.
///
/// Ported from `output.rs`.

/// A CTA (call-to-action) block for command output.
public struct CtaBlock: Sendable, Codable, Equatable {
    /// Commands to suggest.
    public let commands: [CtaEntry]
    /// Human-readable label. Defaults to "Suggested commands:".
    public let description: String?

    public init(commands: [CtaEntry], description: String? = nil) {
        self.commands = commands
        self.description = description
    }
}

/// A single CTA entry.
public enum CtaEntry: Sendable, Codable, Equatable {
    case simple(String)
    case detailed(command: String, description: String?)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .simple(s)
            return
        }
        let obj = try DetailedCTA(from: decoder)
        self = .detailed(command: obj.command, description: obj.description)
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .simple(let s):
            var container = encoder.singleValueContainer()
            try container.encode(s)
        case .detailed(let command, let description):
            try DetailedCTA(command: command, description: description).encode(to: encoder)
        }
    }

    private struct DetailedCTA: Codable {
        let command: String
        let description: String?
    }
}

/// Result of executing a command.
public enum CommandResult: Sendable {
    /// Successful execution with data.
    case ok(data: JSONValue, cta: CtaBlock? = nil)
    /// Failed execution with error details.
    case error(code: String, message: String, retryable: Bool = false, exitCode: Int32? = nil, cta: CtaBlock? = nil)
    /// Streaming output.
    case stream(AsyncStream<JSONValue>)
}

/// Supported output formats.
public enum Format: String, Sendable, CaseIterable {
    case toon
    case json
    case yaml
    case markdown
    case jsonl
    case table
    case csv

    /// Parse a format string.
    public static func from(_ s: String) -> Format? {
        switch s.lowercased() {
        case "toon": return .toon
        case "json": return .json
        case "yaml": return .yaml
        case "md", "markdown": return .markdown
        case "jsonl": return .jsonl
        case "table": return .table
        case "csv": return .csv
        default: return nil
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: return "md"
        default: return rawValue
        }
    }
}

/// Output policy controlling who sees output.
public enum OutputPolicy: Sendable {
    case all
    case agentOnly
}

/// Serializable field error for output.
public struct FieldErrorOutput: Sendable, Codable {
    public let path: String
    public let expected: String
    public let received: String
    public let message: String

    public init(from fieldError: FieldError) {
        self.path = fieldError.path
        self.expected = fieldError.expected
        self.received = fieldError.received
        self.message = fieldError.message
    }
}
