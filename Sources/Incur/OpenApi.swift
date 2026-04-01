/// OpenAPI spec to command generation.
///
/// Parses an OpenAPI 3.x specification and generates command definitions
/// that can be registered with the incur CLI framework. Uses `JSONValue`
/// to walk the spec directly rather than depending on external OpenAPI
/// parsing packages.
///
/// Ported from `openapi.rs`.

import Foundation

// MARK: - Types

/// Options for OpenAPI command generation.
public struct GenerateOptions: Sendable {
    /// Base path prefix prepended to all operation paths.
    public let basePath: String?

    public init(basePath: String? = nil) {
        self.basePath = basePath
    }
}

/// The fetch function signature for OpenAPI-generated command handlers.
///
/// Parameters: (url, method, headers as key-value pairs, optional body)
/// Returns: a JSON value.
public typealias OpenApiFetchFn = @Sendable (
    _ url: String,
    _ method: String,
    _ headers: [(String, String)],
    _ body: String?
) async -> JSONValue

// MARK: - OpenAPI Handler

/// Command handler for OpenAPI-generated commands.
///
/// Stores enough information to interpolate path params, build the query
/// string, construct the request body, and call the user-provided fetch
/// function at runtime.
public struct OpenApiHandler: CommandHandler, Sendable {
    let fetchFn: OpenApiFetchFn
    let httpMethod: String
    let pathTemplate: String
    let basePath: String?
    let pathParamNames: [String]
    let queryParamNames: [String]
    let bodyPropNames: [String]

    public func run(_ ctx: CommandContext) async -> CommandResult {
        let argsMap = ctx.args.objectValue ?? OrderedMap()
        let optionsMap = ctx.options.objectValue ?? OrderedMap()

        // Interpolate path parameters
        var urlPath = "\(basePath ?? "")\(pathTemplate)"
        for paramName in pathParamNames {
            if let value = argsMap[paramName] {
                let strVal = valueToString(value)
                urlPath = urlPath.replacingOccurrences(of: "{\(paramName)}", with: strVal)
            }
        }

        // Build query string from query parameters
        var queryParts: [String] = []
        for paramName in queryParamNames {
            if let value = optionsMap[paramName], !value.isNull {
                let strVal = valueToString(value)
                queryParts.append("\(urlEncode(paramName))=\(urlEncode(strVal))")
            }
        }

        let fullUrl: String
        if queryParts.isEmpty {
            fullUrl = urlPath
        } else {
            fullUrl = "\(urlPath)?\(queryParts.joined(separator: "&"))"
        }

        // Build request body from body property names
        var headers: [(String, String)] = []
        let body: String?
        if !bodyPropNames.isEmpty {
            var bodyObj = OrderedMap()
            for key in bodyPropNames {
                if let value = optionsMap[key], !value.isNull {
                    bodyObj[key] = value
                }
            }
            if bodyObj.isEmpty {
                body = nil
            } else {
                headers.append(("content-type", "application/json"))
                body = JSONValue.object(bodyObj).toJSON(pretty: false)
            }
        } else {
            body = nil
        }

        let result = await fetchFn(fullUrl, httpMethod, headers, body)

        // Check for error responses
        if let obj = result.objectValue {
            if obj["ok"] == .bool(false) {
                let message = obj["message"]?.stringValue
                    ?? obj["error"]?.stringValue
                    ?? "Request failed"
                let code: String
                if let status = obj["status"]?.intValue {
                    code = "HTTP_\(status)"
                } else {
                    code = "HTTP_ERROR"
                }
                return .error(code: code, message: message, retryable: false, exitCode: 1)
            }
        }

        return .ok(data: result)
    }
}

// MARK: - Public API

/// Generates incur `CommandDef`s from an OpenAPI 3.x spec.
///
/// Walks the `paths` object, extracting each method/operation and creating a
/// command for it. Path parameters become positional args, query parameters
/// and request body properties become options.
///
/// Each generated command's handler constructs an HTTP request and calls the
/// provided `fetchFn` to execute it.
public func generateCommands(
    spec: JSONValue,
    fetchFn: @escaping OpenApiFetchFn,
    options: GenerateOptions = GenerateOptions()
) -> [String: CommandEntry] {
    let resolved = resolveRefs(value: spec, root: spec)
    guard let paths = resolved["paths"]?.objectValue else {
        return [:]
    }

    let httpMethods: Set<String> = [
        "get", "post", "put", "patch", "delete", "head", "options", "trace",
    ]

    var commands: [String: CommandEntry] = [:]

    for (path, methodsVal) in paths {
        guard let methods = methodsVal.objectValue else { continue }

        for (method, operationVal) in methods {
            if method.hasPrefix("x-") { continue }
            if !httpMethods.contains(method) { continue }
            guard let op = operationVal.objectValue else { continue }

            // Determine command name
            let name: String
            if let operationId = op["operationId"]?.stringValue {
                name = operationId
            } else {
                name = generateOperationName(method: method, path: path)
            }

            let httpMethod = method.uppercased()
            let description = op["summary"]?.stringValue
                ?? op["description"]?.stringValue

            // Extract parameters
            let parameters = op["parameters"]?.arrayValue ?? []

            let pathParams = parameters.filter { p in
                p["in"]?.stringValue == "path"
            }

            let queryParams = parameters.filter { p in
                p["in"]?.stringValue == "query"
            }

            // Extract body schema
            let (bodyProps, bodyRequiredSet) = extractBodySchema(operation: operationVal)

            // Build args fields from path params
            let argsFields: [FieldMeta] = pathParams.compactMap { p in
                paramToFieldMeta(param: p, isRequired: true)
            }

            // Build options fields from query params + body props
            var optionsFields: [FieldMeta] = []

            for p in queryParams {
                let required = p["required"]?.boolValue ?? false
                if let field = paramToFieldMeta(param: p, isRequired: required) {
                    optionsFields.append(field)
                }
            }

            for (key, schema) in bodyProps {
                let required = bodyRequiredSet.contains(key)
                optionsFields.append(bodyPropToFieldMeta(key: key, schema: schema, isRequired: required))
            }

            // Build handler
            let pathParamNames: [String] = pathParams.compactMap { p in
                p["name"]?.stringValue
            }
            let queryParamNames: [String] = queryParams.compactMap { p in
                p["name"]?.stringValue
            }
            let bodyPropNames: [String] = bodyProps.map { $0.0 }

            let handler = OpenApiHandler(
                fetchFn: fetchFn,
                httpMethod: httpMethod,
                pathTemplate: path,
                basePath: options.basePath,
                pathParamNames: pathParamNames,
                queryParamNames: queryParamNames,
                bodyPropNames: bodyPropNames
            )

            let cmdDef = CommandDef(
                name: name,
                description: description,
                argsFields: argsFields,
                optionsFields: optionsFields,
                handler: handler
            )

            commands[name] = .leaf(cmdDef)
        }
    }

    return commands
}

// MARK: - URL Encoding

/// Percent-encodes a string for use in URLs.
///
/// Encodes all characters except unreserved characters (A-Z, a-z, 0-9, -, _, ., ~)
/// as defined in RFC 3986.
public func urlEncode(_ input: String) -> String {
    var encoded = ""
    encoded.reserveCapacity(input.count)
    let hexUpper: [Character] = Array("0123456789ABCDEF")
    for byte in input.utf8 {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "_"),
             UInt8(ascii: "."), UInt8(ascii: "~"):
            encoded.append(Character(UnicodeScalar(byte)))
        default:
            encoded.append("%")
            encoded.append(hexUpper[Int(byte >> 4)])
            encoded.append(hexUpper[Int(byte & 0x0F)])
        }
    }
    return encoded
}

// MARK: - Internal Helpers

/// Converts a JSONValue to its string representation for URL interpolation.
func valueToString(_ value: JSONValue) -> String {
    switch value {
    case .string(let s): return s
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .bool(let b): return b ? "true" : "false"
    case .null: return ""
    default: return value.toJSON(pretty: false)
    }
}

/// Generates an operation name from an HTTP method and path.
///
/// Replaces `/`, `{`, and `}` with underscores and prepends the method.
/// For example: `("get", "/users/{id}")` -> `"get__users__id_"`
public func generateOperationName(method: String, path: String) -> String {
    let sanitized = path.map { ch -> Character in
        switch ch {
        case "/", "{", "}": return "_"
        default: return ch
        }
    }
    return "\(method)_\(String(sanitized))"
}

/// Maps a JSON Schema type to a `FieldType`.
public func schemaTypeToFieldType(schema: JSONValue?) -> FieldType {
    guard let schema = schema else { return .string }

    guard let typeName = schema["type"]?.stringValue else {
        return .string
    }

    switch typeName {
    case "integer", "number":
        return .number
    case "boolean":
        return .boolean
    case "array":
        let itemsType = schema["items"]?["type"]?.stringValue
        let inner: FieldType
        switch itemsType {
        case "integer", "number":
            inner = .number
        case "boolean":
            inner = .boolean
        default:
            inner = .string
        }
        return .array(inner)
    default:
        return .string
    }
}

/// Converts an OpenAPI parameter object to a `FieldMeta`.
public func paramToFieldMeta(param: JSONValue, isRequired: Bool) -> FieldMeta? {
    guard let name = param["name"]?.stringValue else { return nil }
    let description = param["description"]?.stringValue
    let schema = param["schema"]
    let fieldType = schemaTypeToFieldType(schema: schema)

    return FieldMeta(
        name: name,
        description: description,
        fieldType: fieldType,
        required: isRequired
    )
}

/// Converts a request body property to a `FieldMeta`.
public func bodyPropToFieldMeta(key: String, schema: JSONValue, isRequired: Bool) -> FieldMeta {
    let description = schema["description"]?.stringValue
    let fieldType = schemaTypeToFieldType(schema: schema)

    return FieldMeta(
        name: key,
        description: description,
        fieldType: fieldType,
        required: isRequired
    )
}

/// Extracts body schema properties and required fields from an operation.
///
/// Looks at `requestBody.content["application/json"].schema.properties`
/// and returns a tuple of (properties as key-value pairs, required field names).
public func extractBodySchema(operation: JSONValue) -> ([(String, JSONValue)], Set<String>) {
    guard let body = operation["requestBody"]?.objectValue else {
        return ([], [])
    }
    guard let content = body["content"]?.objectValue else {
        return ([], [])
    }
    guard let jsonContent = content["application/json"]?.objectValue else {
        return ([], [])
    }
    guard let schema = jsonContent["schema"]?.objectValue else {
        return ([], [])
    }
    guard let properties = schema["properties"]?.objectValue else {
        return ([], [])
    }

    let requiredSet: Set<String>
    if let requiredArr = schema["required"]?.arrayValue {
        requiredSet = Set(requiredArr.compactMap { $0.stringValue })
    } else {
        requiredSet = []
    }

    let props: [(String, JSONValue)] = properties.map { ($0, $1) }
    return (props, requiredSet)
}

/// Resolves `$ref` pointers in a JSON value recursively.
///
/// When a JSON object contains a `$ref` key, the value is replaced with the
/// referenced value from the root document. This is done recursively so that
/// nested references are also resolved.
public func resolveRefs(value: JSONValue, root: JSONValue) -> JSONValue {
    switch value {
    case .object(let map):
        // Check for $ref
        if let refStr = map["$ref"]?.stringValue {
            if let resolved = resolveJsonPointer(root: root, pointer: refStr) {
                return resolveRefs(value: resolved, root: root)
            }
        }
        // Recursively resolve all values in the object
        var newMap = OrderedMap()
        for (k, v) in map {
            newMap[k] = resolveRefs(value: v, root: root)
        }
        return .object(newMap)

    case .array(let arr):
        return .array(arr.map { resolveRefs(value: $0, root: root) })

    default:
        return value
    }
}

/// Navigates a JSON Pointer path (e.g. `#/components/schemas/User`).
///
/// Strips the leading `#/` prefix, splits on `/`, and walks the root
/// document. Returns `nil` if any segment is not found.
public func resolveJsonPointer(root: JSONValue, pointer: String) -> JSONValue? {
    guard pointer.hasPrefix("#/") else { return nil }
    let path = pointer.dropFirst(2)
    var current = root
    for segment in path.split(separator: "/") {
        // JSON Pointer escaping: ~1 -> /, ~0 -> ~
        let decoded = segment
            .replacingOccurrences(of: "~1", with: "/")
            .replacingOccurrences(of: "~0", with: "~")
        guard let next = current[decoded] else { return nil }
        current = next
    }
    return current
}
