/// MCP (Model Context Protocol) tool collection and stdio server.
///
/// Ported from `mcp.rs`. Exposes CLI commands as MCP tools over a stdio
/// transport using the official MCP Swift SDK.
///
/// Split into two parts:
/// - Part A: Tool collection types (always available, no dependency on MCP SDK)
/// - Part B: MCP stdio server (uses the MCP Swift SDK for protocol handling)

import Foundation
import MCP

// MARK: - Part A: Tool Collection Types

/// A resolved tool entry from the command tree.
public struct McpToolEntry: Sendable {
    /// Tool name (path segments joined with `_`).
    public let name: String
    /// Human-readable description.
    public let description: String?
    /// Merged JSON Schema for the tool's input.
    public let inputSchema: JSONValue

    public init(name: String, description: String? = nil, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Tool Collection

/// Recursively collects leaf commands as MCP tool entries.
///
/// Groups are traversed but not emitted as tools -- only leaf commands become
/// tools. Fetch gateways are skipped entirely. Tool names use underscore-joined
/// path segments (e.g. `deploy_app`).
///
/// The returned array is sorted by tool name.
public func collectMcpTools(
    commands: [String: CommandEntry],
    prefix: [String] = []
) -> [McpToolEntry] {
    var result: [McpToolEntry] = []

    for name in commands.keys.sorted() {
        guard let entry = commands[name] else { continue }
        var path = prefix
        path.append(name)

        switch entry {
        case .leaf(let def):
            let toolName = path.joined(separator: "_")
            let inputSchema = buildToolSchema(
                argsFields: def.argsFields,
                optionsFields: def.optionsFields
            )
            result.append(McpToolEntry(
                name: toolName,
                description: def.description,
                inputSchema: inputSchema
            ))

        case .group(_, let subcommands, _, _):
            result.append(contentsOf: collectMcpTools(
                commands: subcommands,
                prefix: path
            ))

        case .fetchGateway:
            // Fetch gateways are not exposed as MCP tools.
            break
        }
    }

    result.sort { $0.name < $1.name }
    return result
}

// MARK: - Schema Building

/// Builds a merged JSON Schema from args and options field metadata.
///
/// Creates a JSON Schema object with `"type": "object"`, `"properties"`,
/// and optionally `"required"` (only present when there are required fields).
public func buildToolSchema(
    argsFields: [FieldMeta],
    optionsFields: [FieldMeta]
) -> JSONValue {
    var properties = OrderedMap()
    var required: [String] = []

    for field in argsFields + optionsFields {
        var prop = OrderedMap()
        prop["type"] = .string(fieldTypeToJsonSchemaType(field.fieldType))

        if let desc = field.description {
            prop["description"] = .string(desc)
        }
        if let defaultValue = field.defaultValue {
            prop["default"] = defaultValue
        }

        // For enum types, add the enum values
        if case .enum(let values) = field.fieldType {
            prop["enum"] = .array(values.map { .string($0) })
        }

        properties[field.name] = .object(prop)

        if field.required {
            required.append(field.name)
        }
    }

    var schema = OrderedMap()
    schema["type"] = .string("object")
    schema["properties"] = .object(properties)

    if !required.isEmpty {
        schema["required"] = .array(required.map { .string($0) })
    }

    return .object(schema)
}

/// Maps a FieldType to its JSON Schema type string.
public func fieldTypeToJsonSchemaType(_ fieldType: FieldType) -> String {
    switch fieldType {
    case .string: return "string"
    case .number: return "number"
    case .boolean: return "boolean"
    case .array: return "array"
    case .enum: return "string"
    case .count: return "integer"
    case .value: return "string"
    }
}

// MARK: - Part B: MCP Stdio Server

/// Converts a JSONValue to an MCP SDK Value.
private func jsonValueToMcpValue(_ jsonValue: JSONValue) -> MCP.Value {
    switch jsonValue {
    case .null:
        return .null
    case .bool(let b):
        return .bool(b)
    case .int(let i):
        return .int(i)
    case .double(let d):
        return .double(d)
    case .string(let s):
        return .string(s)
    case .array(let arr):
        return .array(arr.map { jsonValueToMcpValue($0) })
    case .object(let map):
        var dict: [String: MCP.Value] = [:]
        for (key, val) in map {
            dict[key] = jsonValueToMcpValue(val)
        }
        return .object(dict)
    }
}

/// Converts MCP SDK Value arguments to an OrderedMap for command execution.
private func mcpArgsToOrderedMap(_ args: [String: MCP.Value]?) -> OrderedMap {
    guard let args else { return OrderedMap() }
    var map = OrderedMap()
    for (key, value) in args {
        map[key] = mcpValueToJsonValue(value)
    }
    return map
}

/// Converts an MCP SDK Value to a JSONValue.
private func mcpValueToJsonValue(_ value: MCP.Value) -> JSONValue {
    switch value {
    case .null:
        return .null
    case .bool(let b):
        return .bool(b)
    case .int(let i):
        return .int(i)
    case .double(let d):
        return .double(d)
    case .string(let s):
        return .string(s)
    case .data(_, let data):
        // Encode data as base64 string
        return .string(data.base64EncodedString())
    case .array(let arr):
        return .array(arr.map { mcpValueToJsonValue($0) })
    case .object(let dict):
        var map = OrderedMap()
        for (key, val) in dict {
            map[key] = mcpValueToJsonValue(val)
        }
        return .object(map)
    }
}

/// A resolved tool with both metadata and the `CommandDef` needed for execution.
private struct ResolvedTool: Sendable {
    let name: String
    let description: String
    let inputSchema: MCP.Value
    let command: CommandDef
    let middleware: [MiddlewareFn]
}

/// Recursively collects leaf commands from the CLI command tree,
/// preserving `CommandDef` references for execution and inheriting
/// group middleware.
private func collectResolvedTools(
    commands: [String: CommandEntry],
    prefix: [String],
    parentMiddleware: [MiddlewareFn]
) -> [ResolvedTool] {
    var result: [ResolvedTool] = []

    for name in commands.keys.sorted() {
        guard let entry = commands[name] else { continue }
        var path = prefix
        path.append(name)

        switch entry {
        case .leaf(let def):
            let toolName = path.joined(separator: "_")
            let schema = buildToolSchema(argsFields: def.argsFields, optionsFields: def.optionsFields)
            let mcpSchema = jsonValueToMcpValue(schema)
            result.append(ResolvedTool(
                name: toolName,
                description: def.description ?? "",
                inputSchema: mcpSchema,
                command: def,
                middleware: parentMiddleware
            ))

        case .group(_, let subcommands, let middleware, _):
            var mergedMw = parentMiddleware
            mergedMw.append(contentsOf: middleware)
            result.append(contentsOf: collectResolvedTools(
                commands: subcommands,
                prefix: path,
                parentMiddleware: mergedMw
            ))

        case .fetchGateway:
            // Fetch gateways are not exposed as MCP tools.
            break
        }
    }

    result.sort { $0.name < $1.name }
    return result
}

/// Starts a stdio MCP server that exposes CLI commands as tools.
///
/// This function:
/// 1. Walks the CLI command tree to collect leaf commands as tools.
/// 2. Creates an MCP `Server` using the official Swift SDK.
/// 3. Registers `tools/list` and `tools/call` handlers.
/// 4. Connects via stdio transport (stdin/stdout).
/// 5. Blocks until the client disconnects.
///
/// Each tool call executes the corresponding command via
/// `execute()` with `ParseMode.flat` and `Format.json`.
public func serveMcp(
    name: String,
    version: String,
    commands: [String: CommandEntry],
    middleware: [MiddlewareFn] = [],
    envFields: [FieldMeta] = [],
    envSource: [String: String] = ProcessInfo.processInfo.environment
) async throws {
    let resolvedTools = collectResolvedTools(
        commands: commands,
        prefix: [],
        parentMiddleware: []
    )

    // Build the MCP Tool list for tools/list responses
    let toolList: [Tool] = resolvedTools.map { tool in
        Tool(
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema
        )
    }

    // Index tools by name for O(1) lookup during tools/call
    var toolsByName: [String: ResolvedTool] = [:]
    for tool in resolvedTools {
        toolsByName[tool.name] = tool
    }

    // Make these Sendable by capturing them in a final class wrapper
    let toolIndex = SendableToolIndex(toolsByName: toolsByName)

    let server = Server(
        name: name,
        version: version,
        capabilities: .init(tools: .init())
    )

    // Register tools/list handler
    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: toolList)
    }

    // Register tools/call handler
    await server.withMethodHandler(CallTool.self) { params in
        let toolName = params.name
        guard let tool = toolIndex.toolsByName[toolName] else {
            throw MCPError.invalidParams("Unknown tool: \(toolName)")
        }

        // Convert arguments to OrderedMap
        let inputOptions = mcpArgsToOrderedMap(params.arguments)

        // Collect all middleware: root + group + command
        var allMiddleware = middleware
        allMiddleware.append(contentsOf: tool.middleware)
        allMiddleware.append(contentsOf: tool.command.middleware)

        let result = await execute(
            command: tool.command,
            options: ExecuteOptions(
                agent: true,
                envFields: envFields,
                envSource: envSource,
                format: .json,
                formatExplicit: true,
                inputOptions: inputOptions,
                middlewares: allMiddleware,
                name: name,
                parseMode: .flat,
                path: toolName,
                version: version
            )
        )

        switch result {
        case .ok(let data, _):
            let text = data.toJSON(pretty: false)
            return CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)]
            )

        case .error(_, let message, _, _, _, _):
            let text = message.isEmpty ? "Command failed" : message
            return CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)],
                isError: true
            )

        case .stream(let stream):
            // Buffer all stream chunks, then return the collected result.
            var chunks: [JSONValue] = []
            for await item in stream {
                chunks.append(item)
            }
            let text = JSONValue.array(chunks).toJSON(pretty: false)
            return CallTool.Result(
                content: [.text(text: text, annotations: nil, _meta: nil)]
            )
        }
    }

    // Start the server with stdio transport
    let transport = StdioTransport()
    try await server.start(transport: transport)

    // Block until the server task completes (client disconnects)
    await server.waitUntilCompleted()
}

/// Thread-safe wrapper for the tool index to satisfy Sendable requirements.
private final class SendableToolIndex: @unchecked Sendable {
    let toolsByName: [String: ResolvedTool]

    init(toolsByName: [String: ResolvedTool]) {
        self.toolsByName = toolsByName
    }
}
