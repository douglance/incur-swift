/// Curl-style argv parsing and HTTP request/response handling.
///
/// Ported from `fetch.rs`. Parses curl-style command-line arguments into
/// structured fetch input, and provides utilities for detecting streaming
/// responses.

import Foundation

// MARK: - Types

/// Structured input parsed from curl-style argv.
public struct FetchInput: Sendable, Equatable {
    /// The request path (e.g. "/users/123").
    public let path: String
    /// HTTP method (e.g. "GET", "POST").
    public let method: String
    /// Request headers.
    public let headers: [(String, String)]
    /// Request body (for POST/PUT/PATCH).
    public let body: String?
    /// Query parameters.
    public let query: [(String, String)]

    public init(
        path: String,
        method: String,
        headers: [(String, String)] = [],
        body: String? = nil,
        query: [(String, String)] = []
    ) {
        self.path = path
        self.method = method
        self.headers = headers
        self.body = body
        self.query = query
    }

    public static func == (lhs: FetchInput, rhs: FetchInput) -> Bool {
        lhs.path == rhs.path
            && lhs.method == rhs.method
            && lhs.body == rhs.body
            && lhs.headers.count == rhs.headers.count
            && zip(lhs.headers, rhs.headers).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            && lhs.query.count == rhs.query.count
            && zip(lhs.query, rhs.query).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

/// Structured output from a fetch response.
public struct FetchOutput: Sendable {
    /// Whether the response status is in the 2xx range.
    public let ok: Bool
    /// HTTP status code.
    public let status: Int
    /// Parsed response body (JSON parsed if possible, otherwise string).
    public let data: JSONValue
    /// Response headers.
    public let headers: [(String, String)]

    public init(ok: Bool, status: Int, data: JSONValue, headers: [(String, String)] = []) {
        self.ok = ok
        self.status = status
        self.data = data
        self.headers = headers
    }
}

// MARK: - FetchHandler Protocol

/// Protocol for fetch gateway handlers.
///
/// Implementations receive a parsed `FetchInput` and return a `FetchOutput`.
/// This allows CLIs to proxy HTTP-style requests through a command gateway.
public protocol FetchHandler: Sendable {
    /// Handle a fetch request and return a response.
    func handle(_ request: FetchInput) async -> FetchOutput
}

/// Options for configuring a fetch gateway command.
public struct FetchGatewayOptions: Sendable {
    /// A short description of the gateway.
    public let description: String?
    /// Base path prefix for request URLs.
    public let basePath: String?
    /// Output policy for the gateway.
    public let outputPolicy: OutputPolicy?

    public init(
        description: String? = nil,
        basePath: String? = nil,
        outputPolicy: OutputPolicy? = nil
    ) {
        self.description = description
        self.basePath = basePath
        self.outputPolicy = outputPolicy
    }
}

// MARK: - Reserved Flags

/// Reserved flags consumed by the fetch gateway (not forwarded as query params).
private func isReservedFlag(_ key: String) -> Bool {
    switch key {
    case "method", "body", "data", "header":
        return true
    default:
        return false
    }
}

/// Maps short flags to their long-form reserved names.
private func reservedShort(_ ch: Character) -> String? {
    switch ch {
    case "X": return "method"
    case "d": return "data"
    case "H": return "header"
    default: return nil
    }
}

// MARK: - Public API

/// Parses curl-style argv into a structured fetch input.
///
/// Supports:
/// - Positional segments joined into a path (e.g. `users 123` -> `/users/123`)
/// - `-X METHOD` or `--method METHOD` to set the HTTP method
/// - `-d BODY` or `--data BODY` or `--body BODY` to set the request body
/// - `-H "Name: Value"` or `--header "Name: Value"` to set headers
/// - Unknown `--key value` pairs become query parameters
/// - `--key=value` equals syntax for query
public func parseFetchArgv(_ argv: [String]) -> FetchInput {
    var segments: [String] = []
    var headers: [(String, String)] = []
    var query: [(String, String)] = []
    var method: String? = nil
    var body: String? = nil

    func handleReserved(_ key: String, _ value: String) {
        switch key {
        case "method":
            method = value.uppercased()
        case "body", "data":
            body = value
        case "header":
            if let colonIdx = value.firstIndex(of: ":") {
                let name = value[..<colonIdx].trimmingCharacters(in: .whitespaces)
                let val = value[value.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                headers.append((name, val))
            }
        default:
            break
        }
    }

    var i = 0
    while i < argv.count {
        let token = argv[i]

        if token.hasPrefix("--") {
            if let eqIdx = token.firstIndex(of: "="), eqIdx > token.index(token.startIndex, offsetBy: 2) {
                // --key=value
                let key = String(token[token.index(token.startIndex, offsetBy: 2)..<eqIdx])
                let value = String(token[token.index(after: eqIdx)...])
                if isReservedFlag(key) {
                    handleReserved(key, value)
                } else {
                    query.append((key, value))
                }
                i += 1
            } else {
                let key = String(token.dropFirst(2))
                let value = (i + 1 < argv.count) ? argv[i + 1] : ""
                if isReservedFlag(key) {
                    handleReserved(key, value)
                    i += 2
                } else {
                    query.append((key, value))
                    i += 2
                }
            }
        } else if token.hasPrefix("-") && token.count == 2 {
            let short = token[token.index(after: token.startIndex)]
            let value = (i + 1 < argv.count) ? argv[i + 1] : ""
            if let mapped = reservedShort(short) {
                handleReserved(mapped, value)
                i += 2
            } else {
                // Unknown short flag -- skip
                i += 2
            }
        } else {
            segments.append(token)
            i += 1
        }
    }

    let path: String
    if segments.isEmpty {
        path = "/"
    } else {
        path = "/\(segments.joined(separator: "/"))"
    }

    let resolvedMethod: String
    if let m = method {
        resolvedMethod = m
    } else if body != nil {
        resolvedMethod = "POST"
    } else {
        resolvedMethod = "GET"
    }

    return FetchInput(
        path: path,
        method: resolvedMethod,
        headers: headers,
        body: body,
        query: query
    )
}

/// Returns true if the content-type indicates a streaming NDJSON response.
public func isStreamingResponse(contentType: String?) -> Bool {
    contentType == "application/x-ndjson"
}
