/// The main CLI type for the incur framework.
///
/// This module provides `Cli`, the entry point for building command-line
/// applications with incur. It supports:
///
/// - Registering commands and command groups
/// - Middleware that runs around every command
/// - Built-in flags (--help, --version, --format, --json, --verbose, etc.)
/// - Config file loading for option defaults
/// - Three-transport architecture (CLI, HTTP, MCP)
///
/// Ported from `cli.rs`.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Entry in the command tree.
public enum CommandEntry: Sendable {
    /// A leaf command that can be executed.
    case leaf(CommandDef)
    /// A group of subcommands (acts as a namespace).
    case group(description: String?, commands: [String: CommandEntry], middleware: [MiddlewareFn], outputPolicy: OutputPolicy?)
    /// A fetch gateway that proxies curl-style requests to a handler.
    case fetchGateway(handler: any FetchHandler, options: FetchGatewayOptions)

    /// Returns the description of this entry.
    public var description: String? {
        switch self {
        case .leaf(let def): return def.description
        case .group(let desc, _, _, _): return desc
        case .fetchGateway(_, let opts): return opts.description
        }
    }
}

/// Config file options for a CLI.
public struct ConfigOptions: Sendable {
    public let flag: String
    public let files: [String]

    public init(flag: String, files: [String] = []) {
        self.flag = flag
        self.files = files
    }
}

/// The main CLI builder and executor.
public final class Cli: @unchecked Sendable {
    public let name: String
    public var cliDescription: String?
    public var version: String?
    public var aliases: [String] = []
    public var commands: [String: CommandEntry] = [:]
    public var middlewareHandlers: [MiddlewareFn] = []
    public var rootCommand: CommandDef?
    public var envFields: [FieldMeta] = []
    public var varsFields: [FieldMeta] = []
    public var config: ConfigOptions?
    public var outputPolicy: OutputPolicy?
    public var defaultFormat: Format?

    public init(_ name: String) {
        self.name = name
    }

    // MARK: - Builder Methods

    @discardableResult
    public func description(_ desc: String) -> Cli {
        self.cliDescription = desc
        return self
    }

    @discardableResult
    public func version(_ v: String) -> Cli {
        self.version = v
        return self
    }

    @discardableResult
    public func aliases(_ aliases: [String]) -> Cli {
        self.aliases = aliases
        return self
    }

    @discardableResult
    public func format(_ format: Format) -> Cli {
        self.defaultFormat = format
        return self
    }

    @discardableResult
    public func root(_ def: CommandDef) -> Cli {
        self.rootCommand = def
        return self
    }

    @discardableResult
    public func command(_ name: String, _ def: CommandDef) -> Cli {
        self.commands[name] = .leaf(def)
        return self
    }

    @discardableResult
    public func fetchGateway(_ name: String, handler: any FetchHandler, options: FetchGatewayOptions = FetchGatewayOptions()) -> Cli {
        self.commands[name] = .fetchGateway(handler: handler, options: options)
        return self
    }

    @discardableResult
    public func group(_ cli: Cli) -> Cli {
        if let rootCmd = cli.rootCommand, cli.commands.isEmpty {
            self.commands[cli.name] = .leaf(rootCmd)
        } else {
            self.commands[cli.name] = .group(
                description: cli.cliDescription,
                commands: cli.commands,
                middleware: cli.middlewareHandlers,
                outputPolicy: cli.outputPolicy
            )
        }
        return self
    }

    @discardableResult
    public func useMiddleware(_ handler: @escaping MiddlewareFn) -> Cli {
        self.middlewareHandlers.append(handler)
        return self
    }

    // MARK: - Serve

    /// Parses process argv, runs the matched command, writes output to stdout.
    public func serve() async throws {
        let argv = Array(CommandLine.arguments.dropFirst())
        try await serveWith(argv)
    }

    /// Serves with explicit argv (useful for testing).
    public func serveWith(_ argv: [String]) async throws {
        let human = isatty(fileno(stdout)) != 0
        let isAgent = !human
        let configFlag = config?.flag

        // Step 1: Extract built-in flags
        let builtin = extractBuiltinFlags(argv, configFlag: configFlag)

        // --json forces agent-style output even on TTY
        let effectiveHuman = builtin.json ? false : human

        // Step 2: Handle --version
        if builtin.version && !builtin.help {
            if let v = version {
                writelnStdout(v)
                return
            }
        }

        // Handle --config-schema
        if builtin.configSchema {
            let rootOpts = rootCommand?.optionsFields ?? []
            let schema = generateConfigSchema(commands: commands, rootOptions: rootOpts)
            writelnStdout(schema.toJSON(pretty: true))
            return
        }

        // Handle --mcp
        if builtin.mcp {
            try await serveMcp(
                name: name,
                version: version ?? "0.0.0",
                commands: commands,
                middleware: middlewareHandlers,
                envFields: envFields
            )
            return
        }

        // Handle --llms / --llms-full
        if builtin.llms || builtin.llmsFull {
            let skillCommands = collectSkillCommandInfo(commands)
            if builtin.llmsFull {
                writelnStdout(skillGenerate(name: name, commands: skillCommands))
            } else {
                writelnStdout(skillIndex(name: name, commands: skillCommands, description: cliDescription))
            }
            return
        }

        // Handle completions
        if let completeShell = ProcessInfo.processInfo.environment["COMPLETE"],
           let shell = Shell.from(completeShell) {
            let indexStr = ProcessInfo.processInfo.environment["_COMPLETE_INDEX"] ?? "0"
            let index = Int(indexStr) ?? 0
            let completionCommands = buildCompletionCommands(commands)
            let rootDef = rootCommand.map { CompletionCommandDef(optionsFields: $0.optionsFields, aliases: $0.aliases) }
            let candidates = computeCompletions(commands: completionCommands, rootCommand: rootDef, argv: argv, index: index)
            writelnStdout(formatCompletions(shell: shell, candidates: candidates))
            return
        }

        // Handle `completions <shell>` command
        if let cmdIdx = builtin.rest.firstIndex(of: "completions") {
            let shell = builtin.rest.count > cmdIdx + 1 ? builtin.rest[cmdIdx + 1] : nil
            if builtin.help || shell == nil {
                writelnStdout(formatCommandHelp(
                    name: "\(name) completions",
                    options: FormatCommandOptions(
                        argsFields: [FieldMeta(name: "shell", description: "Shell to generate completions for (bash, zsh, fish, nushell)", fieldType: .enum(["bash", "zsh", "fish", "nushell"]), required: true)],
                        description: "Generate shell completion script",
                        hideGlobalOptions: true
                    )
                ))
                return
            }
            if let shell, let s = Shell.from(shell) {
                let output = ([name] + aliases).map { registerCompletion(shell: s, name: $0) }.joined(separator: "\n")
                writelnStdout(output)
            } else {
                writelnStdout(formatHumanError(code: "INVALID_SHELL", message: "Unknown shell '\(shell ?? "")'. Supported: bash, fish, nushell, zsh"))
                exit(1)
            }
            return
        }

        // Handle `skills add`
        if builtin.rest.count >= 1 && builtin.rest[0] == "skills" {
            if builtin.rest.count < 2 || builtin.rest[1] != "add" {
                // Show skills help
                writelnStdout(formatCommandHelp(
                    name: "\(name) skills",
                    options: FormatCommandOptions(
                        commands: [CommandSummary(name: "add", description: "Sync skill files to agents")],
                        description: "Sync skill files to agents"
                    )
                ))
                return
            }

            if builtin.help {
                writelnStdout(formatCommandHelp(
                    name: "\(name) skills add",
                    options: FormatCommandOptions(
                        description: "Sync skill files to agents",
                        hideGlobalOptions: true,
                        optionsFields: [
                            FieldMeta(name: "depth", description: "Grouping depth for skill files", fieldType: .number, defaultValue: 1),
                            FieldMeta(name: "no_global", cliName: "no-global", description: "Install to project directory instead of globally", fieldType: .boolean),
                        ]
                    )
                ))
                return
            }

            let rest = Array(builtin.rest.dropFirst(2))

            // Parse --depth
            var depth = 1
            if let depthIdx = rest.firstIndex(of: "--depth") {
                if depthIdx + 1 < rest.count, let d = Int(rest[depthIdx + 1]) {
                    depth = d
                }
            } else if let token = rest.first(where: { $0.hasPrefix("--depth=") }) {
                if let eqIdx = token.firstIndex(of: "=") {
                    let val = String(token[token.index(after: eqIdx)...])
                    if let d = Int(val) { depth = d }
                }
            }

            let noGlobal = rest.contains("--no-global")

            let skillCommands = collectSkillCommandInfo(commands)

            do {
                let result = try await syncSkills(
                    name: name,
                    commands: skillCommands,
                    options: SyncOptions(
                        depth: depth,
                        description: cliDescription,
                        global: !noGlobal
                    )
                )

                var lines = ["Synced \(result.skills.count) skill\(result.skills.count == 1 ? "" : "s")"]
                for skill in result.skills {
                    lines.append("  \(skill.name)")
                }
                writelnStdout(lines.joined(separator: "\n"))

                if builtin.verbose || builtin.formatExplicit {
                    var output = OrderedMap()
                    output["skills"] = .array(result.paths.map { .string($0.path) })
                    if builtin.verbose {
                        output["agents"] = .array(result.agents.map { agent in
                            var obj = OrderedMap()
                            obj["agent"] = .string(agent.agent)
                            obj["path"] = .string(agent.path.path)
                            obj["mode"] = .string(agent.mode == .symlink ? "symlink" : "copy")
                            return JSONValue.object(obj)
                        })
                    }
                    let effectiveFormat = builtin.formatExplicit
                        ? (builtin.formatValue.flatMap(Format.from) ?? .toon)
                        : .toon
                    writelnStdout(formatValue(.object(output), format: effectiveFormat))
                }
            } catch {
                writelnStdout(formatHumanError(code: "SYNC_SKILLS_FAILED", message: error.localizedDescription))
                exit(1)
            }
            return
        }

        // Handle `mcp add`
        if builtin.rest.count >= 1 && builtin.rest[0] == "mcp" {
            if builtin.rest.count < 2 || builtin.rest[1] != "add" {
                // Show mcp help
                writelnStdout(formatCommandHelp(
                    name: "\(name) mcp",
                    options: FormatCommandOptions(
                        commands: [CommandSummary(name: "add", description: "Register as MCP server")],
                        description: "Register as MCP server"
                    )
                ))
                return
            }

            if builtin.help {
                writelnStdout(formatCommandHelp(
                    name: "\(name) mcp add",
                    options: FormatCommandOptions(
                        description: "Register as MCP server with coding agents",
                        hideGlobalOptions: true,
                        optionsFields: [
                            FieldMeta(name: "command", cliName: "command", description: "Override the command agents will run", fieldType: .string, alias: "c"),
                            FieldMeta(name: "agent", cliName: "agent", description: "Target specific agent (can be repeated)", fieldType: .string),
                            FieldMeta(name: "no_global", cliName: "no-global", description: "Install to project directory instead of globally", fieldType: .boolean),
                        ],
                        optionAliases: ["command": "c"]
                    )
                ))
                return
            }

            let rest = Array(builtin.rest.dropFirst(2))

            // Parse --command / -c, --agent, --no-global
            var mcpCommand: String? = nil
            var agents: [String] = []
            var cursor = 0

            while cursor < rest.count {
                if (rest[cursor] == "--command" || rest[cursor] == "-c"),
                   cursor + 1 < rest.count {
                    mcpCommand = rest[cursor + 1]
                    cursor += 2
                    continue
                }
                if rest[cursor] == "--agent", cursor + 1 < rest.count {
                    agents.append(rest[cursor + 1])
                    cursor += 2
                    continue
                }
                cursor += 1
            }

            let noGlobal = rest.contains("--no-global")

            do {
                let result = try await registerMcp(
                    name: name,
                    options: RegisterOptions(
                        agents: agents.isEmpty ? nil : agents,
                        command: mcpCommand,
                        global: !noGlobal
                    )
                )

                var lines = ["Registered \(name) as MCP server"]
                if !result.agents.isEmpty {
                    lines.append("Agents: \(result.agents.joined(separator: ", "))")
                }
                writelnStdout(lines.joined(separator: "\n"))

                if builtin.verbose || builtin.formatExplicit {
                    var output = OrderedMap()
                    output["name"] = .string(name)
                    output["command"] = .string(result.command)
                    output["agents"] = .array(result.agents.map { .string($0) })
                    let effectiveFormat = builtin.formatExplicit
                        ? (builtin.formatValue.flatMap(Format.from) ?? .toon)
                        : .toon
                    writelnStdout(formatValue(.object(output), format: effectiveFormat))
                }
            } catch {
                writelnStdout(formatHumanError(code: "MCP_ADD_FAILED", message: error.localizedDescription))
                exit(1)
            }
            return
        }

        // Step 3: Handle no-args case
        if builtin.rest.isEmpty && !builtin.help && !builtin.schema {
            if let rootCmd = rootCommand {
                if human && rootCmd.argsFields.contains(where: \.required) {
                    writelnStdout(formatLeafCommandHelp(rootCmd, isRoot: true))
                    return
                }
                // Fall through to execute root command
            } else {
                writelnStdout(formatRootHelp(
                    name: name,
                    options: FormatRootOptions(
                        aliases: aliases.isEmpty ? nil : aliases,
                        configFlag: configFlag,
                        commands: collectHelpCommands(commands),
                        description: cliDescription,
                        root: true,
                        version: version
                    )
                ))
                return
            }
        }

        // Step 4: Resolve command from argv
        let resolved: ResolvedCommand
        if builtin.rest.isEmpty {
            if let rootCmd = rootCommand {
                resolved = .leaf(command: rootCmd, path: name, rest: [], collectedMiddleware: [])
            } else {
                resolved = .help(path: name, description: cliDescription, subcommands: commands)
            }
        } else {
            resolved = resolveCommand(commands: commands, tokens: builtin.rest)
        }

        // Step 5: Handle --schema
        if builtin.schema {
            switch resolved {
            case .leaf(let command, _, _, _):
                let schema = generateCommandSchema(command: command)
                writelnStdout(schema.toJSON(pretty: true))
            case .gateway:
                // Fetch gateways don't have a static schema
                writelnStdout("{\"type\":\"object\",\"description\":\"Fetch gateway - accepts curl-style arguments\"}")
            case .help:
                // For groups/root, generate config-style schema
                let rootOpts = rootCommand?.optionsFields ?? []
                let schema = generateConfigSchema(commands: commands, rootOptions: rootOpts)
                writelnStdout(schema.toJSON(pretty: true))
            case .notFound(let token):
                if effectiveHuman {
                    writelnStdout(formatHumanError(code: "COMMAND_NOT_FOUND", message: "Unknown command: \(token)"))
                } else {
                    writelnStdout("{\"ok\":false,\"error\":{\"code\":\"COMMAND_NOT_FOUND\",\"message\":\"Unknown command: \(token)\"}}")
                }
                exit(1)
            }
            return
        }

        // Step 6: Handle --help
        if builtin.help {
            switch resolved {
            case .leaf(let command, let path, _, _):
                let isRoot = path == name
                let helpCmds = isRoot && !commands.isEmpty ? collectHelpCommands(commands) : []
                writelnStdout(formatCommandHelp(
                    name: isRoot ? name : "\(name) \(path)",
                    options: FormatCommandOptions(
                        argsFields: command.argsFields,
                        configFlag: configFlag,
                        commands: helpCmds,
                        description: command.description,
                        envFields: command.envFields,
                        examples: command.examples,
                        hint: command.hint,
                        optionsFields: command.optionsFields,
                        optionAliases: command.aliases,
                        root: isRoot,
                        version: isRoot ? version : nil
                    )
                ))
            case .gateway(_, let opts, let path, _):
                writelnStdout(formatCommandHelp(
                    name: "\(name) \(path)",
                    options: FormatCommandOptions(
                        description: opts.description ?? "Fetch gateway",
                        hint: "Accepts curl-style arguments: -X METHOD, -H header, -d body, --key value (query params)"
                    )
                ))
            case .help(let path, let description, let subcommands):
                writelnStdout(formatRootHelp(
                    name: path == name ? name : "\(name) \(path)",
                    options: FormatRootOptions(
                        configFlag: configFlag,
                        commands: collectHelpCommands(subcommands),
                        description: description,
                        root: path == name,
                        version: path == name ? version : nil
                    )
                ))
            case .notFound(let token):
                writelnStdout(formatHumanError(code: "COMMAND_NOT_FOUND", message: "Unknown command: \(token)"))
                exit(1)
            }
            return
        }

        // Step 7: Validate --format value before executing
        if let formatStr = builtin.formatValue, Format.from(formatStr) == nil {
            if effectiveHuman {
                writelnStdout(formatHumanError(code: "INVALID_FORMAT", message: "Unknown format '\(formatStr)'. Supported: toon, json, yaml, md, jsonl, table, csv"))
            } else {
                let errJSON: JSONValue = [
                    "ok": false,
                    "error": [
                        "code": .string("INVALID_FORMAT"),
                        "message": .string("Unknown format '\(formatStr)'. Supported: toon, json, yaml, md, jsonl, table, csv"),
                    ]
                ]
                writelnStdout(errJSON.toJSON(pretty: false))
            }
            exit(1)
        }

        // Step 8: Execute command
        switch resolved {
        case .leaf(let command, let path, let rest, let collectedMiddleware):
            // Determine format
            let effectiveFormat = builtin.json ? .json : (builtin.formatValue.flatMap(Format.from) ?? command.format ?? defaultFormat ?? .toon)

            // Load config defaults
            var configDefaults: OrderedMap? = nil
            if let configOptions = config, !builtin.noConfig {
                let configPath = resolveConfigPath(
                    explicit: builtin.configValue,
                    files: configOptions.files
                )
                if let configPath {
                    do {
                        let configData = try loadConfig(path: configPath)
                        configDefaults = try extractCommandSection(
                            config: configData,
                            cliName: name,
                            commandPath: path
                        )
                    } catch {
                        if effectiveHuman {
                            writelnStdout(formatHumanError(code: "CONFIG_ERROR", message: error.localizedDescription))
                        } else {
                            let errJSON: JSONValue = [
                                "ok": false,
                                "error": [
                                    "code": .string("CONFIG_ERROR"),
                                    "message": .string(error.localizedDescription),
                                ]
                            ]
                            writelnStdout(errJSON.toJSON(pretty: false))
                        }
                        exit(1)
                    }
                }
            }

            // Check output policy
            let effectivePolicy = command.outputPolicy ?? outputPolicy
            if case .agentOnly = effectivePolicy, effectiveHuman {
                // Suppress output for agentOnly commands when running interactively
                return
            }

            // Build env source from process environment
            let envSource = ProcessInfo.processInfo.environment

            // Collect all middleware
            let allMiddleware = middlewareHandlers + collectedMiddleware + command.middleware

            let startTime = DispatchTime.now()

            let result = await execute(
                command: command,
                options: ExecuteOptions(
                    agent: isAgent || builtin.json,
                    argv: rest,
                    defaults: configDefaults,
                    envFields: envFields,
                    envSource: envSource,
                    format: effectiveFormat,
                    formatExplicit: builtin.formatExplicit,
                    middlewares: allMiddleware,
                    name: name,
                    parseMode: .argv,
                    path: path,
                    version: version
                )
            )

            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

            // Output the result
            await outputResult(
                result,
                format: effectiveFormat,
                human: effectiveHuman,
                verbose: builtin.verbose,
                filterExpr: builtin.filterOutput,
                tokenCount: builtin.tokenCount,
                tokenLimit: builtin.tokenLimit,
                tokenOffset: builtin.tokenOffset,
                commandPath: path,
                duration: elapsed
            )

        case .gateway(let handler, let opts, let path, let rest):
            let effectiveFormat = builtin.json ? Format.json : (builtin.formatValue.flatMap(Format.from) ?? defaultFormat ?? .toon)

            // Check output policy
            if case .agentOnly = opts.outputPolicy, effectiveHuman {
                return
            }

            let fetchInput = parseFetchArgv(rest)

            // Apply base path if configured
            var input = fetchInput
            if let basePath = opts.basePath, !basePath.isEmpty {
                input = FetchInput(
                    path: basePath + fetchInput.path,
                    method: fetchInput.method,
                    headers: fetchInput.headers,
                    body: fetchInput.body,
                    query: fetchInput.query
                )
            }

            let startTime = DispatchTime.now()
            let output = await handler.handle(input)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000

            if output.ok {
                let result: InternalResult = .ok(data: output.data, cta: nil)
                await outputResult(
                    result,
                    format: effectiveFormat,
                    human: effectiveHuman,
                    verbose: builtin.verbose,
                    filterExpr: builtin.filterOutput,
                    tokenCount: builtin.tokenCount,
                    tokenLimit: builtin.tokenLimit,
                    tokenOffset: builtin.tokenOffset,
                    commandPath: path,
                    duration: elapsed
                )
            } else {
                let result: InternalResult = .error(
                    code: "FETCH_ERROR",
                    message: "Request failed with status \(output.status)",
                    retryable: nil,
                    fieldErrors: nil,
                    cta: nil,
                    exitCode: 1
                )
                await outputResult(
                    result,
                    format: effectiveFormat,
                    human: effectiveHuman,
                    verbose: builtin.verbose,
                    filterExpr: builtin.filterOutput,
                    commandPath: path,
                    duration: elapsed
                )
            }

        case .help(let path, let description, let subcommands):
            writelnStdout(formatRootHelp(
                name: path == name ? name : "\(name) \(path)",
                options: FormatRootOptions(
                    configFlag: configFlag,
                    commands: collectHelpCommands(subcommands),
                    description: description,
                    root: path == name,
                    version: path == name ? version : nil
                )
            ))

        case .notFound(let token):
            if effectiveHuman {
                writelnStdout(formatHumanError(code: "COMMAND_NOT_FOUND", message: "Unknown command: \(token)"))
            } else {
                writelnStdout("{\"ok\":false,\"error\":{\"code\":\"COMMAND_NOT_FOUND\",\"message\":\"Unknown command: \(token)\"}}")
            }
            exit(1)
        }
    }

    // MARK: - Help Formatting

    private func formatLeafCommandHelp(_ command: CommandDef, isRoot: Bool) -> String {
        let helpCmds = isRoot && !commands.isEmpty ? collectHelpCommands(commands) : []
        return formatCommandHelp(
            name: isRoot ? name : "\(name) \(command.name)",
            options: FormatCommandOptions(
                aliases: aliases.isEmpty ? nil : aliases,
                argsFields: command.argsFields,
                configFlag: config?.flag,
                commands: helpCmds,
                description: command.description,
                envFields: command.envFields,
                examples: command.examples,
                hint: command.hint,
                optionsFields: command.optionsFields,
                optionAliases: command.aliases,
                root: isRoot,
                version: isRoot ? version : nil
            )
        )
    }
}

// MARK: - Builtin Flags

struct BuiltinFlags {
    var help = false
    var version = false
    var json = false
    var verbose = false
    var formatValue: String?
    var formatExplicit = false
    var filterOutput: String?
    var llms = false
    var llmsFull = false
    var mcp = false
    var configSchema = false
    var tokenCount = false
    var tokenLimit: Int?
    var tokenOffset: Int?
    var schema = false
    var configValue: String?
    var noConfig = false
    var rest: [String] = []
}

func extractBuiltinFlags(_ argv: [String], configFlag: String?) -> BuiltinFlags {
    var flags = BuiltinFlags()
    var i = 0

    // Pre-compute config flag patterns
    let configLong = configFlag.map { "--\($0)" }
    let configLongEq = configFlag.map { "--\($0)=" }
    let noConfigLong = configFlag.map { "--no-\($0)" }

    while i < argv.count {
        let token = argv[i]
        switch token {
        case "--help", "-h":
            flags.help = true
        case "--version":
            flags.version = true
        case "--json":
            flags.json = true
            flags.formatExplicit = true
        case "--verbose":
            flags.verbose = true
        case "--format":
            if i + 1 < argv.count {
                flags.formatValue = argv[i + 1]
                flags.formatExplicit = true
                i += 1
            }
        case _ where token.hasPrefix("--format="):
            flags.formatValue = String(token.dropFirst("--format=".count))
            flags.formatExplicit = true
        case "--filter-output":
            if i + 1 < argv.count {
                flags.filterOutput = argv[i + 1]
                i += 1
            }
        case _ where token.hasPrefix("--filter-output="):
            flags.filterOutput = String(token.dropFirst("--filter-output=".count))
        case "--llms":
            flags.llms = true
        case "--llms-full":
            flags.llmsFull = true
        case "--mcp":
            flags.mcp = true
        case "--config-schema":
            flags.configSchema = true
        case "--schema":
            flags.schema = true
        case "--token-count":
            flags.tokenCount = true
        case "--token-limit":
            if i + 1 < argv.count { flags.tokenLimit = Int(argv[i + 1]); i += 1 }
        case _ where token.hasPrefix("--token-limit="):
            flags.tokenLimit = Int(String(token.dropFirst("--token-limit=".count)))
        case "--token-offset":
            if i + 1 < argv.count { flags.tokenOffset = Int(argv[i + 1]); i += 1 }
        case _ where token.hasPrefix("--token-offset="):
            flags.tokenOffset = Int(String(token.dropFirst("--token-offset=".count)))
        case "--":
            // Everything after -- is treated as rest
            flags.rest.append(contentsOf: argv[(i + 1)...])
            return flags
        default:
            // Check config flag dynamically
            if let cl = configLong, token == cl {
                if i + 1 < argv.count { flags.configValue = argv[i + 1]; i += 1 }
            } else if let clEq = configLongEq, token.hasPrefix(clEq) {
                flags.configValue = String(token.dropFirst(clEq.count))
            } else if let ncl = noConfigLong, token == ncl {
                flags.noConfig = true
            } else {
                flags.rest.append(token)
            }
        }
        i += 1
    }
    return flags
}

// MARK: - Command Resolution

enum ResolvedCommand {
    case leaf(command: CommandDef, path: String, rest: [String], collectedMiddleware: [MiddlewareFn])
    case gateway(handler: any FetchHandler, options: FetchGatewayOptions, path: String, rest: [String])
    case help(path: String, description: String?, subcommands: [String: CommandEntry])
    case notFound(token: String)
}

func resolveCommand(commands: [String: CommandEntry], tokens: [String]) -> ResolvedCommand {
    if tokens.isEmpty {
        return .help(path: "", description: nil, subcommands: commands)
    }

    var currentCommands = commands
    var collectedMiddleware: [MiddlewareFn] = []
    var pathParts: [String] = []

    for (idx, token) in tokens.enumerated() {
        guard let entry = currentCommands[token] else {
            if idx == 0 {
                return .notFound(token: token)
            }
            // Unknown token — treat remaining as argv for the last command
            break
        }

        pathParts.append(token)

        switch entry {
        case .leaf(let def):
            let rest = Array(tokens.dropFirst(idx + 1))
            return .leaf(
                command: def,
                path: pathParts.joined(separator: " "),
                rest: rest,
                collectedMiddleware: collectedMiddleware
            )
        case .fetchGateway(let handler, let opts):
            let rest = Array(tokens.dropFirst(idx + 1))
            return .gateway(
                handler: handler,
                options: opts,
                path: pathParts.joined(separator: " "),
                rest: rest
            )
        case .group(let desc, let subcommands, let mw, _):
            collectedMiddleware.append(contentsOf: mw)
            if idx == tokens.count - 1 {
                return .help(
                    path: pathParts.joined(separator: " "),
                    description: desc,
                    subcommands: subcommands
                )
            }
            currentCommands = subcommands
        }
    }

    return .help(path: pathParts.joined(separator: " "), description: nil, subcommands: currentCommands)
}

// MARK: - Output

func outputResult(
    _ result: InternalResult,
    format: Format,
    human: Bool,
    verbose: Bool,
    filterExpr: String?,
    tokenCount: Bool = false,
    tokenLimit: Int? = nil,
    tokenOffset: Int? = nil,
    commandPath: String? = nil,
    duration: Double? = nil
) async {
    switch result {
    case .ok(let data, let cta):
        var output = data

        // Apply filter
        if let expr = filterExpr {
            let paths = parseFilterExpression(expr)
            output = applyFilter(data: output, paths: paths)
        }

        // Format the output
        var formatted = formatValue(output, format: format)

        // Apply token operations (approximate: 1 token ~ 4 characters)
        if tokenCount || tokenLimit != nil || tokenOffset != nil {
            formatted = applyTokenOperations(
                formatted,
                count: tokenCount,
                limit: tokenLimit,
                offset: tokenOffset
            )
        } else if verbose {
            // Wrap in verbose envelope
            var envelope = OrderedMap()
            envelope["ok"] = .bool(true)
            envelope["data"] = output
            if let commandPath {
                var meta = OrderedMap()
                meta["command"] = .string(commandPath)
                if let duration {
                    meta["duration"] = .double(duration)
                }
                envelope["meta"] = .object(meta)
            }
            formatted = formatValue(.object(envelope), format: format == .toon ? .json : format)
        }

        writelnStdout(formatted)

        // CTA for humans
        if human, let cta {
            let label = cta.description ?? "Suggested commands:"
            fputs("\n\(label)\n", stderr)
            for entry in cta.commands {
                switch entry {
                case .simple(let cmd):
                    fputs("  \(cmd)\n", stderr)
                case .detailed(let cmd, let desc):
                    if let desc {
                        fputs("  \(cmd)  # \(desc)\n", stderr)
                    } else {
                        fputs("  \(cmd)\n", stderr)
                    }
                }
            }
        }

    case .error(let code, let message, _, _, let cta, let exitCode):
        if human {
            writelnStdout(formatHumanError(code: code, message: message))
        } else {
            let errorJSON: JSONValue = [
                "ok": false,
                "error": [
                    "code": .string(code),
                    "message": .string(message),
                ]
            ]
            writelnStdout(formatValue(errorJSON, format: format))
        }

        if human, let cta {
            let label = cta.description ?? "Suggested commands:"
            fputs("\n\(label)\n", stderr)
            for entry in cta.commands {
                switch entry {
                case .simple(let cmd): fputs("  \(cmd)\n", stderr)
                case .detailed(let cmd, let desc):
                    if let desc { fputs("  \(cmd)  # \(desc)\n", stderr) }
                    else { fputs("  \(cmd)\n", stderr) }
                }
            }
        }

        Foundation.exit(exitCode ?? 1)

    case .stream(let stream):
        // Consume stream, outputting each item
        for await item in stream {
            let formatted = formatValue(item, format: format == .toon ? .jsonl : format)
            writelnStdout(formatted)
        }
    }
}

/// Applies token counting, limiting, and offsetting to formatted output.
///
/// Approximates tokens as `characterCount / 4`.
func applyTokenOperations(
    _ text: String,
    count: Bool,
    limit: Int?,
    offset: Int?
) -> String {
    let totalTokens = text.count / 4

    if count {
        return String(totalTokens)
    }

    // Apply offset and limit by character approximation
    var result = text

    if let offset, offset > 0 {
        let charOffset = offset * 4
        if charOffset >= result.count {
            return ""
        }
        let startIndex = result.index(result.startIndex, offsetBy: charOffset)
        result = String(result[startIndex...])
    }

    if let limit, limit > 0 {
        let charLimit = limit * 4
        if charLimit < result.count {
            let endIndex = result.index(result.startIndex, offsetBy: charLimit)
            result = String(result[..<endIndex])
        }
    }

    return result
}

// MARK: - Helpers

func writelnStdout(_ s: String) {
    print(s)
}

func formatHumanError(code: String, message: String) -> String {
    "Error [\(code)]: \(message)"
}

func collectHelpCommands(_ commands: [String: CommandEntry]) -> [CommandSummary] {
    commands.sorted { $0.key < $1.key }.map { name, entry in
        CommandSummary(name: name, description: entry.description)
    }
}

func buildCompletionCommands(_ commands: [String: CommandEntry]) -> [String: CompletionCommandEntry] {
    var result: [String: CompletionCommandEntry] = [:]
    for (name, entry) in commands {
        switch entry {
        case .leaf(let def):
            result[name] = CompletionCommandEntry(
                isGroup: false,
                description: def.description,
                optionsFields: def.optionsFields,
                aliases: def.aliases
            )
        case .fetchGateway(_, let opts):
            result[name] = CompletionCommandEntry(
                isGroup: false,
                description: opts.description
            )
        case .group(let desc, let subs, _, _):
            result[name] = CompletionCommandEntry(
                isGroup: true,
                description: desc,
                commands: buildCompletionCommands(subs)
            )
        }
    }
    return result
}

// MARK: - Skill Command Info Collection

/// Collects `SkillCommandInfo` from the command tree for use with the Skill module.
func collectSkillCommandInfo(_ commands: [String: CommandEntry], path: [String] = []) -> [SkillCommandInfo] {
    var result: [SkillCommandInfo] = []
    for (name, entry) in commands.sorted(by: { $0.key < $1.key }) {
        let currentPath = path + [name]
        switch entry {
        case .leaf(let def):
            result.append(SkillCommandInfo(
                name: currentPath.joined(separator: " "),
                description: def.description,
                argsFields: def.argsFields,
                optionsFields: def.optionsFields,
                envFields: def.envFields,
                hint: def.hint,
                examples: def.examples,
                outputSchema: def.outputSchema
            ))
        case .fetchGateway(_, let opts):
            result.append(SkillCommandInfo(
                name: currentPath.joined(separator: " "),
                description: opts.description ?? "Fetch gateway",
                hint: "Accepts curl-style arguments: -X METHOD, -H header, -d body, --key value (query params)"
            ))
        case .group(_, let subs, _, _):
            result.append(contentsOf: collectSkillCommandInfo(subs, path: currentPath))
        }
    }
    return result
}
