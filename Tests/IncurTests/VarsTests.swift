import Foundation
import Testing
@testable import Incur

// MARK: - Vars Schema Tests
//
// Mirror the TS upstream `vars` semantics:
//   - declared via `Cli().vars([...FieldMeta])`,
//   - defaults pre-seeded into MutableVars before middleware runs,
//   - middleware sets values via `ctx.vars["key"] = ...`,
//   - the handler reads the snapshot via `ctx.vars["key"]?.stringValue`,
//   - missing required fields produce a VALIDATION_ERROR,
//   - type mismatches produce a VALIDATION_ERROR.

@Suite("Vars")
struct VarsTests {
    /// Captures vars values that the handler observed.
    final class HandlerObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var _vars: JSONValue = .null

        var vars: JSONValue {
            lock.lock(); defer { lock.unlock() }
            return _vars
        }

        func record(_ vars: JSONValue) {
            lock.lock(); defer { lock.unlock() }
            _vars = vars
        }
    }

    struct CapturingHandler: CommandHandler {
        let observation: HandlerObservation

        func run(_ ctx: CommandContext) async -> CommandResult {
            observation.record(ctx.vars)
            return .ok(data: ctx.vars, cta: nil)
        }
    }

    private func makeCommand(observation: HandlerObservation) -> CommandDef {
        CommandDef(name: "whoami", handler: CapturingHandler(observation: observation))
    }

    private func runExecute(
        command: CommandDef,
        varsFields: [FieldMeta],
        middlewares: [MiddlewareFn] = []
    ) async -> InternalResult {
        await execute(
            command: command,
            options: ExecuteOptions(
                middlewares: middlewares,
                varsFields: varsFields
            )
        )
    }

    // MARK: - Schema declaration

    @Test func cliBuilderStoresVarsFields() {
        let cli = Cli("app").vars([
            FieldMeta(name: "userId", fieldType: .string, required: true),
            FieldMeta(name: "tenant", fieldType: .string, defaultValue: "public"),
        ])
        #expect(cli.varsFields.count == 2)
        #expect(cli.varsFields[0].name == "userId")
        #expect(cli.varsFields[0].required == true)
        #expect(cli.varsFields[1].defaultValue?.stringValue == "public")
    }

    // MARK: - Middleware sets, handler reads

    @Test func middlewareSetsAndHandlerReads() async {
        let observation = HandlerObservation()
        let mw: MiddlewareFn = { @Sendable ctx, next in
            ctx.vars["userId"] = .string("alice")
            await next()
        }

        let result = await runExecute(
            command: makeCommand(observation: observation),
            varsFields: [FieldMeta(name: "userId", fieldType: .string, required: true)],
            middlewares: [mw]
        )

        #expect(observation.vars["userId"]?.stringValue == "alice")
        if case .ok(let data, _) = result {
            #expect(data["userId"]?.stringValue == "alice")
        } else {
            Issue.record("expected .ok result, got: \(result)")
        }
    }

    // MARK: - Required vars enforcement

    @Test func missingRequiredVarFailsValidation() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            varsFields: [FieldMeta(name: "userId", fieldType: .string, required: true)]
        )

        if case .error(let code, let message, _, let fieldErrors, _, _) = result {
            #expect(code == "VALIDATION_ERROR")
            #expect(message.contains("userId"))
            #expect(fieldErrors?.contains(where: { $0.path == "vars.userId" }) == true)
        } else {
            Issue.record("expected validation error, got: \(result)")
        }
    }

    @Test func requiredVarSatisfiedByMiddleware() async {
        let observation = HandlerObservation()
        let mw: MiddlewareFn = { @Sendable ctx, next in
            ctx.vars["userId"] = .string("bob")
            await next()
        }
        let result = await runExecute(
            command: makeCommand(observation: observation),
            varsFields: [FieldMeta(name: "userId", fieldType: .string, required: true)],
            middlewares: [mw]
        )
        if case .ok = result {
            #expect(observation.vars["userId"]?.stringValue == "bob")
        } else {
            Issue.record("expected .ok, got: \(result)")
        }
    }

    // MARK: - Default values

    @Test func defaultValueIsSeededWhenMiddlewareDoesNotSet() async {
        let observation = HandlerObservation()
        let result = await runExecute(
            command: makeCommand(observation: observation),
            varsFields: [
                FieldMeta(name: "userId", fieldType: .string, defaultValue: .string("guest")),
            ]
        )
        if case .ok = result {
            #expect(observation.vars["userId"]?.stringValue == "guest")
        } else {
            Issue.record("expected .ok, got: \(result)")
        }
    }

    @Test func middlewareOverridesDefault() async {
        let observation = HandlerObservation()
        let mw: MiddlewareFn = { @Sendable ctx, next in
            ctx.vars["userId"] = .string("alice")
            await next()
        }
        let result = await runExecute(
            command: makeCommand(observation: observation),
            varsFields: [
                FieldMeta(name: "userId", fieldType: .string, defaultValue: .string("guest")),
            ],
            middlewares: [mw]
        )
        if case .ok = result {
            #expect(observation.vars["userId"]?.stringValue == "alice")
        } else {
            Issue.record("expected .ok, got: \(result)")
        }
    }

    // MARK: - Type validation

    @Test func numberVarRejectsStringValue() async {
        let observation = HandlerObservation()
        let mw: MiddlewareFn = { @Sendable ctx, next in
            ctx.vars["count"] = .string("not-a-number")
            await next()
        }
        let result = await runExecute(
            command: makeCommand(observation: observation),
            varsFields: [FieldMeta(name: "count", fieldType: .number, required: true)],
            middlewares: [mw]
        )
        if case .error(let code, _, _, let fieldErrors, _, _) = result {
            #expect(code == "VALIDATION_ERROR")
            #expect(fieldErrors?.contains(where: { $0.path == "vars.count" }) == true)
        } else {
            Issue.record("expected validation error, got: \(result)")
        }
    }

    @Test func numberVarAcceptsIntAndDouble() async {
        let observation = HandlerObservation()
        let mw: MiddlewareFn = { @Sendable ctx, next in
            ctx.vars["count"] = .int(42)
            ctx.vars["ratio"] = .double(0.5)
            await next()
        }
        let result = await runExecute(
            command: makeCommand(observation: observation),
            varsFields: [
                FieldMeta(name: "count", fieldType: .number, required: true),
                FieldMeta(name: "ratio", fieldType: .number, required: true),
            ],
            middlewares: [mw]
        )
        if case .ok = result {
            #expect(observation.vars["count"]?.intValue == 42)
            #expect(observation.vars["ratio"]?.doubleValue == 0.5)
        } else {
            Issue.record("expected .ok, got: \(result)")
        }
    }

    // MARK: - MutableVars thread safety / Sendable surface

    @Test func mutableVarsIsThreadSafeUnderConcurrentWrites() async {
        let vars = MutableVars()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 {
                group.addTask {
                    vars["k\(i)"] = .int(i)
                }
            }
        }
        let snapshot = vars.snapshotMap()
        #expect(snapshot.count == 200)
    }

    @Test func commandContextIsSendable() {
        // Compile-time assertion: CommandContext must be Sendable for the
        // execute pipeline to thread it through actor boundaries.
        func acceptsSendable<T: Sendable>(_ value: T) {}
        let ctx = CommandContext(vars: .object(OrderedMap()))
        acceptsSendable(ctx)
    }

    // MARK: - validateVars helper directly

    @Test func validateVarsDirect_missingRequired() {
        var map = OrderedMap()
        map["other"] = .string("x")
        let err = validateVars(
            [FieldMeta(name: "needed", fieldType: .string, required: true)],
            vars: map
        )
        #expect(err != nil)
        #expect(err?.fieldErrors.first?.path == "vars.needed")
    }

    @Test func validateVarsDirect_passesWhenAllPresent() {
        var map = OrderedMap()
        map["needed"] = .string("ok")
        let err = validateVars(
            [FieldMeta(name: "needed", fieldType: .string, required: true)],
            vars: map
        )
        #expect(err == nil)
    }

    @Test func validateVarsDirect_typeMismatch() {
        var map = OrderedMap()
        map["flag"] = .string("yes")
        let err = validateVars(
            [FieldMeta(name: "flag", fieldType: .boolean, required: true)],
            vars: map
        )
        #expect(err != nil)
    }

    @Test func validateVarsDirect_enumChecksAllowedValues() {
        var map = OrderedMap()
        map["env"] = .string("prod")
        let okErr = validateVars(
            [FieldMeta(name: "env", fieldType: .enum(["dev", "prod"]), required: true)],
            vars: map
        )
        #expect(okErr == nil)

        var bad = OrderedMap()
        bad["env"] = .string("staging")
        let badErr = validateVars(
            [FieldMeta(name: "env", fieldType: .enum(["dev", "prod"]), required: true)],
            vars: bad
        )
        #expect(badErr != nil)
    }
}
