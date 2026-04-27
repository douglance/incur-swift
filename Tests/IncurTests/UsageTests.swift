import Foundation
import Testing
@testable import Incur

// MARK: - Usage Tests

@Suite("Usage")
struct UsageTests {
    struct NoopHandler: CommandHandler {
        func run(_ ctx: CommandContext) async -> CommandResult {
            .ok(data: .null)
        }
    }

    // MARK: - Construction

    @Test func usageInitializerDefaults() {
        let usage = Usage()
        #expect(usage.args.isEmpty)
        #expect(usage.options.isEmpty)
        #expect(usage.prefix == nil)
        #expect(usage.suffix == nil)
    }

    @Test func usageInitializerFull() {
        let usage = Usage(
            args: ["title": .string("Buy milk")],
            options: ["priority": .string("high")],
            prefix: "Quick add",
            suffix: "creates a hi-pri item"
        )
        #expect(usage.args["title"] == .string("Buy milk"))
        #expect(usage.options["priority"] == .string("high"))
        #expect(usage.prefix == "Quick add")
        #expect(usage.suffix == "creates a hi-pri item")
    }

    @Test func commandDefAcceptsUsage() {
        let cmd = CommandDef(
            name: "task",
            argsFields: [FieldMeta(name: "title", fieldType: .string, required: true)],
            usage: [
                Usage(
                    args: ["title": .string("Buy milk")],
                    prefix: "Quick add",
                    suffix: "creates a hi-pri item"
                )
            ],
            handler: NoopHandler()
        )
        #expect(cmd.usage.count == 1)
        #expect(cmd.usage[0].prefix == "Quick add")
        #expect(cmd.usage[0].suffix == "creates a hi-pri item")
    }

    @Test func commandDefDefaultsToEmptyUsage() {
        let cmd = CommandDef(name: "noop", handler: NoopHandler())
        #expect(cmd.usage.isEmpty)
    }

    @Test func commandBuilderUsage() {
        let cmd = CommandDef.build("greet", handler: NoopHandler())
            .description("say hi")
            .usage([Usage(prefix: "echo hi |", suffix: "| cat")])
            .done()
        #expect(cmd.usage.count == 1)
        #expect(cmd.usage[0].prefix == "echo hi |")
        #expect(cmd.usage[0].suffix == "| cat")
    }

    // MARK: - Help Rendering

    @Test func helpEmitsUsageEntryWithPrefixCommandAndSuffix() {
        let help = formatCommandHelp(
            name: "task-cli add",
            options: FormatCommandOptions(
                argsFields: [FieldMeta(name: "title", fieldType: .string, required: true)],
                usage: [
                    Usage(
                        args: ["title": .string("Buy milk")],
                        prefix: "Quick add:",
                        suffix: "# creates a hi-pri item"
                    )
                ]
            )
        )
        // Single rendered line carries the prefix label, the fully-formed
        // command line (cli name + concrete arg value), and the suffix.
        #expect(help.contains("Usage: Quick add: task-cli add \"Buy milk\" # creates a hi-pri item"))
    }

    @Test func helpRendersMultipleUsageEntriesInOrder() {
        let help = formatCommandHelp(
            name: "grep",
            options: FormatCommandOptions(
                argsFields: [FieldMeta(name: "pattern", fieldType: .string, required: true)],
                usage: [
                    Usage(args: ["pattern": .string("foo")], suffix: "file.txt"),
                    Usage(args: ["pattern": .string("bar")], prefix: "cat input.txt |"),
                ]
            )
        )
        let lines = help.split(separator: "\n").map(String.init)
        guard let first = lines.firstIndex(where: { $0.contains("Usage:") && $0.contains("foo") }) else {
            Issue.record("first usage entry missing")
            return
        }
        // Second entry should be on a continuation line indented to align
        // under the synopsis, preserving order.
        let second = lines[first + 1]
        #expect(second.contains("bar"))
        #expect(second.contains("cat input.txt |"))
        // Continuation lines are padded by the width of "Usage: " (7 spaces).
        #expect(second.hasPrefix("       "))
    }

    @Test func helpEmptyUsageDoesNotEmitSection() {
        let help = formatCommandHelp(
            name: "deploy",
            options: FormatCommandOptions(
                argsFields: [FieldMeta(name: "env", fieldType: .string, required: true)],
                description: "Deploy"
            )
        )
        // Standard synopsis must remain byte-identical for commands with no usage.
        #expect(help.contains("Usage: deploy <env>"))
    }

    @Test func helpUsageAndExamplesCoexist() {
        let help = formatCommandHelp(
            name: "deploy",
            options: FormatCommandOptions(
                argsFields: [FieldMeta(name: "env", fieldType: .string, required: true)],
                examples: [Example(command: "production", description: "Deploy to prod")],
                usage: [Usage(args: ["env": .string("staging")], prefix: "first run:")]
            )
        )
        // Usage replaces the standard synopsis line (TS behavior).
        #expect(help.contains("Usage: first run: deploy staging"))
        // Examples section still renders independently.
        #expect(help.contains("Examples:"))
        #expect(help.contains("deploy production"))
        #expect(help.contains("# Deploy to prod"))
    }

    @Test func helpUsageRendersOptionFlags() {
        let help = formatCommandHelp(
            name: "build",
            options: FormatCommandOptions(
                usage: [
                    Usage(
                        options: [
                            "target": .string("release"),
                            "noCache": .bool(true),
                        ]
                    )
                ],
                optionsFields: [
                    FieldMeta(name: "target", fieldType: .string),
                    FieldMeta(name: "noCache", cliName: "no-cache", fieldType: .boolean),
                ]
            )
        )
        // String option value is emitted verbatim; boolean `true` collapses to
        // a placeholder (TS `Record<key, true>` semantics). cliName mapping is
        // honored for the flag itself.
        #expect(help.contains("--target release"))
        #expect(help.contains("--no-cache <noCache>"))
    }

    @Test func helpUsageQuotesWhitespaceStrings() {
        let help = formatCommandHelp(
            name: "say",
            options: FormatCommandOptions(
                argsFields: [FieldMeta(name: "msg", fieldType: .string, required: true)],
                usage: [Usage(args: ["msg": .string("hello world")])]
            )
        )
        #expect(help.contains("\"hello world\""))
    }
}
