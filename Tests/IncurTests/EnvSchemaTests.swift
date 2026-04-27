import Foundation
import Testing
@testable import Incur

// MARK: - CLI-level Env Schema Tests
//
// Mirrors the TS upstream `envSchema` semantics on `Cli.create`:
//   - declared via `Cli().env([...FieldMeta])`,
//   - parsed from a process-env-like source BEFORE middleware runs,
//   - defaults applied for absent vars,
//   - required-but-absent vars produce a VALIDATION_ERROR with `path: "env.<name>"`,
//   - typed fields (number, boolean, enum) coerce values; coercion failures
//     produce VALIDATION_ERROR,
//   - middleware sees the parsed CLI env via `MiddlewareContext.env`,
//   - the handler sees CLI env merged with command-level `envFields` via
//     `CommandContext.env` (command-level wins on conflict).
//
// Tests inject `envSource` directly through `ExecuteOptions` so they never
// touch the real process environment — this keeps them parallel-safe and
// portable across runners that share state across tests.

@Suite("EnvSchema")
struct EnvSchemaTests {
    /// Captures env values that the handler observed.
    final class HandlerObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var _env: JSONValue = .null

        var env: JSONValue {
            lock.lock(); defer { lock.unlock() }
            return _env
        }

        func record(_ env: JSONValue) {
            lock.lock(); defer { lock.unlock() }
            _env = env
        }
    }

    struct CapturingHandler: CommandHandler {
        let observation: HandlerObservation

        func run(_ ctx: CommandContext) async -> CommandResult {
            observation.record(ctx.env)
            return .ok(data: ctx.env, cta: nil)
        }
    }

    private func makeCommand(
        observation: HandlerObservation,
        envFields: [FieldMeta] = []
    ) -> CommandDef {
        CommandDef(
            name: "deploy",
            envFields: envFields,
            handler: CapturingHandler(observation: observation)
        )
    }

    private func runExecute(
        command: CommandDef,
        envFields: [FieldMeta],
        envSource: [String: String] = [:],
        middlewares: [MiddlewareFn] = []
    ) async -> InternalResult {
        await execute(
            command: command,
            options: ExecuteOptions(
                envFields: envFields,
                envSource: envSource,
                middlewares: middlewares
            )
        )
    }

    // MARK: - Builder

    @Test func cliBuilderStoresEnvFields() {
        let cli = Cli("foo").env([
            FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN"),
            FieldMeta(name: "logLevel", fieldType: .string, defaultValue: .string("info"), envName: "LOG_LEVEL"),
        ])
        #expect(cli.envFields.count == 2)
        #expect(cli.envFields[0].name == "apiToken")
        #expect(cli.envFields[0].envName == "API_TOKEN")
        #expect(cli.envFields[0].required == true)
        #expect(cli.envFields[1].defaultValue?.stringValue == "info")
    }

    // MARK: - Env-var read

    @Test func envVarValuePopulatedInHandlerContext() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN"),
            ],
            envSource: ["API_TOKEN": "abc123"]
        )

        if case .ok = result {
            #expect(observation.env["apiToken"]?.stringValue == "abc123")
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    // MARK: - Default values

    @Test func defaultValueAppliedWhenEnvVarMissing() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(
                    name: "logLevel",
                    fieldType: .string,
                    defaultValue: .string("info"),
                    envName: "LOG_LEVEL"
                ),
            ],
            envSource: [:]
        )

        if case .ok = result {
            #expect(observation.env["logLevel"]?.stringValue == "info")
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    @Test func explicitEnvOverridesDefault() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(
                    name: "logLevel",
                    fieldType: .string,
                    defaultValue: .string("info"),
                    envName: "LOG_LEVEL"
                ),
            ],
            envSource: ["LOG_LEVEL": "debug"]
        )
        if case .ok = result {
            #expect(observation.env["logLevel"]?.stringValue == "debug")
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    // MARK: - Required missing

    @Test func requiredEnvVarMissingProducesValidationError() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN"),
            ],
            envSource: [:]
        )

        if case .error(let code, let message, _, let fieldErrors, _, let exitCode) = result {
            #expect(code == "VALIDATION_ERROR")
            #expect(message.contains("API_TOKEN"))
            #expect(exitCode == 1)
            #expect(fieldErrors?.contains(where: { $0.path == "env.apiToken" }) == true)
            #expect(fieldErrors?.first(where: { $0.path == "env.apiToken" })?.received == "undefined")
        } else {
            Issue.record("expected validation error, got: \(result)")
        }
    }

    @Test func handlerNotInvokedWhenEnvValidationFails() async {
        let observation = HandlerObservation()
        _ = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN"),
            ],
            envSource: [:]
        )
        // Handler must not have been reached, so observation stays at .null.
        #expect(observation.env.isNull)
    }

    // MARK: - Type coercion

    @Test func numberEnvVarCoercesIntegerString() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "logLevel", fieldType: .number, required: true, envName: "LOG_LEVEL"),
            ],
            envSource: ["LOG_LEVEL": "42"]
        )
        if case .ok = result {
            #expect(observation.env["logLevel"]?.intValue == 42)
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    @Test func numberEnvVarCoercesDoubleString() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "ratio", fieldType: .number, required: true, envName: "RATIO"),
            ],
            envSource: ["RATIO": "0.5"]
        )
        if case .ok = result {
            #expect(observation.env["ratio"]?.doubleValue == 0.5)
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    @Test func nonNumericNumberEnvVarFailsValidation() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "logLevel", fieldType: .number, required: true, envName: "LOG_LEVEL"),
            ],
            envSource: ["LOG_LEVEL": "oops"]
        )

        if case .error(let code, _, _, let fieldErrors, _, _) = result {
            #expect(code == "VALIDATION_ERROR")
            #expect(fieldErrors?.contains(where: { $0.path == "env.logLevel" }) == true)
            let fe = fieldErrors?.first(where: { $0.path == "env.logLevel" })
            #expect(fe?.expected == "number")
        } else {
            Issue.record("expected validation error, got: \(result)")
        }
    }

    // MARK: - Boolean coercion

    @Test func booleanEnvVarAcceptsCanonicalTrueValues() async {
        for raw in ["1", "true", "yes"] {
            let observation = HandlerObservation()
            let result = await runExecute(
                command: makeCommand(observation: observation),
                envFields: [
                    FieldMeta(name: "debug", fieldType: .boolean, required: true, envName: "DEBUG"),
                ],
                envSource: ["DEBUG": raw]
            )
            if case .ok = result {
                #expect(observation.env["debug"]?.boolValue == true, "expected true for \(raw)")
            } else {
                Issue.record("expected .ok for \(raw), got: \(result)")
            }
        }
    }

    @Test func booleanEnvVarAcceptsCanonicalFalseValues() async {
        for raw in ["0", "false", "no"] {
            let observation = HandlerObservation()
            let result = await runExecute(
                command: makeCommand(observation: observation),
                envFields: [
                    FieldMeta(name: "debug", fieldType: .boolean, required: true, envName: "DEBUG"),
                ],
                envSource: ["DEBUG": raw]
            )
            if case .ok = result {
                #expect(observation.env["debug"]?.boolValue == false, "expected false for \(raw)")
            } else {
                Issue.record("expected .ok for \(raw), got: \(result)")
            }
        }
    }

    @Test func booleanEnvVarRejectsUnknownString() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "debug", fieldType: .boolean, required: true, envName: "DEBUG"),
            ],
            envSource: ["DEBUG": "maybe"]
        )
        if case .error(let code, _, _, let fieldErrors, _, _) = result {
            #expect(code == "VALIDATION_ERROR")
            #expect(fieldErrors?.contains(where: { $0.path == "env.debug" }) == true)
        } else {
            Issue.record("expected validation error, got: \(result)")
        }
    }

    // MARK: - Pre-middleware ordering

    @Test func middlewareSeesPopulatedEnv() async {
        let observation = HandlerObservation()
        // Capture what middleware observed via a Sendable atomic-ish slot.
        final class MwSlot: @unchecked Sendable {
            private let lock = NSLock()
            private var _v: String?
            var value: String? { lock.lock(); defer { lock.unlock() }; return _v }
            func set(_ s: String?) { lock.lock(); defer { lock.unlock() }; _v = s }
        }
        let slot = MwSlot()
        let mw: MiddlewareFn = { @Sendable ctx, next in
            slot.set(ctx.env["apiToken"]?.stringValue)
            await next()
        }

        let result = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN"),
            ],
            envSource: ["API_TOKEN": "tok-xyz"],
            middlewares: [mw]
        )

        if case .ok = result {
            #expect(slot.value == "tok-xyz")
            #expect(observation.env["apiToken"]?.stringValue == "tok-xyz")
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    @Test func middlewareNotInvokedWhenEnvValidationFails() async {
        let observation = HandlerObservation()
        final class MwHits: @unchecked Sendable {
            private let lock = NSLock()
            private var _n = 0
            var n: Int { lock.lock(); defer { lock.unlock() }; return _n }
            func bump() { lock.lock(); defer { lock.unlock() }; _n += 1 }
        }
        let hits = MwHits()
        let mw: MiddlewareFn = { @Sendable _, next in
            hits.bump()
            await next()
        }

        _ = await runExecute(
            command: makeCommand(observation: observation),
            envFields: [
                FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN"),
            ],
            envSource: [:],
            middlewares: [mw]
        )

        #expect(hits.n == 0)
        #expect(observation.env.isNull)
    }

    // MARK: - Coexistence with command-level envFields

    @Test func cliAndCommandEnvFieldsCoexist() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(
                observation: observation,
                envFields: [
                    FieldMeta(name: "baseUrl", fieldType: .string, required: true, envName: "BASE_URL"),
                ]
            ),
            envFields: [
                FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN"),
            ],
            envSource: ["API_TOKEN": "tok", "BASE_URL": "https://api.example.com"]
        )

        if case .ok = result {
            #expect(observation.env["apiToken"]?.stringValue == "tok")
            #expect(observation.env["baseUrl"]?.stringValue == "https://api.example.com")
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    @Test func commandLevelEnvWinsOnKeyConflict() async {
        // When CLI-level and command-level both register the same Swift name,
        // the command-level value reaches the handler. (TS treats them as
        // separate surfaces; we adopt "command-level wins" because the more
        // specific scope is the command's own env declaration.)
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(
                observation: observation,
                envFields: [
                    FieldMeta(
                        name: "logLevel",
                        fieldType: .string,
                        defaultValue: .string("command-default"),
                        envName: "CMD_LOG_LEVEL"
                    ),
                ]
            ),
            envFields: [
                FieldMeta(
                    name: "logLevel",
                    fieldType: .string,
                    defaultValue: .string("cli-default"),
                    envName: "CLI_LOG_LEVEL"
                ),
            ],
            envSource: [:]
        )

        if case .ok = result {
            #expect(observation.env["logLevel"]?.stringValue == "command-default")
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    @Test func commandLevelRequiredEnvErrorAlsoReported() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(
                observation: observation,
                envFields: [
                    FieldMeta(name: "baseUrl", fieldType: .string, required: true, envName: "BASE_URL"),
                ]
            ),
            envFields: [
                FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN"),
            ],
            envSource: ["API_TOKEN": "tok"] // BASE_URL missing
        )

        if case .error(let code, _, _, let fieldErrors, _, _) = result {
            #expect(code == "VALIDATION_ERROR")
            #expect(fieldErrors?.contains(where: { $0.path == "env.baseUrl" }) == true)
        } else {
            Issue.record("expected validation error, got: \(result)")
        }
    }

    // MARK: - Direct helper

    @Test func parseAndValidateEnv_missingRequired() {
        let result = parseAndValidateEnv(
            [FieldMeta(name: "apiToken", fieldType: .string, required: true, envName: "API_TOKEN")],
            source: [:]
        )
        #expect(result.errors.count == 1)
        #expect(result.errors[0].path == "env.apiToken")
        #expect(result.errors[0].received == "undefined")
        #expect(result.values["apiToken"] == nil)
    }

    @Test func parseAndValidateEnv_appliesDefault() {
        let result = parseAndValidateEnv(
            [FieldMeta(
                name: "logLevel",
                fieldType: .string,
                defaultValue: .string("info"),
                envName: "LOG_LEVEL"
            )],
            source: [:]
        )
        #expect(result.errors.isEmpty)
        #expect(result.values["logLevel"]?.stringValue == "info")
    }

    @Test func parseAndValidateEnv_envNameFallsBackToFieldName() {
        // When `envName` is nil, the OS env-var name defaults to the field name.
        let result = parseAndValidateEnv(
            [FieldMeta(name: "API_TOKEN", fieldType: .string, required: true)],
            source: ["API_TOKEN": "abc"]
        )
        #expect(result.errors.isEmpty)
        #expect(result.values["API_TOKEN"]?.stringValue == "abc")
    }
}
