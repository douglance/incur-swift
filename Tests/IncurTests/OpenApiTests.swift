import Foundation
import Testing
@testable import Incur

// MARK: - Thread-safe capture box for tests

/// A simple thread-safe box for capturing values in `@Sendable` closures.
private final class CaptureBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) {
        _value = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _value = newValue
        }
    }
}

// MARK: - OpenAPI Tests

@Suite("OpenApi")
struct OpenApiTests {

    // MARK: - generateOperationName

    @Test func testGenerateOperationName() {
        #expect(generateOperationName(method: "get", path: "/users") == "get__users")
        #expect(
            generateOperationName(method: "post", path: "/users/{id}")
                == "post__users__id_"
        )
        #expect(
            generateOperationName(method: "delete", path: "/users/{userId}/posts/{postId}")
                == "delete__users__userId__posts__postId_"
        )
        #expect(generateOperationName(method: "get", path: "/") == "get__")
    }

    // MARK: - schemaTypeToFieldType

    @Test func testSchemaTypeToFieldType() {
        #expect(schemaTypeToFieldType(schema: .object(["type": "string"])) == .string)
        #expect(schemaTypeToFieldType(schema: .object(["type": "number"])) == .number)
        #expect(schemaTypeToFieldType(schema: .object(["type": "integer"])) == .number)
        #expect(schemaTypeToFieldType(schema: .object(["type": "boolean"])) == .boolean)
        #expect(schemaTypeToFieldType(schema: nil) == .string)
        // Array with items
        let arraySchema: JSONValue = [
            "type": "array",
            "items": ["type": "number"],
        ]
        #expect(schemaTypeToFieldType(schema: arraySchema) == .array(.number))
        // Array with string items (default)
        let arrayStringSchema: JSONValue = [
            "type": "array",
            "items": ["type": "string"],
        ]
        #expect(schemaTypeToFieldType(schema: arrayStringSchema) == .array(.string))
        // Array with boolean items
        let arrayBoolSchema: JSONValue = [
            "type": "array",
            "items": ["type": "boolean"],
        ]
        #expect(schemaTypeToFieldType(schema: arrayBoolSchema) == .array(.boolean))
    }

    // MARK: - resolveRefs

    @Test func testResolveRefs() {
        let spec: JSONValue = [
            "components": [
                "schemas": [
                    "User": [
                        "type": "object",
                        "properties": ["name": ["type": "string"]],
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
            "paths": [
                "/users": [
                    "get": [
                        "responses": [
                            "200": [
                                "content": [
                                    "application/json": [
                                        "schema": ["$ref": "#/components/schemas/User"],
                                    ] as JSONValue,
                                ] as JSONValue,
                            ] as JSONValue,
                        ] as JSONValue,
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
        ]

        let resolved = resolveRefs(value: spec, root: spec)

        // The $ref should be replaced with the actual schema
        let schema = resolved["paths"]?["/users"]?["get"]?["responses"]?["200"]?["content"]?["application/json"]?["schema"]
        #expect(schema != nil)
        #expect(schema?["type"]?.stringValue == "object")
        #expect(schema?["properties"]?["name"]?["type"]?.stringValue == "string")
    }

    // MARK: - resolveJsonPointer

    @Test func testResolveJsonPointer() {
        let root: JSONValue = [
            "components": [
                "schemas": [
                    "User": ["type": "object"],
                ] as JSONValue,
            ] as JSONValue,
        ]

        let result = resolveJsonPointer(root: root, pointer: "#/components/schemas/User")
        #expect(result != nil)
        #expect(result?["type"]?.stringValue == "object")

        // Non-existent path returns nil
        let missing = resolveJsonPointer(root: root, pointer: "#/nonexistent/path")
        #expect(missing == nil)

        // Invalid pointer format returns nil
        let invalid = resolveJsonPointer(root: root, pointer: "no-hash-prefix")
        #expect(invalid == nil)
    }

    // MARK: - paramToFieldMeta

    @Test func testParamToFieldMeta() {
        let param: JSONValue = [
            "name": "userId",
            "in": "path",
            "required": true,
            "schema": ["type": "integer"],
            "description": "The user ID",
        ]

        let field = paramToFieldMeta(param: param, isRequired: true)
        #expect(field != nil)
        #expect(field?.name == "userId")
        #expect(field?.fieldType == .number)
        #expect(field?.required == true)
        #expect(field?.description == "The user ID")
    }

    @Test func testParamToFieldMetaNoName() {
        let param: JSONValue = [
            "in": "query",
            "schema": ["type": "string"],
        ]
        let field = paramToFieldMeta(param: param, isRequired: false)
        #expect(field == nil)
    }

    // MARK: - urlEncode

    @Test func testUrlEncoding() {
        #expect(urlEncode("hello world") == "hello%20world")
        #expect(urlEncode("a=b&c=d") == "a%3Db%26c%3Dd")
        #expect(urlEncode("simple") == "simple")
        #expect(urlEncode("foo-bar_baz.qux~") == "foo-bar_baz.qux~")
        #expect(urlEncode("") == "")
    }

    // MARK: - extractBodySchema

    @Test func testExtractBodySchema() {
        let operation: JSONValue = [
            "requestBody": [
                "content": [
                    "application/json": [
                        "schema": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string"],
                                "age": ["type": "integer"],
                            ] as JSONValue,
                            "required": ["name"],
                        ] as JSONValue,
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
        ]

        let (props, required) = extractBodySchema(operation: operation)
        #expect(props.count == 2)
        #expect(required.contains("name"))
        #expect(!required.contains("age"))

        // Verify property names exist (order may vary with OrderedMap)
        let propNames = Set(props.map { $0.0 })
        #expect(propNames.contains("name"))
        #expect(propNames.contains("age"))
    }

    @Test func testExtractBodySchemaNoBody() {
        let operation: JSONValue = [
            "summary": "No body",
        ]
        let (props, required) = extractBodySchema(operation: operation)
        #expect(props.isEmpty)
        #expect(required.isEmpty)
    }

    // MARK: - generateCommands from spec

    @Test func testGenerateCommandsFromSpec() {
        let spec: JSONValue = [
            "openapi": "3.0.0",
            "info": ["title": "Test", "version": "1.0.0"],
            "paths": [
                "/users": [
                    "get": [
                        "operationId": "listUsers",
                        "summary": "List users",
                        "parameters": [
                            [
                                "name": "limit",
                                "in": "query",
                                "schema": ["type": "number"],
                                "description": "Max results",
                            ] as JSONValue,
                        ] as JSONValue,
                    ] as JSONValue,
                    "post": [
                        "operationId": "createUser",
                        "summary": "Create a user",
                        "requestBody": [
                            "required": true,
                            "content": [
                                "application/json": [
                                    "schema": [
                                        "type": "object",
                                        "properties": ["name": ["type": "string"]],
                                        "required": ["name"],
                                    ] as JSONValue,
                                ] as JSONValue,
                            ] as JSONValue,
                        ] as JSONValue,
                    ] as JSONValue,
                ] as JSONValue,
                "/users/{id}": [
                    "get": [
                        "operationId": "getUser",
                        "summary": "Get a user by ID",
                        "parameters": [
                            [
                                "name": "id",
                                "in": "path",
                                "required": true,
                                "schema": ["type": "number"],
                                "description": "User ID",
                            ] as JSONValue,
                        ] as JSONValue,
                    ] as JSONValue,
                    "delete": [
                        "operationId": "deleteUser",
                        "summary": "Delete a user",
                        "parameters": [
                            [
                                "name": "id",
                                "in": "path",
                                "required": true,
                                "schema": ["type": "number"],
                            ] as JSONValue,
                        ] as JSONValue,
                    ] as JSONValue,
                ] as JSONValue,
                "/health": [
                    "get": [
                        "operationId": "healthCheck",
                        "summary": "Health check",
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
        ]

        let fetchFn: OpenApiFetchFn = { _, _, _, _ in
            .object(["ok": true])
        }

        let commands = generateCommands(spec: spec, fetchFn: fetchFn)

        #expect(commands["listUsers"] != nil)
        #expect(commands["createUser"] != nil)
        #expect(commands["getUser"] != nil)
        #expect(commands["deleteUser"] != nil)
        #expect(commands["healthCheck"] != nil)

        // Check listUsers details
        if case .leaf(let listUsers) = commands["listUsers"] {
            #expect(listUsers.description == "List users")
            #expect(listUsers.argsFields.isEmpty)
            #expect(listUsers.optionsFields.count == 1)
            #expect(listUsers.optionsFields[0].name == "limit")
        } else {
            Issue.record("listUsers should be a leaf command")
        }

        // Check getUser details
        if case .leaf(let getUser) = commands["getUser"] {
            #expect(getUser.argsFields.count == 1)
            #expect(getUser.argsFields[0].name == "id")
            #expect(getUser.argsFields[0].fieldType == .number)
            #expect(getUser.argsFields[0].required)
        } else {
            Issue.record("getUser should be a leaf command")
        }

        // Check createUser details
        if case .leaf(let createUser) = commands["createUser"] {
            #expect(createUser.argsFields.isEmpty)
            #expect(createUser.optionsFields.count == 1)
            #expect(createUser.optionsFields[0].name == "name")
            #expect(createUser.optionsFields[0].required)
        } else {
            Issue.record("createUser should be a leaf command")
        }
    }

    @Test func testGenerateCommandsNoOperationId() {
        let spec: JSONValue = [
            "openapi": "3.0.0",
            "info": ["title": "Test", "version": "1.0.0"],
            "paths": [
                "/items": [
                    "get": [
                        "summary": "List items",
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
        ]

        let fetchFn: OpenApiFetchFn = { _, _, _, _ in .null }
        let commands = generateCommands(spec: spec, fetchFn: fetchFn)

        // Should generate a name from method + path
        #expect(commands["get__items"] != nil)
    }

    @Test func testGenerateCommandsEmptySpec() {
        let spec: JSONValue = [
            "openapi": "3.0.0",
            "info": ["title": "Test", "version": "1.0.0"],
        ]

        let fetchFn: OpenApiFetchFn = { _, _, _, _ in .null }
        let commands = generateCommands(spec: spec, fetchFn: fetchFn)
        #expect(commands.isEmpty)
    }

    @Test func testGenerateCommandsSkipsExtensions() {
        let spec: JSONValue = [
            "openapi": "3.0.0",
            "info": ["title": "Test", "version": "1.0.0"],
            "paths": [
                "/items": [
                    "get": [
                        "operationId": "listItems",
                        "summary": "List items",
                    ] as JSONValue,
                    "x-custom-extension": ["some": "data"],
                ] as JSONValue,
            ] as JSONValue,
        ]

        let fetchFn: OpenApiFetchFn = { _, _, _, _ in .null }
        let commands = generateCommands(spec: spec, fetchFn: fetchFn)

        // Should have listItems but not x-custom-extension
        #expect(commands["listItems"] != nil)
        #expect(commands.count == 1)
    }

    @Test func testGenerateCommandsWithBasePath() async {
        let spec: JSONValue = [
            "openapi": "3.0.0",
            "info": ["title": "Test", "version": "1.0.0"],
            "paths": [
                "/users": [
                    "get": [
                        "operationId": "listUsers",
                        "summary": "List users",
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
        ]

        let captured = CaptureBox("")
        let fetchFn: OpenApiFetchFn = { url, _, _, _ in
            captured.value = url
            return .object(["ok": true])
        }

        let commands = generateCommands(
            spec: spec,
            fetchFn: fetchFn,
            options: GenerateOptions(basePath: "/api/v1")
        )

        if case .leaf(let cmd) = commands["listUsers"] {
            let ctx = CommandContext(args: .null, options: .null)
            _ = await cmd.handler.run(ctx)
            #expect(captured.value == "/api/v1/users")
        } else {
            Issue.record("listUsers should be a leaf command")
        }
    }

    // MARK: - Handler tests

    @Test func testHandlerPathParamInterpolation() async {
        let spec: JSONValue = [
            "openapi": "3.0.0",
            "info": ["title": "Test", "version": "1.0.0"],
            "paths": [
                "/users/{id}": [
                    "get": [
                        "operationId": "getUser",
                        "parameters": [
                            [
                                "name": "id",
                                "in": "path",
                                "required": true,
                                "schema": ["type": "number"],
                            ] as JSONValue,
                        ] as JSONValue,
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
        ]

        let captured = CaptureBox("")
        let fetchFn: OpenApiFetchFn = { url, _, _, _ in
            captured.value = url
            return .object(["id": 42, "name": "Alice"])
        }

        let commands = generateCommands(spec: spec, fetchFn: fetchFn)

        if case .leaf(let cmd) = commands["getUser"] {
            let ctx = CommandContext(
                args: ["id": 42],
                options: .null
            )
            _ = await cmd.handler.run(ctx)
            #expect(captured.value == "/users/42")
        } else {
            Issue.record("getUser should be a leaf command")
        }
    }

    @Test func testHandlerQueryParams() async {
        let spec: JSONValue = [
            "openapi": "3.0.0",
            "info": ["title": "Test", "version": "1.0.0"],
            "paths": [
                "/users": [
                    "get": [
                        "operationId": "listUsers",
                        "parameters": [
                            [
                                "name": "limit",
                                "in": "query",
                                "schema": ["type": "number"],
                            ] as JSONValue,
                        ] as JSONValue,
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
        ]

        let captured = CaptureBox("")
        let fetchFn: OpenApiFetchFn = { url, _, _, _ in
            captured.value = url
            return .object(["ok": true])
        }

        let commands = generateCommands(spec: spec, fetchFn: fetchFn)

        if case .leaf(let cmd) = commands["listUsers"] {
            let ctx = CommandContext(
                args: .null,
                options: ["limit": 5]
            )
            _ = await cmd.handler.run(ctx)
            #expect(captured.value == "/users?limit=5")
        } else {
            Issue.record("listUsers should be a leaf command")
        }
    }

    @Test func testHandlerBodyParams() async {
        let spec: JSONValue = [
            "openapi": "3.0.0",
            "info": ["title": "Test", "version": "1.0.0"],
            "paths": [
                "/users": [
                    "post": [
                        "operationId": "createUser",
                        "requestBody": [
                            "content": [
                                "application/json": [
                                    "schema": [
                                        "type": "object",
                                        "properties": ["name": ["type": "string"]],
                                        "required": ["name"],
                                    ] as JSONValue,
                                ] as JSONValue,
                            ] as JSONValue,
                        ] as JSONValue,
                    ] as JSONValue,
                ] as JSONValue,
            ] as JSONValue,
        ]

        let captured = CaptureBox<String?>(nil)
        let fetchFn: OpenApiFetchFn = { _, _, _, body in
            captured.value = body
            return .object(["created": true, "name": "Bob"])
        }

        let commands = generateCommands(spec: spec, fetchFn: fetchFn)

        if case .leaf(let cmd) = commands["createUser"] {
            let ctx = CommandContext(
                args: .null,
                options: ["name": "Bob"]
            )
            _ = await cmd.handler.run(ctx)
            #expect(captured.value != nil)
            if let body = captured.value, let parsed = JSONValue.parse(body) {
                #expect(parsed["name"]?.stringValue == "Bob")
            } else {
                Issue.record("Body should be valid JSON")
            }
        } else {
            Issue.record("createUser should be a leaf command")
        }
    }

    @Test func testHandlerErrorResponse() async {
        let handler = OpenApiHandler(
            fetchFn: { _, _, _, _ in
                return .object([
                    "ok": false,
                    "message": "Not found",
                    "status": 404,
                ])
            },
            httpMethod: "GET",
            pathTemplate: "/users/{id}",
            basePath: nil,
            pathParamNames: ["id"],
            queryParamNames: [],
            bodyPropNames: []
        )

        let ctx = CommandContext(
            args: ["id": 999],
            options: .null
        )

        let result = await handler.run(ctx)
        if case .error(let code, let message, _, _, _) = result {
            #expect(code == "HTTP_404")
            #expect(message == "Not found")
        } else {
            Issue.record("Expected error result")
        }
    }

    // MARK: - bodyPropToFieldMeta

    @Test func testBodyPropToFieldMeta() {
        let schema: JSONValue = [
            "type": "string",
            "description": "The user's name",
        ]
        let field = bodyPropToFieldMeta(key: "userName", schema: schema, isRequired: true)
        #expect(field.name == "userName")
        #expect(field.cliName == "user-name")
        #expect(field.fieldType == .string)
        #expect(field.required)
        #expect(field.description == "The user's name")
    }

    // MARK: - valueToString

    @Test func testValueToString() {
        #expect(valueToString(.string("hello")) == "hello")
        #expect(valueToString(.int(42)) == "42")
        #expect(valueToString(.bool(true)) == "true")
        #expect(valueToString(.null) == "")
    }
}
