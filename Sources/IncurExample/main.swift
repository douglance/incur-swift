/// A todo-list CLI built with incur.
///
/// Demonstrates: commands, args, options, streaming, middleware,
/// and all built-in flags (--help, --version, --json, --format, --filter-output).
///
/// Usage:
///   swift run IncurExample -- --help
///   swift run IncurExample -- add "Buy groceries" --priority high
///   swift run IncurExample -- list
///   swift run IncurExample -- list --status done
///   swift run IncurExample -- get 1
///   swift run IncurExample -- complete 1
///   swift run IncurExample -- stats
///   swift run IncurExample -- stream
///   swift run IncurExample -- list --json
///   swift run IncurExample -- list --format yaml
///   swift run IncurExample -- --version

import Foundation
import Incur

// MARK: - Handlers

struct AddHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let title = ctx.args["title"]?.stringValue ?? "untitled"
        let priority = ctx.options["priority"]?.stringValue ?? "medium"

        return .ok(
            data: [
                "id": 42,
                "title": .string(title),
                "priority": .string(priority),
                "status": "pending",
            ],
            cta: CtaBlock(
                commands: [
                    .simple("list"),
                    .detailed(command: "get 42", description: "View the new todo"),
                ],
                description: "Next steps:"
            )
        )
    }
}

struct ListHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let status = ctx.options["status"]?.stringValue ?? "all"

        let todos: [JSONValue] = [
            ["id": 1, "title": "Buy groceries", "priority": "high", "status": "pending"],
            ["id": 2, "title": "Write docs", "priority": "medium", "status": "done"],
            ["id": 3, "title": "Fix bug #123", "priority": "high", "status": "pending"],
            ["id": 4, "title": "Review PR", "priority": "low", "status": "done"],
            ["id": 5, "title": "Deploy v2", "priority": "medium", "status": "pending"],
        ]

        let filtered: [JSONValue]
        if status == "all" {
            filtered = todos
        } else {
            filtered = todos.filter { $0["status"]?.stringValue == status }
        }

        return .ok(data: .array(filtered))
    }
}

struct GetHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let id = ctx.args["id"]?.intValue ?? 0

        if id == 0 || id > 5 {
            return .error(
                code: "NOT_FOUND",
                message: "Todo #\(id) not found",
                exitCode: 1,
                cta: CtaBlock(
                    commands: [.simple("list")],
                    description: "Try listing all todos:"
                )
            )
        }

        return .ok(data: [
            "id": .int(id),
            "title": .string("Todo #\(id)"),
            "priority": "medium",
            "status": "pending",
            "created_at": "2026-03-21T12:00:00Z",
        ])
    }
}

struct CompleteHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let id = ctx.args["id"]?.intValue ?? 0

        return .ok(data: [
            "id": .int(id),
            "status": "done",
            "completed_at": "2026-03-21T15:30:00Z",
        ])
    }
}

struct StatsHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        .ok(data: [
            "total": 5,
            "pending": 3,
            "done": 2,
            "by_priority": [
                "high": 2,
                "medium": 2,
                "low": 1,
            ],
        ])
    }
}

struct StreamHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let stream = AsyncStream<JSONValue> { continuation in
            Task {
                for i in 1...5 {
                    try? await Task.sleep(for: .milliseconds(300))
                    continuation.yield([
                        "event": "progress",
                        "step": .int(i),
                        "total": 5,
                        "message": .string("Processing batch \(i)..."),
                    ])
                }
                continuation.yield([
                    "event": "complete",
                    "message": "All batches processed successfully",
                ])
                continuation.finish()
            }
        }
        return .stream(stream)
    }
}

// MARK: - Middleware

func loggingMiddleware() -> MiddlewareFn {
    return { @Sendable ctx, next in
        if !ctx.agent {
            fputs("[todoapp] running `\(ctx.command)`\n", stderr)
        }
        await next()
    }
}

// MARK: - CLI Construction

func buildCli() -> Cli {
    let cli = Cli("todoapp")
        .description("A simple todo list manager")
        .version("0.1.0")
        .useMiddleware(loggingMiddleware())

        // --- add command ---
        .command("add", CommandDef(
            name: "add",
            description: "Add a new todo item",
            argsFields: [
                FieldMeta(name: "title", description: "The todo title", fieldType: .string, required: true),
            ],
            optionsFields: [
                FieldMeta(
                    name: "priority",
                    description: "Priority level",
                    fieldType: .enum(["low", "medium", "high"]),
                    defaultValue: "medium",
                    alias: "p"
                ),
            ],
            aliases: ["priority": "p"],
            examples: [
                Example(command: "\"Buy groceries\"", description: "Add with default priority"),
                Example(command: "\"Fix bug\" --priority high", description: "Add with high priority"),
                Example(command: "\"Read book\" -p low", description: "Add with short alias"),
            ],
            handler: AddHandler()
        ))

        // --- list command ---
        .command("list", CommandDef(
            name: "list",
            description: "List todo items",
            optionsFields: [
                FieldMeta(
                    name: "status",
                    description: "Filter by status",
                    fieldType: .enum(["all", "pending", "done"]),
                    defaultValue: "all",
                    alias: "s"
                ),
                FieldMeta(
                    name: "limit",
                    description: "Maximum number of results",
                    fieldType: .number,
                    defaultValue: 50,
                    alias: "n"
                ),
            ],
            aliases: ["status": "s", "limit": "n"],
            examples: [
                Example(command: "", description: "List all todos"),
                Example(command: "--status pending", description: "List only pending"),
                Example(command: "--json", description: "Output as JSON"),
            ],
            handler: ListHandler()
        ))

        // --- get command ---
        .command("get", CommandDef(
            name: "get",
            description: "Get a todo by ID",
            argsFields: [
                FieldMeta(name: "id", description: "The todo ID", fieldType: .number, required: true),
            ],
            examples: [
                Example(command: "1", description: "Get todo #1"),
            ],
            handler: GetHandler()
        ))

        // --- complete command ---
        .command("complete", CommandDef(
            name: "complete",
            description: "Mark a todo as done",
            argsFields: [
                FieldMeta(name: "id", description: "The todo ID to complete", fieldType: .number, required: true),
            ],
            examples: [
                Example(command: "1", description: "Complete todo #1"),
            ],
            handler: CompleteHandler()
        ))

        // --- stats command ---
        .command("stats", CommandDef(
            name: "stats",
            description: "Show todo statistics",
            handler: StatsHandler()
        ))

        // --- stream command ---
        .command("stream", CommandDef(
            name: "stream",
            description: "Stream progress updates (demo)",
            hint: "Streams 5 progress events with 300ms delays.",
            handler: StreamHandler()
        ))

    return cli
}

// MARK: - Main

@main
struct TodoApp {
    static func main() async {
        let cli = buildCli()
        do {
            try await cli.serve()
        } catch {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
