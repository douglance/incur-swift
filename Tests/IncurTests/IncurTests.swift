import Foundation
import Testing
@testable import Incur

// MARK: - JSONValue Tests

@Suite("JSONValue")
struct JSONValueTests {
    @Test func scalarTypes() {
        #expect(JSONValue.null.isNull)
        #expect(JSONValue.bool(true).boolValue == true)
        #expect(JSONValue.int(42).intValue == 42)
        #expect(JSONValue.double(3.14).doubleValue == 3.14)
        #expect(JSONValue.string("hello").stringValue == "hello")
    }

    @Test func subscriptAccess() {
        let obj: JSONValue = ["name": "alice", "age": 30]
        #expect(obj["name"]?.stringValue == "alice")
        #expect(obj["age"]?.intValue == 30)

        let arr: JSONValue = [1, 2, 3]
        #expect(arr[0]?.intValue == 1)
        #expect(arr[2]?.intValue == 3)
    }

    @Test func jsonRoundTrip() {
        let value: JSONValue = [
            "name": "alice",
            "scores": [1, 2, 3],
            "active": true,
        ]
        let json = value.toJSON(pretty: false)
        let parsed = JSONValue.parse(json)
        #expect(parsed != nil)
    }

    @Test func scalarToString() {
        #expect(JSONValue.null.scalarToString == "null")
        #expect(JSONValue.bool(true).scalarToString == "true")
        #expect(JSONValue.bool(false).scalarToString == "false")
        #expect(JSONValue.int(42).scalarToString == "42")
        #expect(JSONValue.string("hello").scalarToString == "hello")
    }

    @Test func expressibleByLiterals() {
        let null: JSONValue = nil
        #expect(null.isNull)

        let b: JSONValue = true
        #expect(b.boolValue == true)

        let i: JSONValue = 42
        #expect(i.intValue == 42)

        let s: JSONValue = "hello"
        #expect(s.stringValue == "hello")
    }
}

// MARK: - OrderedMap Tests

@Suite("OrderedMap")
struct OrderedMapTests {
    @Test func preservesInsertionOrder() {
        var map = OrderedMap()
        map["c"] = .int(3)
        map["a"] = .int(1)
        map["b"] = .int(2)
        #expect(map.keys == ["c", "a", "b"])
    }

    @Test func updateExistingKey() {
        var map = OrderedMap()
        map["x"] = .int(1)
        map["y"] = .int(2)
        map["x"] = .int(10)
        #expect(map.keys == ["x", "y"])
        #expect(map["x"] == .int(10))
    }

    @Test func removeKey() {
        var map = OrderedMap()
        map["a"] = .int(1)
        map["b"] = .int(2)
        map["a"] = nil
        #expect(map.keys == ["b"])
        #expect(map["a"] == nil)
    }
}

// MARK: - Schema Tests

@Suite("Schema")
struct SchemaTests {
    @Test func toKebabConversion() {
        #expect(Incur.toKebab("filter_output") == "filter-output")
        #expect(Incur.toKebab("tokenLimit") == "token-limit")
        #expect(Incur.toKebab("simple") == "simple")
    }

    @Test func toSnakeConversion() {
        #expect(Incur.toSnake("filter-output") == "filter_output")
        #expect(Incur.toSnake("simple") == "simple")
    }

    @Test func fieldTypeDisplayName() {
        #expect(FieldType.string.displayName == "string")
        #expect(FieldType.number.displayName == "number")
        #expect(FieldType.boolean.displayName == "boolean")
        #expect(FieldType.array(.string).displayName == "array")
        #expect(FieldType.enum(["a", "b", "c"]).displayName == "a|b|c")
        #expect(FieldType.count.displayName == "count")
    }
}

// MARK: - Parser Tests

@Suite("Parser")
struct ParserTests {
    func field(_ name: String, _ ft: FieldType) -> FieldMeta {
        FieldMeta(name: name, fieldType: ft)
    }

    @Test func longOptionWithValue() throws {
        let opts = ParseOptions(optionsFields: [field("output", .string)])
        let result = try parse(argv: ["--output", "json"], options: opts)
        #expect(result.options["output"] == .string("json"))
    }

    @Test func longOptionEquals() throws {
        let opts = ParseOptions(optionsFields: [field("output", .string)])
        let result = try parse(argv: ["--output=json"], options: opts)
        #expect(result.options["output"] == .string("json"))
    }

    @Test func noFlagNegation() throws {
        let opts = ParseOptions(optionsFields: [field("verbose", .boolean)])
        let result = try parse(argv: ["--no-verbose"], options: opts)
        #expect(result.options["verbose"] == .bool(false))
    }

    @Test func booleanFlagWithoutValue() throws {
        let opts = ParseOptions(optionsFields: [field("verbose", .boolean)])
        let result = try parse(argv: ["--verbose"], options: opts)
        #expect(result.options["verbose"] == .bool(true))
    }

    @Test func countFlag() throws {
        let opts = ParseOptions(
            optionsFields: [FieldMeta(name: "verbose", fieldType: .count, alias: "v")]
        )
        let result = try parse(argv: ["-vvv"], options: opts)
        #expect(result.options["verbose"] == .int(3))
    }

    @Test func shortAlias() throws {
        let opts = ParseOptions(
            optionsFields: [FieldMeta(name: "output", fieldType: .string, alias: "o")]
        )
        let result = try parse(argv: ["-o", "json"], options: opts)
        #expect(result.options["output"] == .string("json"))
    }

    @Test func stackedBooleanAliases() throws {
        let opts = ParseOptions(
            optionsFields: [
                FieldMeta(name: "all", fieldType: .boolean, alias: "a"),
                FieldMeta(name: "long_list", fieldType: .boolean, alias: "l"),
            ]
        )
        let result = try parse(argv: ["-al"], options: opts)
        #expect(result.options["all"] == .bool(true))
        #expect(result.options["long_list"] == .bool(true))
    }

    @Test func stackedNonBooleanLast() throws {
        let opts = ParseOptions(
            optionsFields: [
                FieldMeta(name: "verbose", fieldType: .boolean, alias: "v"),
                FieldMeta(name: "output", fieldType: .string, alias: "o"),
            ]
        )
        let result = try parse(argv: ["-vo", "json"], options: opts)
        #expect(result.options["verbose"] == .bool(true))
        #expect(result.options["output"] == .string("json"))
    }

    @Test func stackedNonBooleanNotLastErrors() throws {
        let opts = ParseOptions(
            optionsFields: [
                FieldMeta(name: "output", fieldType: .string, alias: "o"),
                FieldMeta(name: "verbose", fieldType: .boolean, alias: "v"),
            ]
        )
        #expect(throws: ParseError.self) {
            try parse(argv: ["-ov", "json"], options: opts)
        }
    }

    @Test func arrayOptionCollects() throws {
        let opts = ParseOptions(optionsFields: [field("tag", .array(.string))])
        let result = try parse(argv: ["--tag", "a", "--tag", "b"], options: opts)
        #expect(result.options["tag"] == .array([.string("a"), .string("b")]))
    }

    @Test func positionalArgs() throws {
        let opts = ParseOptions(argsFields: [field("source", .string), field("dest", .string)])
        let result = try parse(argv: ["foo", "bar"], options: opts)
        #expect(result.args["source"] == .string("foo"))
        #expect(result.args["dest"] == .string("bar"))
    }

    @Test func numberCoercion() throws {
        let opts = ParseOptions(optionsFields: [field("port", .number)])
        let result = try parse(argv: ["--port", "8080"], options: opts)
        #expect(result.options["port"] == .int(8080))
    }

    @Test func booleanCoercion() throws {
        let opts = ParseOptions(optionsFields: [field("dry_run", .boolean)])
        let result = try parse(argv: ["--dry-run=true"], options: opts)
        #expect(result.options["dry_run"] == .bool(true))
    }

    @Test func defaultsMerged() throws {
        var defaults = OrderedMap()
        defaults["output"] = .string("toon")
        defaults["verbose"] = .bool(false)
        let opts = ParseOptions(
            optionsFields: [field("output", .string), field("verbose", .boolean)],
            defaults: defaults
        )
        let result = try parse(argv: ["--output", "json"], options: opts)
        #expect(result.options["output"] == .string("json"))
        #expect(result.options["verbose"] == .bool(false))
    }

    @Test func unknownFlagErrors() {
        let opts = ParseOptions()
        #expect(throws: ParseError.self) {
            try parse(argv: ["--unknown"], options: opts)
        }
    }

    @Test func missingValueErrors() {
        let opts = ParseOptions(optionsFields: [field("output", .string)])
        #expect(throws: ParseError.self) {
            try parse(argv: ["--output"], options: opts)
        }
    }

    @Test func kebabToSnakeNormalization() throws {
        let opts = ParseOptions(optionsFields: [field("dry_run", .boolean)])
        let result = try parse(argv: ["--dry-run"], options: opts)
        #expect(result.options["dry_run"] == .bool(true))
    }

    @Test func fieldLevelDefault() throws {
        let opts = ParseOptions(
            optionsFields: [FieldMeta(name: "format", fieldType: .string, defaultValue: "toon")]
        )
        let result = try parse(argv: [], options: opts)
        #expect(result.options["format"] == .string("toon"))
    }

    @Test func parseEnvBasic() {
        let fields = [
            FieldMeta(name: "api_key", fieldType: .string, envName: "API_KEY"),
            FieldMeta(name: "port", fieldType: .number, envName: "PORT"),
            FieldMeta(name: "debug", fieldType: .boolean, envName: "DEBUG"),
        ]
        let source = ["API_KEY": "secret", "PORT": "3000", "DEBUG": "true"]
        let result = parseEnv(fields: fields, source: source)
        #expect(result["api_key"] == .string("secret"))
        #expect(result["port"] == .int(3000))
        #expect(result["debug"] == .bool(true))
    }

    @Test func mixedPositionalAndOptions() throws {
        let opts = ParseOptions(
            argsFields: [field("command", .string)],
            optionsFields: [field("verbose", .boolean), field("output", .string)]
        )
        let result = try parse(argv: ["deploy", "--verbose", "--output", "json"], options: opts)
        #expect(result.args["command"] == .string("deploy"))
        #expect(result.options["verbose"] == .bool(true))
        #expect(result.options["output"] == .string("json"))
    }

    @Test func enumValidationRejects() throws {
        let opts = ParseOptions(
            optionsFields: [field("priority", .enum(["low", "medium", "high"]))]
        )
        #expect(throws: ParseError.self) {
            try parse(argv: ["--priority", "invalid"], options: opts)
        }
    }

    @Test func enumValidationAccepts() throws {
        let opts = ParseOptions(
            optionsFields: [field("priority", .enum(["low", "medium", "high"]))]
        )
        let result = try parse(argv: ["--priority", "high"], options: opts)
        #expect(result.options["priority"] == .string("high"))
    }
}

// MARK: - Filter Tests

@Suite("Filter")
struct FilterTests {
    @Test func parseSingleKey() {
        let paths = parseFilterExpression("foo")
        #expect(paths.count == 1)
        #expect(paths[0].count == 1)
        if case .key(let k) = paths[0][0] { #expect(k == "foo") }
    }

    @Test func parseMultipleKeys() {
        let paths = parseFilterExpression("foo,bar,baz")
        #expect(paths.count == 3)
    }

    @Test func parseDottedPath() {
        let paths = parseFilterExpression("foo.bar.baz")
        #expect(paths.count == 1)
        #expect(paths[0].count == 3)
    }

    @Test func parseWithSlice() {
        let paths = parseFilterExpression("items[0,3]")
        #expect(paths.count == 1)
        #expect(paths[0].count == 2)
        if case .slice(let s, let e) = paths[0][1] {
            #expect(s == 0)
            #expect(e == 3)
        }
    }

    @Test func applyEmptyPaths() {
        let data: JSONValue = ["a": 1, "b": 2]
        let result = applyFilter(data: data, paths: [])
        #expect(result == data)
    }

    @Test func applySingleScalarKey() {
        let data: JSONValue = ["name": "alice", "age": 30]
        let paths = parseFilterExpression("name")
        let result = applyFilter(data: data, paths: paths)
        #expect(result == .string("alice"))
    }

    @Test func applyMultipleKeys() {
        let data: JSONValue = ["a": 1, "b": 2, "c": 3]
        let paths = parseFilterExpression("a,c")
        let result = applyFilter(data: data, paths: paths)
        #expect(result["a"] == .int(1))
        #expect(result["c"] == .int(3))
    }

    @Test func applyToArrayData() {
        let data: JSONValue = .array([
            ["name": "alice", "age": 30],
            ["name": "bob", "age": 25],
        ])
        let paths = parseFilterExpression("name")
        let result = applyFilter(data: data, paths: paths)
        #expect(result == .array([.string("alice"), .string("bob")]))
    }

    @Test func applyArraySlice() {
        let data: JSONValue = ["items": .array([1, 2, 3, 4, 5])]
        let paths = parseFilterExpression("items[0,3]")
        let result = applyFilter(data: data, paths: paths)
        #expect(result["items"] == .array([.int(1), .int(2), .int(3)]))
    }
}

// MARK: - Formatter Tests

@Suite("Formatter")
struct FormatterTests {
    @Test func formatJSON() {
        let val: JSONValue = ["name": "alice"]
        let result = formatValue(val, format: .json)
        #expect(result.contains("\"name\""))
        #expect(result.contains("\"alice\""))
    }

    @Test func formatJSONLArray() {
        let val: JSONValue = .array([["a": 1], ["a": 2]])
        let result = formatValue(val, format: .jsonl)
        let lines = result.split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test func formatMarkdownScalar() {
        let val: JSONValue = "hello"
        #expect(formatValue(val, format: .markdown) == "hello")
    }

    @Test func formatTableArrayOfObjects() {
        let val: JSONValue = .array([
            ["id": 1, "name": "alice"],
            ["id": 2, "name": "bob"],
        ])
        let result = formatValue(val, format: .table)
        #expect(result.contains("alice"))
        #expect(result.contains("bob"))
        #expect(result.contains("+--"))
    }

    @Test func formatCSVArrayOfObjects() {
        let val: JSONValue = .array([
            ["id": 1, "name": "alice"],
            ["id": 2, "name": "bob"],
        ])
        let result = formatValue(val, format: .csv)
        let lines = result.split(separator: "\n")
        #expect(lines.count == 3) // header + 2 rows
    }

    @Test func formatToonScalar() {
        #expect(formatValue(.int(42), format: .toon) == "42")
        #expect(formatValue(.string("hello"), format: .toon) == "hello")
    }

    @Test func formatTableEmpty() {
        #expect(formatValue(.array([]), format: .table) == "(empty)")
    }
}

// MARK: - Help Tests

@Suite("Help")
struct HelpTests {
    @Test func formatRootBasic() {
        let help = formatRootHelp(
            name: "my-cli",
            options: FormatRootOptions(
                commands: [
                    CommandSummary(name: "list", description: "List items"),
                    CommandSummary(name: "get", description: "Get an item"),
                ],
                description: "A test CLI",
                version: "1.0.0"
            )
        )
        #expect(help.contains("my-cli@1.0.0 \u{2014} A test CLI"))
        #expect(help.contains("Usage: my-cli <command>"))
        #expect(help.contains("list"))
        #expect(help.contains("get"))
    }

    @Test func formatCommandBasic() {
        let help = formatCommandHelp(
            name: "my-cli deploy",
            options: FormatCommandOptions(
                argsFields: [FieldMeta(name: "environment", description: "Target environment", fieldType: .string, required: true)],
                description: "Deploy the app",
                examples: [Example(command: "production", description: "Deploy to prod")],
                optionsFields: [FieldMeta(name: "verbose", description: "Verbose output", fieldType: .boolean, alias: "v")],
                optionAliases: ["verbose": "v"]
            )
        )
        #expect(help.contains("my-cli deploy \u{2014} Deploy the app"))
        #expect(help.contains("Usage: my-cli deploy <environment> [options]"))
        #expect(help.contains("Arguments:"))
        #expect(help.contains("environment"))
        #expect(help.contains("Options:"))
        #expect(help.contains("--verbose, -v <boolean>"))
        #expect(help.contains("Examples:"))
    }
}

// MARK: - Completions Tests

@Suite("Completions")
struct CompletionsTests {
    @Test func shellParse() {
        #expect(Shell.from("bash") == .bash)
        #expect(Shell.from("zsh") == .zsh)
        #expect(Shell.from("fish") == .fish)
        #expect(Shell.from("nushell") == .nushell)
        #expect(Shell.from("powershell") == nil)
    }

    @Test func registerBash() {
        let script = registerCompletion(shell: .bash, name: "mycli")
        #expect(script.contains("_incur_complete_mycli"))
        #expect(script.contains("complete -o default"))
    }

    @Test func completeSubcommands() {
        let commands: [String: CompletionCommandEntry] = [
            "deploy": CompletionCommandEntry(description: "Deploy things"),
            "status": CompletionCommandEntry(description: "Show status"),
            "debug": CompletionCommandEntry(description: "Debug mode"),
        ]
        let candidates = computeCompletions(commands: commands, rootCommand: nil, argv: ["mycli", "de"], index: 1)
        let values = candidates.map(\.value)
        #expect(values.contains("deploy"))
        #expect(values.contains("debug"))
    }

    @Test func completeOptions() {
        let commands: [String: CompletionCommandEntry] = [
            "deploy": CompletionCommandEntry(
                optionsFields: [
                    FieldMeta(name: "output", fieldType: .string),
                    FieldMeta(name: "verbose", fieldType: .boolean),
                ]
            ),
        ]
        let candidates = computeCompletions(commands: commands, rootCommand: nil, argv: ["mycli", "deploy", "--"], index: 2)
        let values = candidates.map(\.value)
        #expect(values.contains("--output"))
        #expect(values.contains("--verbose"))
    }
}

// MARK: - Middleware Tests

@Suite("Middleware")
struct MiddlewareTests {
    @Test func composeEmptyMiddleware() async {
        let tracker = OrderTracker()
        await composeMiddleware([], ctx: makeCtx()) {
            await tracker.append("called")
        }
        let result = await tracker.items
        #expect(result == ["called"])
    }

    @Test func composeOnionOrder() async {
        let order = OrderTracker()

        let mwA: MiddlewareFn = { @Sendable _, next in
            await order.append("A-before")
            await next()
            await order.append("A-after")
        }

        let mwB: MiddlewareFn = { @Sendable _, next in
            await order.append("B-before")
            await next()
            await order.append("B-after")
        }

        await composeMiddleware([mwA, mwB], ctx: makeCtx()) {
            await order.append("handler")
        }

        let result = await order.items
        #expect(result == ["A-before", "B-before", "handler", "B-after", "A-after"])
    }

    func makeCtx() -> MiddlewareContext {
        MiddlewareContext(
            agent: false,
            command: "test",
            env: .null,
            format: .toon,
            formatExplicit: false,
            name: "test-cli",
            vars: MutableVars(),
            version: nil
        )
    }
}

// Helper for tracking order in async middleware tests
actor OrderTracker {
    var items: [String] = []

    func append(_ item: String) {
        items.append(item)
    }
}

// MARK: - Config Tests

@Suite("Config")
struct ConfigTests {
    @Test func loadConfigFromFile() throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let configPath = tmpDir.appendingPathComponent("test-config-\(UUID().uuidString).json").path
        let json = """
        {
            "options": {
                "verbose": true
            },
            "commands": {
                "deploy": {
                    "options": {
                        "environment": "staging"
                    }
                }
            }
        }
        """
        FileManager.default.createFile(atPath: configPath, contents: json.data(using: .utf8))
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        let config = try loadConfig(path: configPath)
        #expect(config["options"] != nil)
        #expect(config["commands"] != nil)
    }

    @Test func loadConfigInvalidJSON() {
        let tmpDir = FileManager.default.temporaryDirectory
        let configPath = tmpDir.appendingPathComponent("test-bad-config-\(UUID().uuidString).json").path
        FileManager.default.createFile(atPath: configPath, contents: "not json".data(using: .utf8))
        defer { try? FileManager.default.removeItem(atPath: configPath) }

        #expect(throws: ConfigError.self) {
            try loadConfig(path: configPath)
        }
    }

    @Test func loadConfigMissingFile() {
        #expect(throws: ConfigError.self) {
            try loadConfig(path: "/nonexistent/path/config.json")
        }
    }

    @Test func extractCommandSectionRoot() throws {
        let config: JSONValue = [
            "options": [
                "verbose": true,
            ]
        ]

        let result = try extractCommandSection(config: config, cliName: "my-cli", commandPath: "my-cli")
        #expect(result != nil)
        #expect(result?["verbose"] == .bool(true))
    }

    @Test func extractCommandSectionNested() throws {
        let config: JSONValue = [
            "commands": [
                "deploy": [
                    "options": [
                        "environment": "staging",
                    ]
                ]
            ]
        ]

        let result = try extractCommandSection(config: config, cliName: "my-cli", commandPath: "deploy")
        #expect(result != nil)
        #expect(result?["environment"] == .string("staging"))
    }

    @Test func extractCommandSectionDeeplyNested() throws {
        let config: JSONValue = [
            "commands": [
                "users": [
                    "commands": [
                        "list": [
                            "options": [
                                "limit": 10,
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let result = try extractCommandSection(config: config, cliName: "my-cli", commandPath: "users list")
        #expect(result != nil)
        #expect(result?["limit"] == .int(10))
    }

    @Test func extractCommandSectionMissing() throws {
        let config: JSONValue = [
            "commands": [:]
        ]

        let result = try extractCommandSection(config: config, cliName: "my-cli", commandPath: "nonexistent")
        #expect(result == nil)
    }

    @Test func extractCommandSectionEmptyOptions() throws {
        let config: JSONValue = [
            "commands": [
                "test": [
                    "options": [:] as JSONValue,
                ]
            ]
        ]

        let result = try extractCommandSection(config: config, cliName: "my-cli", commandPath: "test")
        #expect(result == nil)
    }

    @Test func resolveConfigPathExplicit() {
        let result = resolveConfigPath(explicit: "/etc/config.json", files: [])
        #expect(result == "/etc/config.json")
    }

    @Test func resolveConfigPathTilde() {
        let result = resolveConfigPath(explicit: "~/config.json", files: [])
        #expect(result != nil)
        #expect(!result!.hasPrefix("~"))
        #expect(result!.hasSuffix("config.json"))
    }

    @Test func resolveConfigPathNoMatch() {
        let result = resolveConfigPath(explicit: nil, files: ["/nonexistent/a.json", "/nonexistent/b.json"])
        #expect(result == nil)
    }
}

// MARK: - Config Schema Tests

@Suite("ConfigSchema")
struct ConfigSchemaTests {
    struct NoopHandler: CommandHandler {
        func run(_ ctx: CommandContext) async -> CommandResult {
            .ok(data: .null)
        }
    }

    func makeField(_ name: String, _ ft: FieldType) -> FieldMeta {
        FieldMeta(name: name, fieldType: ft)
    }

    func makeFieldWithDesc(_ name: String, _ ft: FieldType, _ desc: String) -> FieldMeta {
        FieldMeta(name: name, description: desc, fieldType: ft)
    }

    @Test func emptyTreeHasSchemaProperty() {
        let schema = generateConfigSchema(commands: [:], rootOptions: [])

        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["additionalProperties"]?.boolValue == false)
        // Should have $schema property
        let props = schema["properties"]
        #expect(props != nil)
        #expect(props?["$schema"]?["type"]?.stringValue == "string")
    }

    @Test func rootOptionsGenerateOptionsProperty() {
        let rootOptions = [
            makeFieldWithDesc("verbose", .boolean, "Enable verbose output"),
            makeField("timeout", .number),
        ]

        let schema = generateConfigSchema(commands: [:], rootOptions: rootOptions)

        let options = schema["properties"]?["options"]
        #expect(options?["type"]?.stringValue == "object")
        #expect(options?["additionalProperties"]?.boolValue == false)
        #expect(options?["properties"]?["verbose"]?["type"]?.stringValue == "boolean")
        #expect(options?["properties"]?["verbose"]?["description"]?.stringValue == "Enable verbose output")
        #expect(options?["properties"]?["timeout"]?["type"]?.stringValue == "number")
    }

    @Test func leafCommandGeneratesCommandOptions() {
        let commands: [String: CommandEntry] = [
            "deploy": .leaf(CommandDef(
                name: "deploy",
                optionsFields: [makeField("environment", .string)],
                handler: NoopHandler()
            ))
        ]

        let schema = generateConfigSchema(commands: commands, rootOptions: [])

        let deploy = schema["properties"]?["commands"]?["properties"]?["deploy"]
        #expect(deploy?["type"]?.stringValue == "object")
        #expect(deploy?["properties"]?["options"]?["properties"]?["environment"]?["type"]?.stringValue == "string")
    }

    @Test func groupGeneratesNestedCommands() {
        let subCommands: [String: CommandEntry] = [
            "get": .leaf(CommandDef(
                name: "get",
                optionsFields: [makeField("id", .string)],
                handler: NoopHandler()
            ))
        ]

        let commands: [String: CommandEntry] = [
            "users": .group(
                description: "User commands",
                commands: subCommands,
                middleware: [],
                outputPolicy: nil
            )
        ]

        let schema = generateConfigSchema(commands: commands, rootOptions: [])

        let users = schema["properties"]?["commands"]?["properties"]?["users"]
        #expect(users?["type"]?.stringValue == "object")
        let get = users?["properties"]?["commands"]?["properties"]?["get"]
        #expect(get?["type"]?.stringValue == "object")
        #expect(get?["properties"]?["options"]?["properties"]?["id"]?["type"]?.stringValue == "string")
    }

    @Test func enumField() {
        let rootOptions = [
            makeField("format", .enum(["json", "yaml", "toml"]))
        ]

        let schema = generateConfigSchema(commands: [:], rootOptions: rootOptions)

        let format = schema["properties"]?["options"]?["properties"]?["format"]
        #expect(format?["type"]?.stringValue == "string")
        #expect(format?["enum"]?.arrayValue?.count == 3)
    }

    @Test func arrayField() {
        let rootOptions = [
            makeField("tags", .array(.string))
        ]

        let schema = generateConfigSchema(commands: [:], rootOptions: rootOptions)

        let tags = schema["properties"]?["options"]?["properties"]?["tags"]
        #expect(tags?["type"]?.stringValue == "array")
        #expect(tags?["items"]?["type"]?.stringValue == "string")
    }

    @Test func fieldWithDefault() {
        let rootOptions = [
            FieldMeta(name: "retries", description: "Number of retries", fieldType: .number, defaultValue: 3)
        ]

        let schema = generateConfigSchema(commands: [:], rootOptions: rootOptions)

        let retries = schema["properties"]?["options"]?["properties"]?["retries"]
        #expect(retries?["type"]?.stringValue == "number")
        #expect(retries?["default"]?.intValue == 3)
        #expect(retries?["description"]?.stringValue == "Number of retries")
    }

    @Test func commandSchemaGeneration() {
        let command = CommandDef(
            name: "deploy",
            argsFields: [
                FieldMeta(name: "target", description: "Deployment target", fieldType: .string, required: true),
            ],
            optionsFields: [
                FieldMeta(name: "dry_run", description: "Dry run mode", fieldType: .boolean),
                FieldMeta(name: "replicas", description: "Number of replicas", fieldType: .number),
            ],
            handler: NoopHandler()
        )

        let schema = generateCommandSchema(command: command)

        #expect(schema["type"]?.stringValue == "object")
        #expect(schema["properties"]?["target"]?["type"]?.stringValue == "string")
        #expect(schema["properties"]?["target"]?["description"]?.stringValue == "Deployment target")
        #expect(schema["properties"]?["dry-run"]?["type"]?.stringValue == "boolean")
        #expect(schema["properties"]?["replicas"]?["type"]?.stringValue == "number")

        // Required should include "target"
        let required = schema["required"]?.arrayValue
        #expect(required?.contains(.string("target")) == true)
    }
}

// MARK: - Token Operations Tests

@Suite("TokenOperations")
struct TokenOperationsTests {
    @Test func tokenCount() {
        // 20 characters -> 5 tokens (20/4)
        let text = "12345678901234567890"
        let result = applyTokenOperations(text, count: true, limit: nil, offset: nil)
        #expect(result == "5")
    }

    @Test func tokenCountEmpty() {
        let result = applyTokenOperations("", count: true, limit: nil, offset: nil)
        #expect(result == "0")
    }

    @Test func tokenLimit() {
        // 40 chars = 10 tokens. Limit to 5 tokens = first 20 chars.
        let text = "1234567890123456789012345678901234567890"
        let result = applyTokenOperations(text, count: false, limit: 5, offset: nil)
        #expect(result.count == 20)
        #expect(result == "12345678901234567890")
    }

    @Test func tokenOffset() {
        // 40 chars = 10 tokens. Offset 2 tokens = skip first 8 chars.
        let text = "1234567890123456789012345678901234567890"
        let result = applyTokenOperations(text, count: false, limit: nil, offset: 2)
        #expect(result.count == 32)
        #expect(result == "90123456789012345678901234567890")
    }

    @Test func tokenOffsetAndLimit() {
        // 40 chars. Offset 2 tokens (8 chars), limit 3 tokens (12 chars).
        let text = "1234567890123456789012345678901234567890"
        let result = applyTokenOperations(text, count: false, limit: 3, offset: 2)
        #expect(result.count == 12)
        #expect(result == "901234567890")
    }

    @Test func tokenOffsetBeyondEnd() {
        let text = "short"
        let result = applyTokenOperations(text, count: false, limit: nil, offset: 100)
        #expect(result == "")
    }

    @Test func tokenLimitBeyondLength() {
        let text = "short"
        let result = applyTokenOperations(text, count: false, limit: 100, offset: nil)
        #expect(result == "short")
    }
}

// MARK: - Execute Tests

@Suite("Execute")
struct ExecuteTests {
    struct NoopHandler: CommandHandler {
        func run(_ ctx: CommandContext) async -> CommandResult {
            .ok(data: .null)
        }
    }

    @Test func executeRejectsUnknownFlags() async {
        let command = CommandDef(
            name: "test",
            optionsFields: [FieldMeta(name: "verbose", fieldType: .boolean)],
            handler: NoopHandler()
        )
        let opts = ExecuteOptions(argv: ["--unknown-flag"])
        let result = await execute(command: command, options: opts)

        if case .error(let code, let message, _, _, _, _) = result {
            #expect(code == "PARSE_ERROR")
            #expect(message.contains("Unknown flag"))
        } else {
            Issue.record("Expected .error result for unknown flag, got \(result)")
        }
    }
}

// MARK: - Builtin Flags Tests

@Suite("BuiltinFlags")
struct BuiltinFlagsTests {
    @Test func extractBasicFlags() {
        let flags = extractBuiltinFlags(["--help", "--version", "--json", "--verbose"], configFlag: nil)
        #expect(flags.help == true)
        #expect(flags.version == true)
        #expect(flags.json == true)
        #expect(flags.verbose == true)
    }

    @Test func extractFormatFlag() {
        let flags = extractBuiltinFlags(["--format", "table"], configFlag: nil)
        #expect(flags.formatValue == "table")
        #expect(flags.formatExplicit == true)
    }

    @Test func extractFormatFlagEquals() {
        let flags = extractBuiltinFlags(["--format=csv"], configFlag: nil)
        #expect(flags.formatValue == "csv")
        #expect(flags.formatExplicit == true)
    }

    @Test func extractSchemaFlag() {
        let flags = extractBuiltinFlags(["deploy", "--schema"], configFlag: nil)
        #expect(flags.schema == true)
        #expect(flags.rest == ["deploy"])
    }

    @Test func extractConfigSchemaFlag() {
        let flags = extractBuiltinFlags(["--config-schema"], configFlag: nil)
        #expect(flags.configSchema == true)
    }

    @Test func extractTokenFlags() {
        let flags = extractBuiltinFlags(["--token-count", "--token-limit", "100", "--token-offset", "5"], configFlag: nil)
        #expect(flags.tokenCount == true)
        #expect(flags.tokenLimit == 100)
        #expect(flags.tokenOffset == 5)
    }

    @Test func extractTokenFlagsEquals() {
        let flags = extractBuiltinFlags(["--token-limit=100", "--token-offset=5"], configFlag: nil)
        #expect(flags.tokenLimit == 100)
        #expect(flags.tokenOffset == 5)
    }

    @Test func extractConfigFlag() {
        let flags = extractBuiltinFlags(["--config", "myconfig.json", "deploy"], configFlag: "config")
        #expect(flags.configValue == "myconfig.json")
        #expect(flags.rest == ["deploy"])
    }

    @Test func extractConfigFlagEquals() {
        let flags = extractBuiltinFlags(["--config=myconfig.json"], configFlag: "config")
        #expect(flags.configValue == "myconfig.json")
    }

    @Test func extractNoConfigFlag() {
        let flags = extractBuiltinFlags(["--no-config"], configFlag: "config")
        #expect(flags.noConfig == true)
    }

    @Test func restTokensPreserved() {
        let flags = extractBuiltinFlags(["deploy", "production", "--verbose"], configFlag: nil)
        #expect(flags.rest == ["deploy", "production"])
        #expect(flags.verbose == true)
    }

    @Test func doubleDashSeparator() {
        let flags = extractBuiltinFlags(["--verbose", "--", "--help", "foo"], configFlag: nil)
        #expect(flags.verbose == true)
        #expect(flags.help == false)
        #expect(flags.rest == ["--help", "foo"])
    }

    @Test func extractFormatValueCapturedForInvalid() {
        let flags = extractBuiltinFlags(["--format", "invalid"], configFlag: nil)
        #expect(flags.formatValue == "invalid")
        #expect(flags.formatExplicit == true)
    }
}

// MARK: - Format Tests

@Suite("Format")
struct FormatTests {
    @Test func fromValidFormats() {
        #expect(Format.from("toon") == .toon)
        #expect(Format.from("json") == .json)
        #expect(Format.from("yaml") == .yaml)
        #expect(Format.from("md") == .markdown)
        #expect(Format.from("markdown") == .markdown)
        #expect(Format.from("jsonl") == .jsonl)
        #expect(Format.from("table") == .table)
        #expect(Format.from("csv") == .csv)
    }

    @Test func fromCaseInsensitive() {
        #expect(Format.from("JSON") == .json)
        #expect(Format.from("Yaml") == .yaml)
        #expect(Format.from("TABLE") == .table)
    }

    @Test func fromInvalidReturnsNil() {
        #expect(Format.from("invalid") == nil)
        #expect(Format.from("xml") == nil)
        #expect(Format.from("html") == nil)
        #expect(Format.from("") == nil)
        #expect(Format.from("toml") == nil)
    }
}

// MARK: - Fetch Tests

@Suite("Fetch")
struct FetchTests {
    @Test func basicPath() {
        let input = parseFetchArgv(["users", "123"])
        #expect(input.path == "/users/123")
        #expect(input.method == "GET")
        #expect(input.body == nil)
    }

    @Test func emptyPath() {
        let input = parseFetchArgv([])
        #expect(input.path == "/")
    }

    @Test func methodLong() {
        let input = parseFetchArgv(["--method", "PUT", "users", "123"])
        #expect(input.method == "PUT")
        #expect(input.path == "/users/123")
    }

    @Test func methodShort() {
        let input = parseFetchArgv(["-X", "DELETE", "users", "123"])
        #expect(input.method == "DELETE")
    }

    @Test func bodySetsPost() {
        let input = parseFetchArgv(["-d", #"{"name":"test"}"#, "users"])
        #expect(input.method == "POST")
        #expect(input.body == #"{"name":"test"}"#)
    }

    @Test func explicitMethodOverridesBody() {
        let input = parseFetchArgv(["-X", "PUT", "-d", #"{"name":"test"}"#, "users"])
        #expect(input.method == "PUT")
        #expect(input.body != nil)
    }

    @Test func headers() {
        let input = parseFetchArgv(["-H", "Authorization: Bearer token123", "users"])
        #expect(input.headers.count == 1)
        #expect(input.headers[0].0 == "Authorization")
        #expect(input.headers[0].1 == "Bearer token123")
    }

    @Test func queryParams() {
        let input = parseFetchArgv(["users", "--limit", "10", "--offset", "20"])
        #expect(input.path == "/users")
        #expect(input.query.count == 2)
        #expect(input.query.contains(where: { $0.0 == "limit" && $0.1 == "10" }))
        #expect(input.query.contains(where: { $0.0 == "offset" && $0.1 == "20" }))
    }

    @Test func queryWithEquals() {
        let input = parseFetchArgv(["users", "--limit=10"])
        #expect(input.query.count == 1)
        #expect(input.query[0].0 == "limit")
        #expect(input.query[0].1 == "10")
    }

    @Test func dataLong() {
        let input = parseFetchArgv(["--data", #"{"x":1}"#, "api"])
        #expect(input.body == #"{"x":1}"#)
    }

    @Test func bodyLong() {
        let input = parseFetchArgv(["--body", #"{"x":1}"#, "api"])
        #expect(input.body == #"{"x":1}"#)
    }

    @Test func headerEqualsSyntax() {
        let input = parseFetchArgv(["--header=Content-Type: application/json", "api"])
        #expect(input.headers.count == 1)
        #expect(input.headers[0].0 == "Content-Type")
        #expect(input.headers[0].1 == "application/json")
    }

    @Test func mixedEverything() {
        let input = parseFetchArgv([
            "-X", "POST",
            "-H", "Authorization: Bearer tok",
            "-d", #"{"a":1}"#,
            "--limit", "5",
            "api", "v1", "data",
        ])
        #expect(input.method == "POST")
        #expect(input.path == "/api/v1/data")
        #expect(input.body == #"{"a":1}"#)
        #expect(input.headers.count == 1)
        #expect(input.query.count == 1)
        #expect(input.query[0].0 == "limit")
        #expect(input.query[0].1 == "5")
    }

    @Test func isStreamingResponseNdjson() {
        #expect(isStreamingResponse(contentType: "application/x-ndjson") == true)
    }

    @Test func isStreamingResponseJson() {
        #expect(isStreamingResponse(contentType: "application/json") == false)
    }

    @Test func isStreamingResponseNil() {
        #expect(isStreamingResponse(contentType: nil) == false)
    }
}

// MARK: - Skill Tests

@Suite("Skill")
struct SkillTests {
    func makeCmd(_ name: String) -> SkillCommandInfo {
        SkillCommandInfo(
            name: name,
            description: "Does \(name)"
        )
    }

    @Test func indexBasic() {
        let cmds = [makeCmd("deploy"), makeCmd("status")]
        let result = skillIndex(name: "mycli", commands: cmds, description: "A test CLI")
        #expect(result.contains("# mycli"))
        #expect(result.contains("A test CLI"))
        #expect(result.contains("| `mycli deploy` | Does deploy |"))
        #expect(result.contains("| `mycli status` | Does status |"))
    }

    @Test func indexWithArgs() {
        let cmd = SkillCommandInfo(
            name: "deploy",
            argsFields: [
                FieldMeta(name: "target", fieldType: .string, required: true),
                FieldMeta(name: "env", fieldType: .string),
            ]
        )
        let result = skillIndex(name: "mycli", commands: [cmd])
        #expect(result.contains("mycli deploy <target> [env]"))
    }

    @Test func hashDeterministic() {
        let cmds = [makeCmd("deploy"), makeCmd("status")]
        let h1 = skillHash(commands: cmds)
        let h2 = skillHash(commands: cmds)
        #expect(h1 == h2)
        #expect(h1.count == 16)
    }

    @Test func hashChangesOnMutation() {
        let cmds1 = [makeCmd("deploy")]
        let cmds2 = [makeCmd("deploy"), makeCmd("status")]
        #expect(skillHash(commands: cmds1) != skillHash(commands: cmds2))
    }

    @Test func splitDepthZero() {
        let cmds = [makeCmd("deploy"), makeCmd("status")]
        let files = skillSplit(name: "mycli", commands: cmds, depth: 0)
        #expect(files.count == 1)
        #expect(files[0].dir == "")
    }

    @Test func splitDepthOne() {
        let cmds = [
            makeCmd("deploy app"),
            makeCmd("deploy config"),
            makeCmd("status check"),
        ]
        let files = skillSplit(name: "mycli", commands: cmds, depth: 1)
        #expect(files.count == 2)
        let dirs = files.map(\.dir)
        #expect(dirs.contains("deploy"))
        #expect(dirs.contains("status"))
    }

    @Test func slugifyBasic() {
        #expect(slugify("mycli deploy") == "mycli-deploy")
        #expect(slugify("My CLI / Deploy") == "my-cli-deploy")
        #expect(slugify("--edge--case--") == "edge-case")
    }

    @Test func renderBodyWithArgs() {
        let cmd = SkillCommandInfo(
            name: "deploy",
            description: "Deploy the app",
            argsFields: [
                FieldMeta(name: "target", description: "Deploy target", fieldType: .string, required: true),
            ]
        )
        let result = renderCommandBody(cli: "mycli", command: cmd, level: 1)
        #expect(result.contains("# mycli deploy"))
        #expect(result.contains("Deploy the app"))
        #expect(result.contains("## Arguments"))
        #expect(result.contains("| `target` | `string` | yes | Deploy target |"))
    }

    @Test func renderBodyWithOptions() {
        let cmd = SkillCommandInfo(
            name: "list",
            optionsFields: [
                FieldMeta(name: "verbose", description: "Verbose output", fieldType: .boolean, defaultValue: false),
            ]
        )
        let result = renderCommandBody(cli: "mycli", command: cmd, level: 1)
        #expect(result.contains("## Options"))
        #expect(result.contains("| `--verbose` | `boolean` | `false` | Verbose output |"))
    }

    @Test func renderBodyWithExamples() {
        let cmd = SkillCommandInfo(
            name: "deploy",
            examples: [
                Example(command: "production", description: "Deploy to prod"),
            ]
        )
        let result = renderCommandBody(cli: "mycli", command: cmd, level: 1)
        #expect(result.contains("## Examples"))
        #expect(result.contains("```sh"))
        #expect(result.contains("# Deploy to prod"))
        #expect(result.contains("mycli production"))
    }

    @Test func renderBodyWithHint() {
        let cmd = SkillCommandInfo(
            name: "test",
            hint: "Run this often"
        )
        let result = renderCommandBody(cli: "mycli", command: cmd, level: 1)
        #expect(result.contains("> Run this often"))
    }

    @Test func renderBodyWithOutputSchema() {
        let cmd = SkillCommandInfo(
            name: "status",
            outputSchema: [
                "type": "object",
                "properties": [
                    "healthy": [
                        "type": "boolean",
                        "description": "Service health",
                    ]
                ],
                "required": ["healthy"],
            ]
        )
        let result = renderCommandBody(cli: "mycli", command: cmd, level: 1)
        #expect(result.contains("## Output"))
        #expect(result.contains("| `healthy` | `boolean` | yes | Service health |"))
    }

    @Test func schemaToTableNonObject() {
        let schema: JSONValue = ["type": "string"]
        #expect(schemaToTable(schema: schema, prefix: "") == nil)
    }

    @Test func schemaToTableEmptyProperties() {
        let schema: JSONValue = ["type": "object", "properties": [:] as JSONValue]
        #expect(schemaToTable(schema: schema, prefix: "") == nil)
    }

    @Test func generateFullNoGroups() {
        let cmds = [makeCmd("deploy"), makeCmd("status")]
        let result = skillGenerate(name: "mycli", commands: cmds)
        #expect(result.contains("# mycli deploy"))
        #expect(result.contains("# mycli status"))
        // No h2 group headings without groups
        #expect(!result.contains("## mycli"))
    }

    @Test func generateFullWithGroups() {
        let cmds = [makeCmd("deploy app"), makeCmd("deploy config"), makeCmd("status check")]
        let groups = ["deploy": "Deployment commands", "status": "Status commands"]
        let result = skillGenerate(name: "mycli", commands: cmds, groups: groups)
        #expect(result.contains("# mycli"))
        #expect(result.contains("## mycli deploy"))
        #expect(result.contains("Deployment commands"))
        #expect(result.contains("## mycli status"))
        #expect(result.contains("Status commands"))
    }
}

// MARK: - FetchGateway Tests

@Suite("FetchGateway")
struct FetchGatewayTests {
    struct EchoFetchHandler: FetchHandler, @unchecked Sendable {
        func handle(_ request: FetchInput) async -> FetchOutput {
            FetchOutput(
                ok: true,
                status: 200,
                data: [
                    "path": .string(request.path),
                    "method": .string(request.method),
                ]
            )
        }
    }

    @Test func fetchGatewayRegistration() {
        let cli = Cli("test")
            .fetchGateway("api", handler: EchoFetchHandler(), options: FetchGatewayOptions(description: "API gateway"))

        #expect(cli.commands["api"] != nil)
        if case .fetchGateway(_, let opts) = cli.commands["api"] {
            #expect(opts.description == "API gateway")
        } else {
            Issue.record("Expected .fetchGateway case")
        }
    }

    @Test func fetchGatewayAppearsInHelp() {
        let cli = Cli("test")
            .fetchGateway("api", handler: EchoFetchHandler(), options: FetchGatewayOptions(description: "API gateway"))

        let helpCommands = collectHelpCommands(cli.commands)
        #expect(helpCommands.count == 1)
        #expect(helpCommands[0].name == "api")
        #expect(helpCommands[0].description == "API gateway")
    }

    @Test func fetchGatewayAppearsInSkillOutput() {
        let cli = Cli("test")
            .fetchGateway("api", handler: EchoFetchHandler(), options: FetchGatewayOptions(description: "API gateway"))

        let skillCommands = collectSkillCommandInfo(cli.commands)
        #expect(skillCommands.count == 1)
        #expect(skillCommands[0].name == "api")
        #expect(skillCommands[0].description == "API gateway")
    }

    @Test func fetchGatewayResolvesCommand() {
        let cli = Cli("test")
            .fetchGateway("api", handler: EchoFetchHandler(), options: FetchGatewayOptions(description: "API gateway"))

        let resolved = resolveCommand(commands: cli.commands, tokens: ["api", "users", "123"])
        if case .gateway(_, _, let path, let rest) = resolved {
            #expect(path == "api")
            #expect(rest == ["users", "123"])
        } else {
            Issue.record("Expected .gateway case, got \(resolved)")
        }
    }
}

// MARK: - Pager Tests

@Suite("Pager")
struct PagerTests {
    @Test func stdoutInteractiveCallable() {
        // Just verify it doesn't crash
        let _ = stdoutIsInteractive()
    }

    @Test func pagerFallsBackWhenMissing() {
        let original = ProcessInfo.processInfo.environment["PAGER"]
        setenv("PAGER", "__definitely_missing_pager__", 1)
        let result = pageOutput("hello from incur pager")
        if let orig = original {
            setenv("PAGER", orig, 1)
        } else {
            unsetenv("PAGER")
        }
        #expect(result == false)
    }
}

// MARK: - Agents Tests

@Suite("Agents")
struct AgentsTests {
    @Test func testAllAgentsCount() {
        let agents = allAgents()
        #expect(agents.count == 21, "Expected 21 agent definitions")
    }

    @Test func testUniversalAgentsCount() {
        let agents = allAgents()
        let universal = agents.filter { $0.universal }
        #expect(universal.count == 8, "Expected 8 universal agents")
        let names = universal.map(\.name)
        #expect(names == [
            "Amp", "Cline", "Codex", "Cursor",
            "Gemini CLI", "GitHub Copilot", "Kimi CLI", "OpenCode",
        ])
    }

    @Test func testNonUniversalProjectDirs() {
        let agents = allAgents()
        for agent in agents where !agent.universal {
            #expect(
                agent.projectSkillsDir != ".agents/skills",
                "Non-universal agent \(agent.name) should have a unique project skills dir"
            )
        }
    }

    @Test func testSanitizeName() {
        #expect(sanitizeName("my/skill") == "my-skill")
        #expect(sanitizeName("my\\skill") == "my-skill")
        #expect(sanitizeName("my..skill") == "myskill")
        #expect(sanitizeName("  trimmed  ") == "trimmed")
    }

    @Test func testSanitizeNameTruncation() {
        let longName = String(repeating: "a", count: 300)
        let result = sanitizeName(longName)
        #expect(result.count == 255)
    }

    @Test func testExtractSkillName() {
        let content = "---\nname: my-skill\ndescription: A skill\n---\n"
        #expect(extractSkillName(content: content) == "my-skill")
    }

    @Test func testExtractSkillNameMissing() {
        let content = "---\ndescription: No name here\n---\n"
        #expect(extractSkillName(content: content) == nil)
    }

    @Test func testDiffPaths() {
        let target = URL(fileURLWithPath: "/a/b/c/d")
        let base = URL(fileURLWithPath: "/a/b/x/y")
        let rel = diffPaths(target: target, base: base)
        #expect(rel == "../../c/d")
    }

    @Test func testDiffPathsSameDir() {
        let target = URL(fileURLWithPath: "/a/b/c")
        let base = URL(fileURLWithPath: "/a/b")
        let rel = diffPaths(target: target, base: base)
        #expect(rel == "c")
    }

    @Test func testDiscoverSkillsEmptyDir() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("incur-test-discover-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let skills = try discoverSkills(rootDir: dir)
        #expect(skills.isEmpty)
    }

    @Test func testDiscoverSkillsWithSkillMd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("incur-test-discover-\(UUID().uuidString)")
        let skillDir = dir.appendingPathComponent("my-skill")
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        let content = "---\nname: test-skill\n---\nSome content"
        try content.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let skills = try discoverSkills(rootDir: dir)
        #expect(skills.count == 1)
        #expect(skills[0].name == "test-skill")
    }
}

// MARK: - SyncMcp Tests

@Suite("SyncMcp")
struct SyncMcpTests {
    @Test func testAmpConfigPath() {
        let path = ampConfigPath()
        #expect(path.path.contains("amp"))
        #expect(path.path.hasSuffix("settings.json"))
    }

    @Test func testRegisterOptionsDefaults() {
        let opts = RegisterOptions()
        #expect(opts.agents == nil)
        #expect(opts.command == nil)
        #expect(opts.global == true)
    }

    @Test func testRegisterOptionsCustom() {
        let opts = RegisterOptions(agents: ["amp"], command: "mycli --mcp", global: false)
        #expect(opts.agents == ["amp"])
        #expect(opts.command == "mycli --mcp")
        #expect(opts.global == false)
    }

    @Test func testRegisterResultInit() {
        let result = RegisterResult()
        #expect(result.agents.isEmpty)
        #expect(result.command == "")
    }
}

// MARK: - SyncSkills Tests

@Suite("SyncSkills")
struct SyncSkillsTests {
    @Test func testSyncOptionsDefaults() {
        let opts = SyncOptions()
        #expect(opts.cwd == nil)
        #expect(opts.depth == nil)
        #expect(opts.description == nil)
        #expect(opts.global == true)
        #expect(opts.include == nil)
    }

    @Test func testReadSkillsHashNonexistent() {
        #expect(readSkillsHash(name: "nonexistent-test-cli-\(UUID().uuidString)") == nil)
    }

    @Test func testSyncResultInit() {
        let result = SyncResult()
        #expect(result.skills.isEmpty)
        #expect(result.paths.isEmpty)
        #expect(result.agents.isEmpty)
    }

    @Test func testSyncedSkillInit() {
        let skill = SyncedSkill(name: "test", description: "A test", external: true)
        #expect(skill.name == "test")
        #expect(skill.description == "A test")
        #expect(skill.external == true)
    }

    @Test func testInstallResultInit() {
        let result = InstallResult()
        #expect(result.paths.isEmpty)
        #expect(result.agents.isEmpty)
    }

    @Test func testInstallOptionsDefaults() {
        let opts = InstallOptions()
        #expect(opts.agents == nil)
        #expect(opts.cwd == nil)
        #expect(opts.global == true)
    }
}

// MARK: - MCP Tests

@Suite("MCP")
struct McpTests {
    struct NoopHandler: CommandHandler {
        func run(_ ctx: CommandContext) async -> CommandResult {
            .ok(data: .null)
        }
    }

    func makeLeaf(_ name: String, description: String? = nil,
                   argsFields: [FieldMeta] = [],
                   optionsFields: [FieldMeta] = []) -> CommandDef {
        CommandDef(
            name: name,
            description: description,
            argsFields: argsFields,
            optionsFields: optionsFields,
            handler: NoopHandler()
        )
    }

    // MARK: - collectMcpTools

    @Test func testCollectToolsFlat() {
        let commands: [String: CommandEntry] = [
            "deploy": .leaf(makeLeaf("deploy", description: "Deploy app")),
            "status": .leaf(makeLeaf("status", description: "Show status")),
        ]

        let tools = collectMcpTools(commands: commands)
        #expect(tools.count == 2)
        #expect(tools[0].name == "deploy")
        #expect(tools[0].description == "Deploy app")
        #expect(tools[1].name == "status")
        #expect(tools[1].description == "Show status")
    }

    @Test func testCollectToolsNested() {
        let subcommands: [String: CommandEntry] = [
            "app": .leaf(makeLeaf("app", description: "Deploy app")),
            "config": .leaf(makeLeaf("config", description: "Deploy config")),
        ]
        let commands: [String: CommandEntry] = [
            "deploy": .group(
                description: "Deploy group",
                commands: subcommands,
                middleware: [],
                outputPolicy: nil
            ),
            "status": .leaf(makeLeaf("status", description: "Show status")),
        ]

        let tools = collectMcpTools(commands: commands)
        #expect(tools.count == 3)
        #expect(tools[0].name == "deploy_app")
        #expect(tools[1].name == "deploy_config")
        #expect(tools[2].name == "status")
    }

    @Test func testCollectToolsSorted() {
        let commands: [String: CommandEntry] = [
            "zebra": .leaf(makeLeaf("zebra", description: "Z")),
            "alpha": .leaf(makeLeaf("alpha", description: "A")),
            "middle": .leaf(makeLeaf("middle", description: "M")),
        ]

        let tools = collectMcpTools(commands: commands)
        #expect(tools[0].name == "alpha")
        #expect(tools[1].name == "middle")
        #expect(tools[2].name == "zebra")
    }

    @Test func testCollectToolsSkipsFetchGateway() {
        struct DummyFetch: FetchHandler, @unchecked Sendable {
            func handle(_ request: FetchInput) async -> FetchOutput {
                FetchOutput(ok: true, status: 200, data: .null)
            }
        }

        let commands: [String: CommandEntry] = [
            "deploy": .leaf(makeLeaf("deploy", description: "Deploy app")),
            "api": .fetchGateway(handler: DummyFetch(), options: FetchGatewayOptions(description: "API gateway")),
            "status": .leaf(makeLeaf("status", description: "Show status")),
        ]

        let tools = collectMcpTools(commands: commands)
        #expect(tools.count == 2)
        let names = tools.map(\.name)
        #expect(names.contains("deploy"))
        #expect(names.contains("status"))
        #expect(!names.contains("api"))
    }

    // MARK: - buildToolSchema

    @Test func testBuildToolSchemaBasic() {
        let argsFields = [
            FieldMeta(name: "target", description: "Deploy target", fieldType: .string, required: true),
        ]
        let optionsFields = [
            FieldMeta(name: "verbose", description: "Verbose output", fieldType: .boolean),
        ]

        let schema = buildToolSchema(argsFields: argsFields, optionsFields: optionsFields)

        #expect(schema["type"]?.stringValue == "object")

        let props = schema["properties"]
        #expect(props?["target"] != nil)
        #expect(props?["target"]?["type"]?.stringValue == "string")
        #expect(props?["target"]?["description"]?.stringValue == "Deploy target")
        #expect(props?["verbose"] != nil)
        #expect(props?["verbose"]?["type"]?.stringValue == "boolean")

        let required = schema["required"]?.arrayValue
        #expect(required?.count == 1)
        #expect(required?.contains(.string("target")) == true)
    }

    @Test func testBuildToolSchemaRequired() {
        let argsFields = [
            FieldMeta(name: "target", fieldType: .string, required: true),
            FieldMeta(name: "source", fieldType: .string, required: true),
        ]
        let optionsFields = [
            FieldMeta(name: "verbose", fieldType: .boolean),
            FieldMeta(name: "count", fieldType: .number, required: true),
        ]

        let schema = buildToolSchema(argsFields: argsFields, optionsFields: optionsFields)

        let required = schema["required"]?.arrayValue
        #expect(required?.count == 3)
        #expect(required?.contains(.string("target")) == true)
        #expect(required?.contains(.string("source")) == true)
        #expect(required?.contains(.string("count")) == true)
        #expect(required?.contains(.string("verbose")) != true)
    }

    @Test func testBuildToolSchemaNoRequired() {
        let schema = buildToolSchema(
            argsFields: [],
            optionsFields: [FieldMeta(name: "verbose", fieldType: .boolean)]
        )

        // When no fields are required, the "required" key should be absent
        #expect(schema["required"] == nil)
    }

    @Test func testBuildToolSchemaWithDefault() {
        let schema = buildToolSchema(
            argsFields: [],
            optionsFields: [
                FieldMeta(name: "retries", fieldType: .number, defaultValue: 3),
            ]
        )

        #expect(schema["properties"]?["retries"]?["default"]?.intValue == 3)
    }

    @Test func testBuildToolSchemaWithEnum() {
        let schema = buildToolSchema(
            argsFields: [],
            optionsFields: [
                FieldMeta(name: "priority", fieldType: .enum(["low", "medium", "high"])),
            ]
        )

        let priorityProp = schema["properties"]?["priority"]
        #expect(priorityProp?["type"]?.stringValue == "string")
        #expect(priorityProp?["enum"]?.arrayValue?.count == 3)
    }

    // MARK: - fieldTypeToJsonSchemaType

    @Test func testFieldTypeToJsonSchemaType() {
        #expect(fieldTypeToJsonSchemaType(.string) == "string")
        #expect(fieldTypeToJsonSchemaType(.number) == "number")
        #expect(fieldTypeToJsonSchemaType(.boolean) == "boolean")
        #expect(fieldTypeToJsonSchemaType(.array(.string)) == "array")
        #expect(fieldTypeToJsonSchemaType(.enum(["a", "b"])) == "string")
        #expect(fieldTypeToJsonSchemaType(.count) == "integer")
        #expect(fieldTypeToJsonSchemaType(.value) == "string")
    }
}
