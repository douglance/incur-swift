import Foundation
import Testing
@testable import Incur

/// Thread-safe captureBox for fetchFn callbacks.
private final class GatewayBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        get {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _value = newValue
        }
    }
}

@Suite("OpenApiGateway")
struct OpenApiGatewayTests {

    // A small handcrafted OpenAPI 3.x spec with three paths and mixed methods.
    private var sampleSpec: JSONValue {
        return [
            "openapi": "3.0.0",
            "info": ["title": "Sample", "version": "1.0.0"],
            "paths": [
                "/users": [
                    "get": [
                        "operationId": "listUsers",
                        "summary": "List all users",
                        "parameters": [
                            [
                                "name": "limit",
                                "in": "query",
                                "schema": ["type": "integer"],
                            ],
                        ],
                    ],
                    "post": [
                        "operationId": "createUser",
                        "summary": "Create a user",
                        "requestBody": [
                            "content": [
                                "application/json": [
                                    "schema": [
                                        "type": "object",
                                        "properties": [
                                            "name": ["type": "string"],
                                            "email": ["type": "string"],
                                        ],
                                        "required": ["name"],
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
                "/users/{id}": [
                    "get": [
                        "operationId": "getUser",
                        "summary": "Get a user by id",
                        "parameters": [
                            [
                                "name": "id",
                                "in": "path",
                                "required": true,
                                "schema": ["type": "string"],
                            ],
                        ],
                    ],
                ],
            ],
        ]
    }

    @Test func openapiCommandRegistersGroup() {
        let cli = Cli("api-cli")
            .command(
                "api",
                openapi: sampleSpec,
                fetch: { _, _, _, _ in .object(OrderedMap()) },
                description: "API gateway"
            )

        guard let entry = cli.commands["api"] else {
            Issue.record("expected `api` command to be registered")
            return
        }
        guard case .group(let desc, let subs, _, _) = entry else {
            Issue.record("expected api to be a group")
            return
        }
        #expect(desc == "API gateway")
        // Should have all three operations: listUsers, createUser, getUser
        #expect(subs.count == 3)
        #expect(subs["listUsers"] != nil)
        #expect(subs["createUser"] != nil)
        #expect(subs["getUser"] != nil)
    }

    @Test func openapiSubcommandUsesOperationIdAsName() {
        let cli = Cli("api-cli").command(
            "api",
            openapi: sampleSpec,
            fetch: { _, _, _, _ in .null }
        )
        guard case .group(_, let subs, _, _) = cli.commands["api"] else {
            Issue.record("expected group")
            return
        }
        guard case .leaf(let listDef) = subs["listUsers"] else {
            Issue.record("expected listUsers leaf")
            return
        }
        #expect(listDef.description == "List all users")
        // limit is a query parameter -> options
        #expect(listDef.optionsFields.contains { $0.name == "limit" })
        // No path params -> argsFields empty
        #expect(listDef.argsFields.isEmpty)
    }

    @Test func openapiPathParamBecomesPositionalArg() {
        let cli = Cli("api-cli").command(
            "api",
            openapi: sampleSpec,
            fetch: { _, _, _, _ in .null }
        )
        guard case .group(_, let subs, _, _) = cli.commands["api"],
              case .leaf(let getDef) = subs["getUser"] else {
            Issue.record("expected getUser leaf")
            return
        }
        #expect(getDef.argsFields.count == 1)
        #expect(getDef.argsFields.first?.name == "id")
        #expect(getDef.argsFields.first?.required == true)
    }

    @Test func openapiBodyPropsBecomeOptions() {
        let cli = Cli("api-cli").command(
            "api",
            openapi: sampleSpec,
            fetch: { _, _, _, _ in .null }
        )
        guard case .group(_, let subs, _, _) = cli.commands["api"],
              case .leaf(let createDef) = subs["createUser"] else {
            Issue.record("expected createUser leaf")
            return
        }
        let optionNames = createDef.optionsFields.map(\.name)
        #expect(optionNames.contains("name"))
        #expect(optionNames.contains("email"))
    }

    @Test func openapiHandlerInvokesFetchWithInterpolatedUrl() async {
        let captured = GatewayBox<(url: String, method: String, headers: [(String, String)], body: String?)?>(nil)

        let cli = Cli("api-cli").command(
            "api",
            openapi: sampleSpec,
            fetch: { url, method, headers, body in
                captured.value = (url, method, headers, body)
                return .object(["id": "42", "name": "Alice"])
            },
            basePath: "https://api.example.com"
        )

        guard case .group(_, let subs, _, _) = cli.commands["api"],
              case .leaf(let getDef) = subs["getUser"] else {
            Issue.record("expected getUser leaf")
            return
        }

        let result = await getDef.handler.run(
            CommandContext(
                args: .object(["id": "42"]),
                options: .object(OrderedMap())
            )
        )

        // Fetch was called with the interpolated URL
        #expect(captured.value?.url == "https://api.example.com/users/42")
        #expect(captured.value?.method == "GET")

        // Result is .ok (no { ok: false } envelope -> raw data passes through)
        switch result {
        case .ok(let data, _):
            #expect(data["id"]?.stringValue == "42")
            #expect(data["name"]?.stringValue == "Alice")
        case .error, .stream:
            Issue.record("expected ok result")
        }
    }

    @Test func openapiHandlerRoutesPostBody() async {
        let captured = GatewayBox<(url: String, method: String, headers: [(String, String)], body: String?)?>(nil)

        let cli = Cli("api-cli").command(
            "api",
            openapi: sampleSpec,
            fetch: { url, method, headers, body in
                captured.value = (url, method, headers, body)
                return .object(["created": true])
            }
        )

        guard case .group(_, let subs, _, _) = cli.commands["api"],
              case .leaf(let createDef) = subs["createUser"] else {
            Issue.record("expected createUser leaf")
            return
        }

        let result = await createDef.handler.run(
            CommandContext(
                args: .object(OrderedMap()),
                options: .object(["name": "Bob", "email": "bob@example.com"])
            )
        )

        #expect(captured.value?.method == "POST")
        #expect(captured.value?.url == "/users")
        // Body should be JSON-serialized
        #expect(captured.value?.body != nil)
        let bodyText = captured.value?.body ?? ""
        #expect(bodyText.contains("\"name\""))
        #expect(bodyText.contains("\"Bob\""))

        if case .ok(let data, _) = result {
            #expect(data["created"]?.boolValue == true)
        } else {
            Issue.record("expected ok result")
        }
    }

    @Test func openapiPathToCommandNameMatchesTSWhenNoOperationId() {
        // Spec without operationId — should fall back to method_path_with_underscores.
        let spec: JSONValue = [
            "paths": [
                "/health": [
                    "get": [
                        "summary": "Health check",
                    ],
                ],
            ],
        ]

        let cli = Cli("foo").command(
            "api",
            openapi: spec,
            fetch: { _, _, _, _ in .null }
        )
        guard case .group(_, let subs, _, _) = cli.commands["api"] else {
            Issue.record("expected group")
            return
        }
        // generateOperationName: get + sanitize("/health" -> "_health") -> "get__health"
        #expect(subs["get__health"] != nil)
    }
}
