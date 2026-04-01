/// Error types for the incur framework.
///
/// Ported from `errors.rs`.

import Foundation

/// A field-level validation error detail.
public struct FieldError: Sendable, Equatable {
    /// The field path that failed validation.
    public let path: String
    /// The expected value or type.
    public let expected: String
    /// The value that was received.
    public let received: String
    /// Human-readable validation message.
    public let message: String

    public init(path: String, expected: String, received: String, message: String) {
        self.path = path
        self.expected = expected
        self.received = received
        self.message = message
    }
}

/// CLI error with code, hint, and retryable flag.
public struct IncurError: Error, Sendable {
    /// The short, human-readable error message.
    public let message: String
    /// Machine-readable error code (e.g. `"NOT_AUTHENTICATED"`).
    public let code: String
    /// Actionable hint for the user.
    public let hint: String?
    /// Whether the operation can be retried.
    public let retryable: Bool
    /// Process exit code. When set, `serve()` uses this instead of `1`.
    public let exitCode: Int32?

    public init(
        message: String,
        code: String,
        hint: String? = nil,
        retryable: Bool = false,
        exitCode: Int32? = nil
    ) {
        self.message = message
        self.code = code
        self.hint = hint
        self.retryable = retryable
        self.exitCode = exitCode
    }
}

extension IncurError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Validation error with per-field error details.
public struct ValidationError: Error, Sendable {
    /// Human-readable error message.
    public let message: String
    /// Per-field validation errors.
    public let fieldErrors: [FieldError]

    public init(message: String, fieldErrors: [FieldError] = []) {
        self.message = message
        self.fieldErrors = fieldErrors
    }
}

extension ValidationError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Error thrown when argument parsing fails (unknown flags, missing values).
public struct ParseError: Error, Sendable {
    /// Human-readable error message.
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

extension ParseError: LocalizedError {
    public var errorDescription: String? { message }
}

/// Unified error type for the incur framework.
public enum IncurFrameworkError: Error, Sendable {
    case incur(IncurError)
    case validation(ValidationError)
    case parse(ParseError)
    case other(String)
}

extension IncurFrameworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .incur(let e): return e.message
        case .validation(let e): return e.message
        case .parse(let e): return e.message
        case .other(let msg): return msg
        }
    }
}
