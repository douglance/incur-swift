---
name: incur-swift
description: incur-swift is the Swift port of the incur framework for building CLIs that work for both AI agents and humans. Use when creating new Swift CLIs.
command: incur-swift
---

# incur-swift

Swift framework for building CLIs for agents and human consumption. Strictly typed schemas for arguments and options via Swift macros, structured output envelopes, auto-generated skill files, and agent discovery via Skills, MCP, and `--llms`.

This SKILL is the Swift counterpart of the upstream TypeScript [`incur`](https://github.com/wevm/incur) `SKILL.md`. Section structure is preserved so users moving between the TS and Swift docs find the same anchors.

## Install

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/douglance/incur-swift.git", from: "0.1.0"),
],
targets: [
    .executableTarget(
        name: "MyCLI",
        dependencies: [
            .product(name: "Incur", package: "incur-swift"),
        ]
    ),
]
```

Supported platforms: macOS 13+, iOS 18+, tvOS 17+, visionOS 2+. Swift 6.0+.

## Quick Start

```swift
import Incur

struct GreetHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let name = ctx.args["name"]?.stringValue ?? "world"
        return .ok(data: ["message": .string("hello \(name)")])
    }
}

@main
struct GreetCLI {
    static func main() async {
        let cli = Cli("greet")
            .description("A greeting CLI")
            .command("greet", CommandDef(
                name: "greet",
                argsFields: [
                    FieldMeta(name: "name", description: "Name to greet",
                              fieldType: .string, required: true),
                ],
                handler: GreetHandler()
            ))
        try? await cli.serve()
    }
}
```

```sh
greet world
# → message: hello world
```

## Creating a CLI

`Cli(name)` is the entry point. It has two modes:

### Single-command CLI

Pass a single root `command` and don't register subcommands:

```swift
let cli = Cli("tool")
    .description("Does one thing")
    .command("tool", CommandDef(
        name: "tool",
        argsFields: [FieldMeta(name: "file", fieldType: .string, required: true)],
        handler: ToolHandler()
    ))
```

### Router CLI (subcommands)

Register multiple subcommands via `.command()`. Each call returns the CLI instance and is chainable:

```swift
let cli = Cli("gh")
    .version("1.0.0")
    .description("GitHub CLI")
    .command("status", CommandDef(name: "status", handler: StatusHandler()))
    .command("clone",  CommandDef(name: "clone",  handler: CloneHandler()))

try await cli.serve()
```

## Commands

### Registering commands

```swift
cli.command("install", CommandDef(
    name: "install",
    description: "Install a package",
    argsFields: [
        FieldMeta(name: "package", description: "Package name",
                  fieldType: .string, required: false),
    ],
    optionsFields: [
        FieldMeta(name: "save_dev", description: "Save as dev dependency",
                  fieldType: .boolean, alias: "D"),
        FieldMeta(name: "global", description: "Install globally",
                  fieldType: .boolean, alias: "g"),
    ],
    aliases: ["save_dev": "D", "global": "g"],
    examples: [
        Example(command: "express", description: "Install a package"),
        Example(command: "vitest --save-dev", description: "Install as dev dependency"),
    ],
    handler: InstallHandler()
))
```

`.command()` is chainable — it returns the CLI instance:

```swift
cli
    .command("ping",    CommandDef(name: "ping",    handler: PingHandler()))
    .command("version", CommandDef(name: "version", handler: VersionHandler()))
```

### Subcommand groups

Create a sub-CLI and mount it as a command group:

```swift
let cli = Cli("gh").description("GitHub CLI")
let pr  = Cli("pr").description("Pull request commands")

pr.command("list", CommandDef(
    name: "list",
    description: "List pull requests",
    optionsFields: [
        FieldMeta(name: "state", fieldType: .enum(["open", "closed", "all"]),
                  defaultValue: "open"),
    ],
    handler: ListPRHandler()
))

pr.command("view", CommandDef(
    name: "view",
    description: "View a pull request",
    argsFields: [FieldMeta(name: "number", fieldType: .number, required: true)],
    handler: ViewPRHandler()
))

cli.group(pr)
try await cli.serve()
```

```sh
gh pr list --state closed
gh pr view 42
```

Groups nest arbitrarily — `cli.group(pr).group(...)` builds `gh pr review approve`-style trees.

### HTTP Routes

Flatten the command tree into HTTP routes, then plug into your HTTP framework of choice (Hummingbird, Vapor, swift-nio):

```swift
let routes = cli.flattenCommands()  // [HttpRoute]
// Each HttpRoute has .path, .method, .handler that maps Request -> Response.
```

Argv translates into HTTP using curl-style conventions: positional args become path segments, options become query string or JSON body. Responses are JSON envelopes:

```json
{ "ok": true, "data": { ... }, "meta": { "command": "users", "duration": "3ms" } }
```

Streaming commands (`CommandResult.stream(_:)`) are emitted as NDJSON (`application/x-ndjson`).

### OpenAPI

Generate commands from an OpenAPI 3.x spec:

```swift
let commands = generateCommands(
    spec: openApiSpec,
    fetchFn: myHttpClient,
    options: GenerateOptions(basePath: "https://api.example.com")
)
for cmd in commands {
    cli.command(cmd.name, cmd)
}
```

This is the Swift equivalent of `.command('api', { fetch, openapi: spec })` in the TS package — same idea, different shape.

## Arguments & Options

All schemas use `[FieldMeta]` (or the `@IncurArgs` / `@IncurOptions` macros to derive them from struct fields). Arguments are positional (assigned by order in `argsFields`). Options are named flags.

### Arguments

```swift
argsFields: [
    FieldMeta(name: "repo", description: "owner/repo", fieldType: .string, required: true),
    FieldMeta(name: "branch", description: "Branch name", fieldType: .string, required: false),
]
```

```sh
tool clone owner/repo main
#          ^^^^^^^^^^ ^^^^
#          repo       branch
```

### Options

```swift
optionsFields: [
    FieldMeta(name: "state", fieldType: .enum(["open", "closed"]),
              defaultValue: "open"),
    FieldMeta(name: "limit", fieldType: .number, defaultValue: 30),
    FieldMeta(name: "label", fieldType: .array(.string), required: false),
    FieldMeta(name: "verbose", fieldType: .boolean, required: false),
]
```

Supported parsing:

- `--flag value` and `--flag=value`
- `-f value` short aliases (via `alias:` on `FieldMeta` or via `aliases:` map)
- `-abc` stacked short aliases — all but the last must be boolean or count
- `-vvv` count flag incrementing
- `--verbose` boolean flags (`true`), `--no-verbose` (`false`)
- `--label bug --label feature` array options
- Automatic type coercion (string → number, string → boolean)
- Defaults from `defaultValue:`, optionality from `required: false`

### Aliases

Set on `FieldMeta` directly:

```swift
FieldMeta(name: "state", fieldType: .string, alias: "s")
FieldMeta(name: "limit", fieldType: .number, alias: "l")
```

Or via the `aliases:` parameter on `CommandDef` (overrides field-level aliases):

```swift
aliases: ["state": "s", "limit": "l"]
```

```sh
tool list -s closed -l 10
```

### Deprecated options

Mark options as deprecated with `@Incur(deprecated: "...")` on the macro side, or `deprecated: true` on a hand-rolled `FieldMeta`. Shows `[deprecated]` in `--help`, `**Deprecated.**` in skill docs, `deprecated: true` in JSON Schema, and emits a stderr warning in TTY mode.

```swift
@IncurOptions
struct DeployOptions {
    /// Availability zone
    @Incur(deprecated: "Use --region instead")
    var zone: String?

    /// Target region
    var region: String?
}
```

### Environment variables

Declare an env schema with `@IncurEnv` (or `envFields:` on `CommandDef`). Values are read from `ProcessInfo.processInfo.environment` and coerced.

```swift
@IncurEnv
struct AppEnv {
    /// Auth token
    @Incur(env: "NPM_TOKEN")
    var npmToken: String?

    /// Registry URL
    @Incur(env: "NPM_REGISTRY", default: "https://registry.npmjs.org")
    var npmRegistry: String
}
```

### Usage patterns

Provide alternative usage strings to show in `--help`:

```swift
CommandDef(
    name: "curl-md",
    argsFields: [FieldMeta(name: "url", fieldType: .string, required: true)],
    optionsFields: [
        FieldMeta(name: "objective", fieldType: .string, required: false),
    ],
    usagePatterns: [
        UsagePattern(args: ["url"]),
        UsagePattern(args: ["url"], options: ["objective"]),
        UsagePattern(prefix: "cat file.txt |", suffix: "| head"),
    ],
    handler: CurlHandler()
)
```

Renders as:

```
Usage: curl-md <url>
       curl-md <url> --objective <objective>
       cat file.txt | curl-md | head
```

## Output

Every handler returns a `CommandResult`. incur wraps the data in a structured envelope and serializes to the requested format.

### Output schema

Define `outputSchema` to declare the return shape. The runtime validates handler output against it:

```swift
CommandDef(
    name: "info",
    outputSchema: .object([
        "name": .string,
        "version": .string,
    ]),
    handler: InfoHandler()
)
```

### Formats

Control with `--format <fmt>` or `--json`:

| Flag             | Format   | Description                                   |
| ---------------- | -------- | --------------------------------------------- |
| _(default)_      | TOON     | Token-efficient, ~40% fewer tokens than JSON  |
| `--format json`  | JSON     | `JSONSerialization`-safe                      |
| `--format yaml`  | YAML     | Human-readable                                |
| `--format md`    | Markdown | Tables for docs/issues                        |
| `--format jsonl` | NDJSON   | One JSON line per stream chunk                |
| `--format table` | Table    | ASCII column layout                           |
| `--format csv`   | CSV      | Comma-separated values                        |

### Envelope

With `--verbose`, the full envelope is emitted:

```sh
tool info express --verbose
```

```
ok: true
data:
  name: express
  version: 4.21.2
meta:
  command: info
  duration: 12ms
```

Without `--verbose`, only `data` is emitted. On errors, only the `error` block is emitted.

### Filtering output

Use `--filter-output` to prune command output to specific keys. Supports dot-notation for nested access, array slices with `[start,end]`, and comma-separated paths:

```sh
tool users --filter-output users.name
tool users --filter-output users[0,2].name
tool users --filter-output id,title,nested.value
```

The filter implementation lives in `Sources/Incur/Filter.swift` and is shared across CLI and HTTP transports.

### Token pagination

Use `--token-count`, `--token-limit`, and `--token-offset` to manage large outputs. Tokens are estimated using LLM tokenization rules:

```sh
# Check token count
tool users --token-count
# → 42

# Limit to first 20 tokens
tool users --token-limit 20

# Paginate with offset
tool users --token-offset 20 --token-limit 20
```

With `--verbose`, truncated output includes `meta.nextOffset` for programmatic pagination.

### Command schema

Use `--schema` to print the JSON Schema for a command's arguments, environment variables, options, and output:

```sh
tool install --schema
tool install --schema --format json   # machine-readable
```

Not supported on fetch-gateway commands.

### TTY detection

incur adapts output based on whether stdout is a TTY:

| Scenario              | TTY (human)             | Non-TTY (agent/pipe) |
| --------------------- | ----------------------- | -------------------- |
| Command output        | Formatted data only     | TOON envelope        |
| Errors                | Human-readable message  | Error envelope       |
| `--help`              | Pretty help text        | Same                 |
| `--json` / `--format` | Overrides to structured | Same                 |

## Run Context

`CommandContext` is what handlers receive in `run(_ ctx:)`.

### `agent` boolean

`ctx.agent` is `true` when stdout is not a TTY (piped or consumed by an agent), `false` when running in a terminal:

```swift
struct DeployHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        if !ctx.agent {
            print("Deploying...")
        }
        return .ok(data: ["status": "ok"])
    }
}
```

### `.ok()` and `.error()` helpers

`CommandResult` has variants for explicit result control:

```swift
struct GetHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let id = ctx.args["id"]?.intValue ?? 0
        guard let item = await db.find(id) else {
            return .error(
                code: "NOT_FOUND",
                message: "Item \(id) not found",
                retryable: false,
                exitCode: 1
            )
        }
        return .ok(data: item.toJSONValue())
    }
}
```

### CTAs (Call to Action)

Suggest next commands to guide agents on success:

```swift
return .ok(
    data: ["id": 42, "name": .string(ctx.args["name"]?.stringValue ?? "")],
    cta: CtaBlock(
        commands: [
            .detailed(command: "get 42", description: "View the item"),
            .simple("list"),
        ],
        description: "Suggested commands:"
    )
)
```

Or on errors, to help agents self-correct:

```swift
return .error(
    code: "NOT_AUTHENTICATED",
    message: "GitHub token not found",
    retryable: true,
    exitCode: 1,
    cta: CtaBlock(
        commands: [
            .detailed(command: "auth login", description: "Log in to GitHub"),
            .detailed(command: "config set --token <token>", description: "Set token manually"),
        ],
        description: "To authenticate:"
    )
)
```

## Agent Discovery

### MCP Server

Every incur-swift CLI has built-in Model Context Protocol (MCP) support — exposing commands as MCP tools that agents can call directly. The implementation lives under `Sources/Incur/Mcp.swift` and uses the `swift-sdk` MCP package.

#### `mcp add` built-in command

Register the CLI as an MCP server for your agents:

```sh
my-cli mcp add
```

This registers the CLI with your agent's MCP config. Works with Claude Code, Cursor, Amp, and others out of the box (21 agents supported via `Sources/Incur/Agents.swift`).

Options:

| Flag              | Description                                              |
| ----------------- | -------------------------------------------------------- |
| `-c`, `--command` | Override the command agents will run to start the server |
| `--agent <agent>` | Target a specific agent (e.g. `claude-code`, `cursor`)   |
| `--no-global`     | Install to project instead of globally                   |

#### `--mcp` flag

Start the CLI as an MCP stdio server:

```sh
my-cli --mcp
```

This exposes all commands as MCP tools over stdin/stdout. Command groups are flattened with underscores (e.g. `pr_list`, `pr_view`). Arguments and options are merged into a single flat input schema.

### Skills

All incur-swift CLIs can auto-generate and install agent skill files with `skills add`:

```sh
my-cli skills add
```

This generates Markdown skill files from your command definitions and installs them so agents discover your CLI automatically.

#### Configuration

Configure `skills add` on the root `Cli`:

```swift
let cli = Cli("my-cli")
    .sync(SyncConfig(
        depth: 1,
        include: ["_root"],
        suggestions: ["install react as a dependency", "check for outdated packages"]
    ))
```

| Option        | Type       | Description                                                                                          |
| ------------- | ---------- | ---------------------------------------------------------------------------------------------------- |
| `depth`       | `Int`      | Grouping depth for skill files. `0` = single file, `1` = one per top-level command. Default: `1`     |
| `include`     | `[String]` | Glob patterns for additional `SKILL.md` files to include. Use `"_root"` for the project-level SKILL.md |
| `suggestions` | `[String]` | Example prompts shown after sync to help users get started                                           |

### `--llms` flag

Every incur-swift CLI gets a built-in `--llms` flag that outputs a machine-readable manifest of all commands:

```sh
tool --llms          # Markdown skill documentation (default)
tool --llms-full     # Full skill manifest including hidden commands
tool --llms --format json    # JSON Schema manifest
```

Markdown sample:

```md
# tool install

Install a package

## Arguments

| Name      | Type     | Required | Description             |
| --------- | -------- | -------- | ----------------------- |
| `package` | `string` | no       | Package name to install |

## Options

| Flag         | Type      | Default | Description            |
| ------------ | --------- | ------- | ---------------------- |
| `--save-dev` | `boolean` |         | Save as dev dependency |
| `--global`   | `boolean` |         | Install globally       |
```

JSON sample:

```json
{
  "version": "incur.v1",
  "commands": [
    {
      "name": "install",
      "description": "Install a package",
      "schema": {
        "args":    { "type": "object", "properties": { "package": { "type": "string" } } },
        "options": { "type": "object", "properties": { "save_dev": { "type": "boolean" } } },
        "output":  { "type": "object", "properties": { "added":    { "type": "number" } } }
      }
    }
  ]
}
```

## Built-in Flags

| Flag                    | Description                                          |
| ----------------------- | ---------------------------------------------------- |
| `--help`, `-h`          | Show help for the CLI or a specific command          |
| `--version`             | Print CLI version                                    |
| `--llms`                | Output agent-readable command manifest               |
| `--llms-full`           | Output full skill manifest                           |
| `--mcp`                 | Start as an MCP stdio server                         |
| `--json`                | Shorthand for `--format json`                        |
| `--format <fmt>`        | Output format (toon, json, yaml, md, jsonl, table, csv) |
| `--verbose`             | Include full envelope (`ok`, `data`, `meta`)         |
| `--filter-output <k>`   | Prune output to specific keys                        |
| `--schema`              | JSON Schema for command input                        |
| `--token-count`         | Print token count for output                         |
| `--token-limit <n>`     | Truncate output to N tokens                          |
| `--token-offset <n>`    | Skip first N tokens (paginate)                       |
| `completions <shell>`   | Generate shell completions (bash, zsh, fish, nushell) |
| `skills add`            | Sync skill files to AI agents                        |
| `mcp add`               | Register as MCP server with AI agents                |

## Examples

### Typed examples on commands

```swift
CommandDef(
    name: "deploy",
    argsFields: [
        FieldMeta(name: "env", fieldType: .enum(["staging", "production"]), required: true),
    ],
    optionsFields: [FieldMeta(name: "force", fieldType: .boolean)],
    examples: [
        Example(command: "staging", description: "Deploy to staging"),
        Example(command: "production --force", description: "Force deploy to prod"),
    ],
    handler: DeployHandler()
)
```

Examples appear in `--help` output and generated skill files.

### Hints

```swift
CommandDef(
    name: "publish",
    hint: "Requires NPM_TOKEN to be set in your environment.",
    handler: PublishHandler()
)
```

Hints display after examples in help output and are included in skill files.

### Output policy

Control whether output data is displayed to humans. `.all` (default) shows output to everyone. `.agentOnly` suppresses data in human/TTY mode while still returning it via `--json`, `--format`, or `--verbose`.

```swift
CommandDef(
    name: "deploy",
    outputPolicy: .agentOnly,
    handler: DeployHandler()
)
```

Set on a group or root CLI to inherit across children. Children can override per-command.

## Middleware

Register composable before/after hooks with `cli.useMiddleware(_:)`. Middleware executes in registration order, onion-style. Each calls `await next()` to proceed.

```swift
let cli = Cli("deploy-cli")
    .description("Deploy tools")
    .useMiddleware { @Sendable ctx, next in
        let start = Date()
        await next()
        print("took \(Date().timeIntervalSince(start) * 1000)ms")
    }
    .command("deploy", CommandDef(name: "deploy", handler: DeployHandler()))
```

```sh
$ deploy-cli deploy
# → deployed: true
# took 12ms
```

Middleware on a sub-CLI only applies to its commands:

```swift
let admin = Cli("admin")
    .description("Admin commands")
    .useMiddleware { @Sendable ctx, next in
        guard isAdmin() else {
            fputs("forbidden\n", stderr)
            return
        }
        await next()
    }
    .command("reset", CommandDef(name: "reset", handler: ResetHandler()))

cli.group(admin)
```

Per-command middleware runs after root and group middleware, and only for that command:

```swift
let requireAuth: MiddlewareFn = { @Sendable ctx, next in
    guard ctx.vars["user"] != nil else {
        fputs("must be logged in\n", stderr)
        return
    }
    await next()
}

cli.command("deploy", CommandDef(
    name: "deploy",
    middleware: [requireAuth],
    handler: DeployHandler()
))
```

Middleware does **not** run for built-in commands (`--help`, `--llms`, `--mcp`, `mcp add`, `skills add`).

### Vars — typed dependency injection

Middleware sets typed variables via `ctx.vars`; handlers read them via the same map. Use `defaultValue:` on the var schema for vars that don't need middleware:

```swift
let cli = Cli("my-cli")
    .description("My CLI")
    .vars([
        FieldMeta(name: "user",       fieldType: .string),
        FieldMeta(name: "request_id", fieldType: .string),
        FieldMeta(name: "debug",      fieldType: .boolean, defaultValue: false),
    ])
    .useMiddleware { @Sendable ctx, next in
        ctx.vars["user"] = .string(await authenticate())
        ctx.vars["request_id"] = .string(UUID().uuidString)
        await next()
    }
    .command("whoami", CommandDef(name: "whoami", handler: WhoAmIHandler()))
```

```sh
$ my-cli whoami
# → user: u_123
# → request_id: 550e8400-...
# → debug: false
```

## Serving

Call `serve()` to parse argv from `CommandLine.arguments` and run:

```swift
try await cli.serve()
```

For testing, pass custom argv and DI overrides:

```swift
var output = ""
try await cli.serve(
    argv: ["install", "express", "--json"],
    stdout: { output += $0 },
    exit:   { _ in },
    env:    [:]
)
```

### `serve()` parameters

| Parameter | Type                              | Description                    |
| --------- | --------------------------------- | ------------------------------ |
| `argv`    | `[String]?`                       | Override `CommandLine.arguments` (default: read from process) |
| `stdout`  | `(@Sendable (String) -> Void)?`   | Override stdout writer         |
| `exit`    | `(@Sendable (Int32) -> Void)?`    | Override exit handler          |
| `env`     | `[String: String]?`               | Override environment variables |

## Streaming

Return `.stream(_:)` to emit chunks incrementally over an `AsyncStream<JSONValue>`:

```swift
struct LogsHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let stream = AsyncStream<JSONValue> { continuation in
            Task {
                continuation.yield(.string("connecting..."))
                continuation.yield(.string("streaming logs"))
                continuation.yield(.string("done"))
                continuation.finish()
            }
        }
        return .stream(stream)
    }
}
```

Each yielded value is written as a line in human/TOON mode. With `--format jsonl`, each chunk becomes `{"type":"chunk","data":"..."}`. You can also yield objects:

```swift
continuation.yield(["progress": 50])
continuation.yield(["progress": 100])
```

## Type Generation

The macro layer (`@IncurArgs`, `@IncurOptions`, `@IncurEnv`) is incur-swift's equivalent of TS's `incur gen` codegen. The macros expand at compile time to produce typed `[FieldMeta]` arrays. There is no separate codegen step.

If you need a wire-level manifest for an external tool, run:

```sh
my-cli --llms --format json
```

…and feed the JSON Schema output to your generator.

## Status / Parity

incur-swift tracks the upstream TypeScript `incur` package as its spec. Parity with `incur@0.3.x` is in progress; many features (token pagination, `--filter-output`, vars/DI, sync skills, OpenAPI gateway, fetch handler, type generation) have landed in either both or partial form. See the project `README.md` for the up-to-date status table.

## Full Example

```swift
import Foundation
import Incur

struct InstallHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        let pkg = ctx.args["package"]?.stringValue
        if pkg == nil { return .ok(data: ["added": 120, "packages": 450]) }
        return .ok(data: ["added": 1, "packages": 451])
    }
}

struct OutdatedHandler: CommandHandler {
    func run(_ ctx: CommandContext) async -> CommandResult {
        .ok(data: [
            "packages": [
                ["name": "express", "current": "4.18.0", "wanted": "4.21.2", "latest": "4.21.2"],
            ],
        ])
    }
}

@main
struct NpmCLI {
    static func main() async {
        let cli = Cli("npm")
            .version("10.9.2")
            .description("The package manager for JavaScript.")

            .command("install", CommandDef(
                name: "install",
                description: "Install a package",
                argsFields: [
                    FieldMeta(name: "package", description: "Package name to install",
                              fieldType: .string, required: false),
                ],
                optionsFields: [
                    FieldMeta(name: "save_dev", description: "Save as dev dependency",
                              fieldType: .boolean, alias: "D"),
                    FieldMeta(name: "global",   description: "Install globally",
                              fieldType: .boolean, alias: "g"),
                ],
                aliases: ["save_dev": "D", "global": "g"],
                examples: [
                    Example(command: "express", description: "Install a package"),
                    Example(command: "vitest --save-dev", description: "Install as dev dependency"),
                ],
                handler: InstallHandler()
            ))

            .command("outdated", CommandDef(
                name: "outdated",
                description: "Check for outdated packages",
                optionsFields: [
                    FieldMeta(name: "global", description: "Check global packages",
                              fieldType: .boolean, alias: "g"),
                ],
                handler: OutdatedHandler()
            ))

        do {
            try await cli.serve()
        } catch {
            fputs("Error: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
```
