import Foundation
import Testing
@testable import Incur

private struct FetchHelloHandler: CommandHandler, Sendable {
    func run(_ ctx: CommandContext) async -> CommandResult {
        var data = OrderedMap()
        data["name"] = ctx.args["name"] ?? .null
        data["limit"] = ctx.options["limit"] ?? .null
        data["created"] = ctx.options["created"] ?? .null
        return .ok(data: .object(data))
    }
}

private struct FetchHealthHandler: CommandHandler, Sendable {
    func run(_ ctx: CommandContext) async -> CommandResult {
        .ok(data: ["ok": true])
    }
}

private struct FetchValidationHandler: CommandHandler, Sendable {
    func run(_ ctx: CommandContext) async -> CommandResult {
        guard let id = ctx.args["id"], !id.isNull else {
            return .error(code: "VALIDATION_ERROR", message: "id is required", retryable: false, exitCode: 1)
        }
        return .ok(data: ["id": id])
    }
}

private struct FetchStreamHandler: CommandHandler, Sendable {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let stream = AsyncStream<JSONValue> { cont in
            cont.yield(["progress": 1])
            cont.yield(["progress": 2])
            cont.finish()
        }
        return .stream(stream)
    }
}

@Suite("CliFetchHandler")
struct CliFetchHandlerTests {

    @Test func getHealthReturns200() async {
        let cli = Cli("test").command(
            "health",
            CommandDef(name: "health", handler: FetchHealthHandler())
        )
        let req = URLRequest(url: URL(string: "http://localhost/health")!)
        let res = await cli.fetch(req)
        #expect(res.status == 200)
        #expect(res.body["ok"]?.boolValue == true)
        #expect(res.body["data"]?["ok"]?.boolValue == true)
        #expect(res.body["meta"]?["command"]?.stringValue == "health")
    }

    @Test func getUnknownReturns404() async {
        let cli = Cli("test").command(
            "health",
            CommandDef(name: "health", handler: FetchHealthHandler())
        )
        let req = URLRequest(url: URL(string: "http://localhost/unknown")!)
        let res = await cli.fetch(req)
        #expect(res.status == 404)
        #expect(res.body["ok"]?.boolValue == false)
        #expect(res.body["error"]?["code"]?.stringValue == "COMMAND_NOT_FOUND")
    }

    @Test func getRootWithoutRootCommandReturns404() async {
        let cli = Cli("test").command(
            "health",
            CommandDef(name: "health", handler: FetchHealthHandler())
        )
        let req = URLRequest(url: URL(string: "http://localhost/")!)
        let res = await cli.fetch(req)
        #expect(res.status == 404)
        #expect(res.body["ok"]?.boolValue == false)
        #expect(res.body["error"]?["code"]?.stringValue == "COMMAND_NOT_FOUND")
    }

    @Test func querySearchParamsBecomeOptions() async {
        let cli = Cli("test").command(
            "users",
            CommandDef(
                name: "users",
                optionsFields: [
                    FieldMeta(name: "limit", fieldType: .number),
                ],
                handler: FetchHelloHandler()
            )
        )
        let req = URLRequest(url: URL(string: "http://localhost/users?limit=5")!)
        let res = await cli.fetch(req)
        #expect(res.status == 200)
        #expect(res.body["data"]?["limit"]?.stringValue == "5")
    }

    @Test func postBodyBecomesOptions() async {
        let cli = Cli("test").command(
            "users",
            CommandDef(
                name: "users",
                optionsFields: [
                    FieldMeta(name: "created", fieldType: .boolean),
                ],
                handler: FetchHelloHandler()
            )
        )
        var req = URLRequest(url: URL(string: "http://localhost/users")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = "{\"created\":true}".data(using: .utf8)

        let res = await cli.fetch(req)
        #expect(res.status == 200)
        #expect(res.body["data"]?["created"]?.boolValue == true)
    }

    @Test func trailingPathSegmentsBecomePositionalArgs() async {
        let cli = Cli("test").command(
            "users",
            CommandDef(
                name: "users",
                argsFields: [
                    FieldMeta(name: "name", fieldType: .string, required: true),
                ],
                handler: FetchHelloHandler()
            )
        )
        let req = URLRequest(url: URL(string: "http://localhost/users/alice")!)
        let res = await cli.fetch(req)
        #expect(res.status == 200)
        #expect(res.body["data"]?["name"]?.stringValue == "alice")
    }

    @Test func nestedCommandResolution() async {
        let listCmd = CommandDef(name: "list", handler: FetchHealthHandler())
        let cli = Cli("test")
        cli.commands["users"] = .group(
            description: "Users",
            commands: ["list": .leaf(listCmd)],
            middleware: [],
            outputPolicy: nil
        )
        let req = URLRequest(url: URL(string: "http://localhost/users/list")!)
        let res = await cli.fetch(req)
        #expect(res.status == 200)
        #expect(res.body["meta"]?["command"]?.stringValue == "users list")
    }

    @Test func validationErrorReturns400() async {
        let cli = Cli("test").command(
            "users",
            CommandDef(
                name: "users",
                argsFields: [
                    FieldMeta(name: "id", fieldType: .number, required: true),
                ],
                handler: FetchValidationHandler()
            )
        )
        let req = URLRequest(url: URL(string: "http://localhost/users")!)
        let res = await cli.fetch(req)
        #expect(res.status == 400)
        #expect(res.body["ok"]?.boolValue == false)
        #expect(res.body["error"]?["code"]?.stringValue == "VALIDATION_ERROR")
    }

    @Test func streamingHandlerBuffersIntoArray() async {
        let cli = Cli("test").command(
            "stream",
            CommandDef(name: "stream", handler: FetchStreamHandler())
        )
        let req = URLRequest(url: URL(string: "http://localhost/stream")!)
        let res = await cli.fetch(req)
        #expect(res.status == 200)
        let chunks = res.body["data"]?.arrayValue
        #expect(chunks?.count == 2)
        #expect(chunks?[0]["progress"]?.intValue == 1)
        #expect(chunks?[1]["progress"]?.intValue == 2)
    }

    @Test func bodyDataReturnsCompactJSON() {
        let resp = FetchResponse(
            status: 200,
            headers: ["content-type": "application/json"],
            body: ["ok": true, "data": "hi"]
        )
        let str = String(data: resp.bodyData(), encoding: .utf8) ?? ""
        #expect(str.contains("\"ok\":true"))
        #expect(str.contains("\"data\":\"hi\""))
    }
}
