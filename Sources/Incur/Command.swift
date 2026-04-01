/// Unified command execution for the incur framework.
///
/// This module is the heart of the three-transport architecture. The
/// `execute` function is called by CLI, HTTP, and MCP transports with
/// different `ParseMode` values to handle input parsing, middleware
/// composition, and handler invocation uniformly.
///
/// Ported from `command.rs`.

import Foundation

/// How to parse input for a command.
public enum ParseMode: Sendable {
    /// CLI: parse both args and options from argv tokens.
    case argv
    /// HTTP: args from URL path segments, options from body/query.
    case split
    /// MCP: all params from JSON, split by schema field names.
    case flat
}

/// A usage example for a command.
public struct Example: Sendable {
    /// The command invocation (without the CLI name prefix).
    public let command: String
    /// A short description of what this example demonstrates.
    public let description: String?

    public init(command: String, description: String? = nil) {
        self.command = command
        self.description = description
    }
}

/// Trait for command handlers.
public protocol CommandHandler: Sendable {
    /// Execute the command with the given context.
    func run(_ ctx: CommandContext) async -> CommandResult
}

/// A registered command definition (leaf node in the command tree).
public final class CommandDef: @unchecked Sendable {
    /// The command name.
    public let name: String
    /// A short description of what the command does.
    public let description: String?
    /// Schema for positional arguments.
    public let argsFields: [FieldMeta]
    /// Schema for named options/flags.
    public let optionsFields: [FieldMeta]
    /// Schema for environment variables.
    public let envFields: [FieldMeta]
    /// Map of option names to single-char aliases.
    public let aliases: [String: Character]
    /// Usage examples displayed in help output.
    public let examples: [Example]
    /// Plain-text hint displayed after examples in help output.
    public let hint: String?
    /// Default output format for this command.
    public let format: Format?
    /// Output policy controlling who sees this command's output.
    public let outputPolicy: OutputPolicy?
    /// The command handler.
    public let handler: any CommandHandler
    /// Per-command middleware.
    public let middleware: [MiddlewareFn]
    /// JSON Schema for the command's output type.
    public let outputSchema: JSONValue?

    public init(
        name: String,
        description: String? = nil,
        argsFields: [FieldMeta] = [],
        optionsFields: [FieldMeta] = [],
        envFields: [FieldMeta] = [],
        aliases: [String: Character] = [:],
        examples: [Example] = [],
        hint: String? = nil,
        format: Format? = nil,
        outputPolicy: OutputPolicy? = nil,
        handler: any CommandHandler,
        middleware: [MiddlewareFn] = [],
        outputSchema: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.argsFields = argsFields
        self.optionsFields = optionsFields
        self.envFields = envFields
        self.aliases = aliases
        self.examples = examples
        self.hint = hint
        self.format = format
        self.outputPolicy = outputPolicy
        self.handler = handler
        self.middleware = middleware
        self.outputSchema = outputSchema
    }

    /// Creates a new command builder with the given name and handler.
    public static func build(_ name: String, handler: any CommandHandler) -> CommandBuilder {
        CommandBuilder(def: CommandDef(name: name, handler: handler))
    }
}

/// Builder for constructing a `CommandDef` ergonomically.
public final class CommandBuilder {
    private var _name: String
    private var _description: String?
    private var _argsFields: [FieldMeta] = []
    private var _optionsFields: [FieldMeta] = []
    private var _envFields: [FieldMeta] = []
    private var _aliases: [String: Character] = [:]
    private var _examples: [Example] = []
    private var _hint: String?
    private var _format: Format?
    private var _outputPolicy: OutputPolicy?
    private var _handler: any CommandHandler
    private var _middleware: [MiddlewareFn] = []
    private var _outputSchema: JSONValue?

    init(def: CommandDef) {
        _name = def.name
        _description = def.description
        _argsFields = def.argsFields
        _optionsFields = def.optionsFields
        _envFields = def.envFields
        _aliases = def.aliases
        _examples = def.examples
        _hint = def.hint
        _format = def.format
        _outputPolicy = def.outputPolicy
        _handler = def.handler
        _middleware = def.middleware
        _outputSchema = def.outputSchema
    }

    public func description(_ desc: String) -> CommandBuilder {
        _description = desc
        return self
    }

    public func argsFields(_ fields: [FieldMeta]) -> CommandBuilder {
        _argsFields = fields
        return self
    }

    public func optionsFields(_ fields: [FieldMeta]) -> CommandBuilder {
        for field in fields {
            if let alias = field.alias {
                _aliases[field.name] = alias
            }
        }
        _optionsFields = fields
        return self
    }

    public func envFields(_ fields: [FieldMeta]) -> CommandBuilder {
        _envFields = fields
        return self
    }

    public func examples(_ examples: [Example]) -> CommandBuilder {
        _examples = examples
        return self
    }

    public func hint(_ hint: String) -> CommandBuilder {
        _hint = hint
        return self
    }

    public func format(_ format: Format) -> CommandBuilder {
        _format = format
        return self
    }

    public func done() -> CommandDef {
        CommandDef(
            name: _name,
            description: _description,
            argsFields: _argsFields,
            optionsFields: _optionsFields,
            envFields: _envFields,
            aliases: _aliases,
            examples: _examples,
            hint: _hint,
            format: _format,
            outputPolicy: _outputPolicy,
            handler: _handler,
            middleware: _middleware,
            outputSchema: _outputSchema
        )
    }
}

/// The context passed to a command's `run` function.
public struct CommandContext: Sendable {
    /// Whether the consumer is an agent (stdout is not a TTY).
    public let agent: Bool
    /// Parsed positional arguments as a JSON value.
    public let args: JSONValue
    /// Parsed environment variables as a JSON value.
    public let env: JSONValue
    /// Parsed named options as a JSON value.
    public let options: JSONValue
    /// The resolved output format.
    public let format: Format
    /// Whether the format was explicitly requested by the user.
    public let formatExplicit: Bool
    /// The CLI name.
    public let name: String
    /// Middleware variables set by upstream middleware.
    public let vars: JSONValue
    /// The CLI version string.
    public let version: String?

    public init(
        agent: Bool = false,
        args: JSONValue = .null,
        env: JSONValue = .null,
        options: JSONValue = .null,
        format: Format = .toon,
        formatExplicit: Bool = false,
        name: String = "",
        vars: JSONValue = .null,
        version: String? = nil
    ) {
        self.agent = agent
        self.args = args
        self.env = env
        self.options = options
        self.format = format
        self.formatExplicit = formatExplicit
        self.name = name
        self.vars = vars
        self.version = version
    }
}

/// Options for the unified `execute` function.
public struct ExecuteOptions: Sendable {
    public let agent: Bool
    public let argv: [String]
    public let defaults: OrderedMap?
    public let envFields: [FieldMeta]
    public let envSource: [String: String]
    public let format: Format
    public let formatExplicit: Bool
    public let inputOptions: OrderedMap
    public let middlewares: [MiddlewareFn]
    public let name: String
    public let parseMode: ParseMode
    public let path: String
    public let version: String?

    public init(
        agent: Bool = false,
        argv: [String] = [],
        defaults: OrderedMap? = nil,
        envFields: [FieldMeta] = [],
        envSource: [String: String] = [:],
        format: Format = .toon,
        formatExplicit: Bool = false,
        inputOptions: OrderedMap = OrderedMap(),
        middlewares: [MiddlewareFn] = [],
        name: String = "",
        parseMode: ParseMode = .argv,
        path: String = "",
        version: String? = nil
    ) {
        self.agent = agent
        self.argv = argv
        self.defaults = defaults
        self.envFields = envFields
        self.envSource = envSource
        self.format = format
        self.formatExplicit = formatExplicit
        self.inputOptions = inputOptions
        self.middlewares = middlewares
        self.name = name
        self.parseMode = parseMode
        self.path = path
        self.version = version
    }
}

/// Internal execute result (before output envelope wrapping).
public enum InternalResult: Sendable {
    case ok(data: JSONValue, cta: CtaBlock?)
    case error(code: String, message: String, retryable: Bool?, fieldErrors: [FieldError]?, cta: CtaBlock?, exitCode: Int32?)
    case stream(AsyncStream<JSONValue>)
}

/// Unified command execution used by CLI, HTTP, and MCP transports.
public func execute(command: CommandDef, options: ExecuteOptions) async -> InternalResult {
    let varsMap = MutableVars()

    // Parse args and options based on parseMode
    let args: JSONValue
    let parsedOptions: JSONValue

    switch options.parseMode {
    case .argv:
        do {
            let parseResult = try parse(argv: options.argv, options: ParseOptions(
                argsFields: command.argsFields,
                optionsFields: command.optionsFields,
                aliases: command.aliases,
                defaults: options.defaults
            ))
            args = .object(parseResult.args)
            parsedOptions = .object(parseResult.options)
        } catch let error as ParseError {
            return .error(code: "PARSE_ERROR", message: error.message, retryable: nil, fieldErrors: nil, cta: nil, exitCode: 1)
        } catch {
            return .error(code: "PARSE_ERROR", message: error.localizedDescription, retryable: nil, fieldErrors: nil, cta: nil, exitCode: 1)
        }

    case .split:
        args = parseArgsFromArgv(options.argv, argsFields: command.argsFields)
        parsedOptions = .object(options.inputOptions)

    case .flat:
        let result = splitFlatParams(
            params: options.inputOptions,
            argsFields: command.argsFields,
            optionsFields: command.optionsFields
        )
        args = result.0
        parsedOptions = result.1
    }

    // Parse command env from envSource
    let commandEnv = parseEnvFields(command.envFields, source: options.envSource)

    // Parse CLI-level env
    let cliEnv = parseEnvFields(options.envFields, source: options.envSource)

    // Shared result slot (actor for Sendable safety)
    let resultSlot = ResultSlot()

    let runCommand: @Sendable () async -> Void = {
        // Build CommandContext with current vars snapshot
        let ctx = CommandContext(
            agent: options.agent,
            args: args,
            env: commandEnv,
            options: parsedOptions,
            format: options.format,
            formatExplicit: options.formatExplicit,
            name: options.name,
            vars: varsMap.snapshot(),
            version: options.version
        )

        let handlerResult = await command.handler.run(ctx)

        switch handlerResult {
        case .ok(let data, let cta):
            await resultSlot.set(.ok(data: data, cta: cta))
        case .error(let code, let message, let retryable, let exitCode, let cta):
            await resultSlot.set(.error(
                code: code,
                message: message,
                retryable: retryable ? true : nil,
                fieldErrors: nil,
                cta: cta,
                exitCode: exitCode
            ))
        case .stream(let stream):
            await resultSlot.set(.stream(stream))
        }
    }

    // Run middleware chain (or handler directly if no middleware)
    if !options.middlewares.isEmpty {
        let mwCtx = MiddlewareContext(
            agent: options.agent,
            command: options.path,
            env: cliEnv,
            format: options.format,
            formatExplicit: options.formatExplicit,
            name: options.name,
            vars: varsMap,
            version: options.version
        )

        // When streaming with middleware, we need to extract the result as soon
        // as the handler sets it, rather than waiting for the full middleware
        // chain to complete. This is because middleware "after" hooks would
        // otherwise block stream consumption.
        //
        // Pattern: run middleware in a detached task, race between the result
        // slot being populated and the middleware chain finishing.
        let middlewareTask = Task { @Sendable in
            await composeMiddleware(options.middlewares, ctx: mwCtx, finalHandler: runCommand)
        }

        // Poll for the result to be available. Once the handler sets it
        // (including streams), we can return immediately and let middleware
        // after-hooks continue in the background.
        while true {
            if let result = await resultSlot.get() {
                if case .stream = result {
                    // Stream result: return immediately, let middleware finish in background
                    return result
                }
                // Non-stream: wait for middleware to fully complete
                await middlewareTask.value
                return result
            }
            // Yield to allow the middleware task to make progress
            await Task.yield()
        }
    } else {
        await runCommand()
    }

    return await resultSlot.get() ?? .ok(data: .null, cta: nil)
}

/// Actor for safely passing the result out of a `@Sendable` closure.
private actor ResultSlot {
    private var value: InternalResult?

    func set(_ result: InternalResult) {
        value = result
    }

    func get() -> InternalResult? {
        value
    }
}

// MARK: - Internal parsing helpers

private func parseArgsFromArgv(_ argv: [String], argsFields: [FieldMeta]) -> JSONValue {
    var argsMap = OrderedMap()
    for (i, token) in argv.enumerated() {
        if i < argsFields.count {
            argsMap[argsFields[i].name] = parseOptionValue(token)
        }
    }
    return .object(argsMap)
}

private func splitFlatParams(
    params: OrderedMap,
    argsFields: [FieldMeta],
    optionsFields: [FieldMeta]
) -> (JSONValue, JSONValue) {
    let argNames = Set(argsFields.map(\.name))
    var argsMap = OrderedMap()
    var optsMap = OrderedMap()

    for (key, value) in params {
        let snakeKey = toSnake(key)
        if argNames.contains(snakeKey) {
            argsMap[snakeKey] = value
        } else {
            optsMap[snakeKey] = value
        }
    }

    return (.object(argsMap), .object(optsMap))
}

private func parseEnvFields(_ envFields: [FieldMeta], source: [String: String]) -> JSONValue {
    var envMap = OrderedMap()
    for field in envFields {
        let envName = field.envName ?? field.name
        if let value = source[envName] {
            envMap[field.name] = parseEnvValue(value, fieldType: field.fieldType)
        } else if let defaultValue = field.defaultValue {
            envMap[field.name] = defaultValue
        }
    }
    return .object(envMap)
}

private func parseEnvValue(_ value: String, fieldType: FieldType) -> JSONValue {
    switch fieldType {
    case .boolean:
        return .bool(value == "1" || value == "true" || value == "yes")
    case .number:
        if let d = Double(value) {
            if d == d.rounded(.towardZero) && !d.isInfinite, let i = Int(exactly: d) {
                return .int(i)
            }
            return .double(d)
        }
        return .string(value)
    default:
        return .string(value)
    }
}

private func parseOptionValue(_ value: String) -> JSONValue {
    // Try integer
    if let i = Int(value) { return .int(i) }
    // Try float
    if let d = Double(value) { return .double(d) }
    // Boolean
    if value == "true" { return .bool(true) }
    if value == "false" { return .bool(false) }
    // Default to string
    return .string(value)
}
