import Foundation
import Testing
@testable import Incur

// MARK: - Test Handlers

/// A simple echo handler for testing that returns its args and options.
private struct EchoHandler: CommandHandler, Sendable {
    func run(_ ctx: CommandContext) async -> CommandResult {
        var data = OrderedMap()
        data["args"] = ctx.args
        data["options"] = ctx.options
        return .ok(data: .object(data))
    }
}

/// A handler that returns a stream for testing.
private struct StreamTestHandler: CommandHandler, Sendable {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let stream = AsyncStream<JSONValue> { continuation in
            continuation.yield(.int(1))
            continuation.yield(.int(2))
            continuation.yield(.int(3))
            continuation.finish()
        }
        return .stream(stream)
    }
}

/// A handler that returns an error.
private struct ErrorTestHandler: CommandHandler, Sendable {
    func run(_ ctx: CommandContext) async -> CommandResult {
        .error(code: "TEST_ERROR", message: "Something went wrong", retryable: true, exitCode: 1)
    }
}

/// A handler that returns a validation error.
private struct ValidationErrorTestHandler: CommandHandler, Sendable {
    func run(_ ctx: CommandContext) async -> CommandResult {
        .error(code: "VALIDATION_ERROR", message: "Invalid input", retryable: false, exitCode: 1)
    }
}

// MARK: - HTTP Server Tests

@Suite("HttpServer")
struct HttpServerTests {

    // MARK: - flattenCommands

    @Test func testFlattenCommands() {
        let echoCmd = CommandDef(name: "echo", handler: EchoHandler())
        let listCmd = CommandDef(name: "list", handler: EchoHandler())
        let getCmd = CommandDef(name: "get", handler: EchoHandler())

        let entries: [String: CommandEntry] = [
            "echo": .leaf(echoCmd),
            "users": .group(
                description: "User commands",
                commands: [
                    "list": .leaf(listCmd),
                    "get": .leaf(getCmd),
                ],
                middleware: [],
                outputPolicy: nil
            ),
        ]

        let routes = flattenCommands(entries: entries)

        let paths = Set(routes.map(\.path))
        #expect(paths.contains("/echo"))
        #expect(paths.contains("/users/list"))
        #expect(paths.contains("/users/get"))
        #expect(!paths.contains("/users"))
        #expect(routes.count == 3)
    }

    @Test func testFlattenCommandsWithMiddleware() {
        let groupMiddleware: MiddlewareFn = { @Sendable _, next in
            await next()
        }

        let cmd = CommandDef(name: "list", handler: EchoHandler())

        let entries: [String: CommandEntry] = [
            "users": .group(
                description: "User commands",
                commands: [
                    "list": .leaf(cmd),
                ],
                middleware: [groupMiddleware],
                outputPolicy: nil
            ),
        ]

        let routes = flattenCommands(entries: entries)
        #expect(routes.count == 1)
        #expect(routes[0].middleware.count == 1)
    }

    @Test func testFlattenCommandsNested() {
        let cmd = CommandDef(name: "search", handler: EchoHandler())

        let entries: [String: CommandEntry] = [
            "admin": .group(
                description: "Admin",
                commands: [
                    "users": .group(
                        description: "Users",
                        commands: [
                            "search": .leaf(cmd),
                        ],
                        middleware: [],
                        outputPolicy: nil
                    ),
                ],
                middleware: [],
                outputPolicy: nil
            ),
        ]

        let routes = flattenCommands(entries: entries)
        #expect(routes.count == 1)
        #expect(routes[0].path == "/admin/users/search")
    }

    @Test func testFlattenCommandsEmpty() {
        let entries: [String: CommandEntry] = [:]
        let routes = flattenCommands(entries: entries)
        #expect(routes.isEmpty)
    }

    // MARK: - parseQueryString

    @Test func testParseQueryString() {
        let result = parseQueryString("name=alice&limit=10")
        #expect(result["name"]?.stringValue == "alice")
        #expect(result["limit"]?.stringValue == "10")
        #expect(result.count == 2)
    }

    @Test func testParseQueryStringEmpty() {
        let result = parseQueryString("")
        #expect(result.isEmpty)
    }

    @Test func testParseQueryStringNoValue() {
        let result = parseQueryString("flag")
        #expect(result["flag"]?.stringValue == "")
    }

    @Test func testParseQueryStringPercentEncoded() {
        let result = parseQueryString("name=hello%20world&q=a%26b")
        #expect(result["name"]?.stringValue == "hello world")
        #expect(result["q"]?.stringValue == "a&b")
    }

    @Test func testParseQueryStringPlusAsSpace() {
        let result = parseQueryString("q=hello+world")
        #expect(result["q"]?.stringValue == "hello world")
    }

    @Test func testParseQueryStringMultiplePairs() {
        let result = parseQueryString("a=1&b=2&c=3")
        #expect(result.count == 3)
        #expect(result["a"]?.stringValue == "1")
        #expect(result["b"]?.stringValue == "2")
        #expect(result["c"]?.stringValue == "3")
    }

    // MARK: - handleHttpRequest

    @Test func testHandleHttpRequestBasic() async {
        let cmd = CommandDef(
            name: "echo",
            description: "Echo command",
            handler: EchoHandler()
        )

        let route = HttpRoute(path: "/echo", command: cmd)

        let response = await handleHttpRequest(
            route: route,
            queryParams: ["name": "alice"],
            bodyParams: OrderedMap(),
            cliName: "test-cli"
        )

        #expect(response.statusCode == 200)
        #expect(response.body["ok"]?.boolValue == true)
        #expect(response.body["data"] != nil)
        #expect(response.body["meta"]?["command"]?.stringValue == "echo")
        #expect(response.body["meta"]?["duration"]?.stringValue?.hasSuffix("ms") == true)
    }

    @Test func testHandleHttpRequestWithBodyParams() async {
        let cmd = CommandDef(name: "create", handler: EchoHandler())
        let route = HttpRoute(path: "/create", command: cmd)

        let bodyParams: OrderedMap = ["name": "bob", "age": 30]
        let response = await handleHttpRequest(
            route: route,
            queryParams: OrderedMap(),
            bodyParams: bodyParams,
            cliName: "test-cli"
        )

        #expect(response.statusCode == 200)
        #expect(response.body["ok"]?.boolValue == true)
    }

    @Test func testHandleHttpRequestError() async {
        let cmd = CommandDef(name: "fail", handler: ErrorTestHandler())
        let route = HttpRoute(path: "/fail", command: cmd)

        let response = await handleHttpRequest(
            route: route,
            queryParams: OrderedMap(),
            bodyParams: OrderedMap(),
            cliName: "test-cli"
        )

        #expect(response.statusCode == 500)
        #expect(response.body["ok"]?.boolValue == false)
        #expect(response.body["error"]?["code"]?.stringValue == "TEST_ERROR")
        #expect(response.body["error"]?["message"]?.stringValue == "Something went wrong")
    }

    @Test func testHandleHttpRequestValidationError() async {
        let cmd = CommandDef(name: "validate", handler: ValidationErrorTestHandler())
        let route = HttpRoute(path: "/validate", command: cmd)

        let response = await handleHttpRequest(
            route: route,
            queryParams: OrderedMap(),
            bodyParams: OrderedMap(),
            cliName: "test-cli"
        )

        // Validation errors should return 400
        #expect(response.statusCode == 400)
        #expect(response.body["ok"]?.boolValue == false)
        #expect(response.body["error"]?["code"]?.stringValue == "VALIDATION_ERROR")
    }

    @Test func testHandleHttpRequestStream() async {
        let cmd = CommandDef(name: "stream", handler: StreamTestHandler())
        let route = HttpRoute(path: "/stream", command: cmd)

        let response = await handleHttpRequest(
            route: route,
            queryParams: OrderedMap(),
            bodyParams: OrderedMap(),
            cliName: "test-cli"
        )

        #expect(response.statusCode == 200)
        #expect(response.body["ok"]?.boolValue == true)

        // Stream should be buffered into an array
        let data = response.body["data"]?.arrayValue
        #expect(data != nil)
        #expect(data?.count == 3)
        #expect(data?[0] == .int(1))
        #expect(data?[1] == .int(2))
        #expect(data?[2] == .int(3))
    }

    @Test func testHandleHttpRequestGroupedCommand() async {
        let cmd = CommandDef(name: "list", handler: EchoHandler())
        let route = HttpRoute(path: "/users/list", command: cmd)

        let response = await handleHttpRequest(
            route: route,
            queryParams: OrderedMap(),
            bodyParams: OrderedMap(),
            cliName: "test-cli"
        )

        #expect(response.statusCode == 200)
        #expect(response.body["meta"]?["command"]?.stringValue == "users list")
    }

    @Test func testHandleHttpRequestMergesQueryAndBody() async {
        let cmd = CommandDef(name: "merge", handler: EchoHandler())
        let route = HttpRoute(path: "/merge", command: cmd)

        // Body should override query
        let response = await handleHttpRequest(
            route: route,
            queryParams: ["name": "from-query", "extra": "query-only"],
            bodyParams: ["name": "from-body"],
            cliName: "test-cli"
        )

        #expect(response.statusCode == 200)
        // The echo handler returns options as-is, so we can verify merge behavior
        let options = response.body["data"]?["options"]
        #expect(options?["name"]?.stringValue == "from-body")
        #expect(options?["extra"]?.stringValue == "query-only")
    }

    @Test func testHandleHttpRequestWithVersion() async {
        let cmd = CommandDef(name: "echo", handler: EchoHandler())
        let route = HttpRoute(path: "/echo", command: cmd)

        let response = await handleHttpRequest(
            route: route,
            queryParams: OrderedMap(),
            bodyParams: OrderedMap(),
            cliName: "test-cli",
            cliVersion: "1.2.3"
        )

        #expect(response.statusCode == 200)
        #expect(response.body["ok"]?.boolValue == true)
    }
}
