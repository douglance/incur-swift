# Incur

A Swift framework for building CLIs that work for both AI agents and humans.

Define your commands once. Incur serves them over three transports:

- **CLI** — standard argv parsing with flags, options, positional args
- **MCP** — Model Context Protocol stdio server for AI coding agents
- **HTTP** — JSON API server (bring your own HTTP framework)

## Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/douglance/incur-swift.git", from: "0.1.0"),
]
```

Then add `"Incur"` to your target's dependencies:

```swift
.executableTarget(
    name: "MyCLI",
    dependencies: [
        .product(name: "Incur", package: "incur-swift"),
    ]
)
```

## Quick Start

```swift
import Incur

struct GreetHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let name = ctx.args["name"]?.stringValue ?? "world"
        return .ok(data: ["message": .string("Hello, \(name)!")])
    }
}

@main
struct MyCLI {
    static func main() async {
        let cli = Cli("greet")
            .description("A greeting CLI")
            .version("1.0.0")
            .command("hello", CommandDef(
                name: "hello",
                description: "Say hello",
                argsFields: [
                    FieldMeta(name: "name", description: "Who to greet", fieldType: .string, required: true),
                ],
                handler: GreetHandler()
            ))

        do {
            try await cli.serve()
        } catch {
            fputs("Error: \(error)\n", stderr)
        }
    }
}
```

```
$ greet hello World
Hello, World!

$ greet hello World --json
{"message":"Hello, World!"}

$ greet --mcp
# starts MCP stdio server

$ greet --help
A greeting CLI

Commands:
  hello    Say hello
```

## Commands

Commands are defined with `CommandDef` and a `CommandHandler`:

```swift
struct MyHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        // ctx.args     — positional arguments
        // ctx.options  — named options/flags
        // ctx.env      — environment variable bindings
        // ctx.agent    — true if invoked by an AI agent
        // ctx.format   — requested output format
        // ctx.vars     — variables set by middleware

        return .ok(data: ["result": "done"])
    }
}
```

`CommandResult` has three variants:

```swift
.ok(data: JSONValue, cta: CtaBlock?)          // success
.error(code:, message:, retryable:, exitCode:) // structured error
.stream(AsyncStream<JSONValue>)                // streaming output
```

### Arguments and Options

```swift
CommandDef(
    name: "deploy",
    description: "Deploy an application",
    argsFields: [
        FieldMeta(name: "app", description: "App name", fieldType: .string, required: true),
    ],
    optionsFields: [
        FieldMeta(name: "env", description: "Target environment",
                  fieldType: .enum(["staging", "production"]),
                  defaultValue: "staging", alias: "e"),
        FieldMeta(name: "force", description: "Skip confirmation",
                  fieldType: .boolean),
        FieldMeta(name: "replicas", description: "Number of replicas",
                  fieldType: .number, defaultValue: 3),
    ],
    aliases: ["env": "e"],
    handler: DeployHandler()
)
```

```
$ mycli deploy myapp --env production --force
$ mycli deploy myapp -e staging --replicas 5
```

### Subcommands

Nest `Cli` instances as groups:

```swift
let db = Cli("db")
    .description("Database operations")
    .command("migrate", CommandDef(name: "migrate", ...))
    .command("seed", CommandDef(name: "seed", ...))

let cli = Cli("mycli")
    .group(db)
    .command("status", CommandDef(name: "status", ...))
```

```
$ mycli db migrate
$ mycli status
```

## Macros

Incur provides macros to generate argument and option schemas from Swift structs:

### `@IncurArgs` — Positional Arguments

```swift
@IncurArgs
struct DeployArgs {
    /// The application to deploy
    var app: String
    /// Optional version tag
    var version: String?
}
```

### `@IncurOptions` — Named Options

```swift
@IncurOptions
struct DeployOptions {
    /// Target environment
    @Incur(alias: "e", default: "staging")
    var env: String
    /// Number of replicas
    @Incur(alias: "n", default: 3)
    var replicas: Int
    /// Skip confirmation
    var force: Bool
    /// Deprecated flag
    @Incur(deprecated: "Use --env instead")
    var target: String?
}
```

### `@IncurEnv` — Environment Variables

```swift
@IncurEnv
struct AppEnv {
    /// API token
    @Incur(env: "API_TOKEN")
    var apiToken: String
    /// Base URL
    @Incur(env: "BASE_URL", default: "https://api.example.com")
    var baseUrl: String
}
```

## Middleware

Onion-style middleware that wraps command execution:

```swift
func authMiddleware() -> MiddlewareFn {
    return { @Sendable ctx, next in
        guard let token = ProcessInfo.processInfo.environment["API_TOKEN"] else {
            fputs("Error: API_TOKEN not set\n", stderr)
            return
        }
        ctx.vars["token"] = .string(token)
        await next()
    }
}

let cli = Cli("mycli")
    .useMiddleware(authMiddleware())
```

Middleware applies at three levels: CLI-wide, per-group, and per-command.

## MCP Server

Every Incur CLI is automatically an MCP server. Pass `--mcp` to start it:

```
$ mycli --mcp
```

All commands become MCP tools. Subcommands are named with underscores (e.g., `db_migrate`). Input schemas are generated from your field definitions.

### Register with AI agents

```
$ mycli mcp add              # registers with all detected agents
$ mycli mcp add --agent amp  # register with a specific agent
```

Supports 21 AI coding agents including Claude Code, Cursor, Copilot, Amp, Windsurf, and more.

## Built-in Flags

Every CLI gets these automatically:

| Flag | Description |
|------|-------------|
| `--help`, `-h` | Auto-generated help text |
| `--version` | Print version |
| `--json` | JSON output |
| `--format <fmt>` | Output format: `toon`, `json`, `yaml`, `md`, `jsonl`, `table`, `csv` |
| `--verbose` | Full output envelope with metadata |
| `--filter-output <keys>` | Filter output by key paths (e.g., `foo,bar.baz,a[0,3]`) |
| `--schema` | JSON Schema for command input |
| `--mcp` | Start as MCP stdio server |
| `--llms` | Compact command index for LLMs |
| `--llms-full` | Full skill manifest for LLMs |
| `--token-count` | Token-based output pagination |
| `completions <shell>` | Shell completions (bash, zsh, fish, nushell) |
| `skills add` | Sync skill files to AI agents |
| `mcp add` | Register as MCP server with AI agents |

## Output Formats

```
$ mycli list                          # human-readable (toon)
$ mycli list --json                   # JSON
$ mycli list --format table           # ASCII table
$ mycli list --format csv             # CSV
$ mycli list --format md              # Markdown table
$ mycli list --filter-output id,title # select specific fields
```

## Call-to-Action

Commands can suggest follow-up actions:

```swift
return .ok(
    data: ["id": 42, "status": "created"],
    cta: CtaBlock(
        commands: [
            .simple("list"),
            .detailed(command: "get 42", description: "View the new item"),
        ],
        description: "Next steps:"
    )
)
```

Displayed to humans on stderr. Included in JSON/MCP responses as structured data.

## HTTP Server

Generate routes from your command tree and plug into any Swift HTTP framework:

```swift
let routes = cli.flattenCommands()    // [HttpRoute]
let response = handleHttpRequest(...) // HttpResponse
```

## OpenAPI

Generate commands from an OpenAPI 3.x spec:

```swift
let commands = generateCommands(
    spec: openApiSpec,
    fetchFn: myHttpClient,
    options: GenerateOptions(basePath: "https://api.example.com")
)
```

## Config Files

CLIs can load defaults from JSON config files:

```json
{
  "commands": {
    "deploy": {
      "options": {
        "env": "staging",
        "replicas": 3
      }
    }
  }
}
```

Use `--config-schema` to generate JSON Schema for editor autocompletion.

## Requirements

- Swift 6.0+
- macOS 13+

## License

MIT
