/// Framework-agnostic HTTP transport utilities for the incur framework.
///
/// Provides routing and handler logic that can be plugged into any Swift HTTP
/// framework (Vapor, Hummingbird, etc.) without adding a framework dependency.
/// The module flattens the command tree into HTTP routes and provides a
/// `handleHttpRequest` function that executes commands and returns structured
/// JSON responses.
///
/// Ported from `http.rs`.

import Foundation

// MARK: - Types

/// A flattened HTTP route mapping a path + method to a command.
public struct HttpRoute: Sendable {
    /// HTTP method (e.g. "GET", "POST"). Empty string means "any method".
    public let method: String
    /// URL path pattern (e.g. "/users/list").
    public let path: String
    /// The command definition to execute.
    public let command: CommandDef
    /// Middleware to run around this command (includes parent group middleware).
    public let middleware: [MiddlewareFn]

    public init(method: String = "", path: String, command: CommandDef, middleware: [MiddlewareFn] = []) {
        self.method = method
        self.path = path
        self.command = command
        self.middleware = middleware
    }
}

/// Result of handling an HTTP request, ready for serialization.
public struct HttpResponse: Sendable {
    /// HTTP status code to return.
    public let statusCode: Int
    /// JSON response body.
    public let body: JSONValue

    public init(statusCode: Int, body: JSONValue) {
        self.statusCode = statusCode
        self.body = body
    }
}

// MARK: - Route Flattening

/// Flattens a command tree into a list of HTTP routes.
///
/// Walks the command entries recursively. Each leaf command becomes a route
/// at `/{prefix}/{name}`. Group middleware is accumulated and passed down
/// to child routes.
///
/// - Parameters:
///   - entries: The command entries to flatten.
///   - prefix: Path segments accumulated from parent groups.
///   - parentMiddleware: Middleware inherited from parent groups.
/// - Returns: An array of `HttpRoute` values.
public func flattenCommands(
    entries: [String: CommandEntry],
    prefix: [String] = [],
    parentMiddleware: [MiddlewareFn] = []
) -> [HttpRoute] {
    var routes: [HttpRoute] = []

    for (name, entry) in entries {
        let segments = prefix + [name]
        let path = "/" + segments.joined(separator: "/")

        switch entry {
        case .leaf(let def):
            let allMiddleware = parentMiddleware + def.middleware
            routes.append(HttpRoute(
                path: path,
                command: def,
                middleware: allMiddleware
            ))

        case .group(_, let subCommands, let groupMiddleware, _):
            let combinedMiddleware = parentMiddleware + groupMiddleware
            let subRoutes = flattenCommands(
                entries: subCommands,
                prefix: segments,
                parentMiddleware: combinedMiddleware
            )
            routes.append(contentsOf: subRoutes)

        case .fetchGateway:
            // Fetch gateways are not exposed as HTTP routes
            break
        }
    }

    return routes
}

// MARK: - Request Handling

/// Handles an HTTP request by executing the command associated with a route.
///
/// This function:
/// 1. Merges query parameters and body parameters into input options
/// 2. Executes the command via `execute()` with `ParseMode.split`
/// 3. Returns a structured JSON response with `ok`, `data`/`error`, and `meta`
///
/// For streaming commands, all chunks are buffered into an array.
///
/// - Parameters:
///   - route: The matched HTTP route.
///   - queryParams: Parsed query string parameters.
///   - bodyParams: Parsed request body parameters.
///   - envFields: CLI-level environment field definitions.
///   - envSource: Environment variable values (e.g. from `ProcessInfo`).
///   - cliName: The CLI application name.
///   - cliVersion: The CLI version string.
/// - Returns: An `HttpResponse` with status code and JSON body.
public func handleHttpRequest(
    route: HttpRoute,
    queryParams: OrderedMap,
    bodyParams: OrderedMap,
    envFields: [FieldMeta] = [],
    envSource: [String: String] = [:],
    cliName: String,
    cliVersion: String? = nil
) async -> HttpResponse {
    let start = ContinuousClock.now
    let commandPath = route.path
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .replacingOccurrences(of: "/", with: " ")

    // Merge query and body params (body takes precedence)
    var inputOptions = queryParams
    inputOptions.merge(bodyParams)

    let result = await execute(
        command: route.command,
        options: ExecuteOptions(
            agent: true,
            envFields: envFields,
            envSource: envSource,
            format: .json,
            formatExplicit: true,
            inputOptions: inputOptions,
            middlewares: route.middleware,
            name: cliName,
            parseMode: .split,
            path: commandPath,
            version: cliVersion
        )
    )

    let elapsed = ContinuousClock.now - start
    let durationMs = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    let duration = "\(durationMs)ms"

    switch result {
    case .ok(let data, let cta):
        var meta: OrderedMap = [
            "command": .string(commandPath),
            "duration": .string(duration),
        ]
        if let cta = cta {
            meta["cta"] = ctaToJson(cta)
        }

        let body: JSONValue = [
            "ok": true,
            "data": data,
            "meta": .object(meta),
        ]
        return HttpResponse(statusCode: 200, body: body)

    case .error(let code, let message, let retryable, _, let cta, _):
        let statusCode: Int
        if code == "VALIDATION_ERROR" {
            statusCode = 400
        } else {
            statusCode = 500
        }

        var errorObj: OrderedMap = [
            "code": .string(code),
            "message": .string(message),
        ]
        if let retryable = retryable {
            errorObj["retryable"] = .bool(retryable)
        }

        var meta: OrderedMap = [
            "command": .string(commandPath),
            "duration": .string(duration),
        ]
        if let cta = cta {
            meta["cta"] = ctaToJson(cta)
        }

        let body: JSONValue = [
            "ok": false,
            "error": .object(errorObj),
            "meta": .object(meta),
        ]
        return HttpResponse(statusCode: statusCode, body: body)

    case .stream(let stream):
        // Buffer all stream chunks into an array
        var chunks: [JSONValue] = []
        for await chunk in stream {
            chunks.append(chunk)
        }

        let meta: OrderedMap = [
            "command": .string(commandPath),
            "duration": .string(duration),
        ]

        let body: JSONValue = [
            "ok": true,
            "data": .array(chunks),
            "meta": .object(meta),
        ]
        return HttpResponse(statusCode: 200, body: body)
    }
}

// MARK: - Query String Parsing

/// Parses a URL query string into an `OrderedMap`.
///
/// Handles `key=value` pairs separated by `&`. Values are percent-decoded.
/// Duplicate keys are overwritten (last value wins).
///
/// - Parameter query: The raw query string (without the leading `?`).
/// - Returns: An `OrderedMap` of parsed key-value pairs.
public func parseQueryString(_ query: String) -> OrderedMap {
    var result = OrderedMap()
    guard !query.isEmpty else { return result }

    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
        let parts = pair.split(separator: "=", maxSplits: 1)
        let key = percentDecode(String(parts[0]))
        let value: String
        if parts.count > 1 {
            value = percentDecode(String(parts[1]))
        } else {
            value = ""
        }
        result[key] = .string(value)
    }

    return result
}

// MARK: - Internal Helpers

/// Simple percent-decoding for URL query values.
private func percentDecode(_ input: String) -> String {
    // Replace + with space first (form encoding)
    let plusDecoded = input.replacingOccurrences(of: "+", with: " ")
    // Use Foundation's built-in percent decoding
    return plusDecoded.removingPercentEncoding ?? plusDecoded
}

/// Converts a `CtaBlock` to a `JSONValue` for JSON response serialization.
private func ctaToJson(_ cta: CtaBlock) -> JSONValue {
    let commandEntries: [JSONValue] = cta.commands.map { entry in
        switch entry {
        case .simple(let s):
            return .string(s)
        case .detailed(let command, let description):
            var obj = OrderedMap()
            obj["command"] = .string(command)
            if let desc = description {
                obj["description"] = .string(desc)
            }
            return .object(obj)
        }
    }

    var obj = OrderedMap()
    obj["commands"] = .array(commandEntries)
    if let desc = cta.description {
        obj["description"] = .string(desc)
    }
    return .object(obj)
}
