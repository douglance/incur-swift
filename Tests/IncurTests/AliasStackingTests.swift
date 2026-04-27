import Foundation
import Testing
@testable import Incur

// MARK: - Alias Stacking Tests
//
// Documents and pins the behavior of the `parse` function when handling
// POSIX-style stacked short flags (`-abc` -> `-a -b -c`).
//
// The parser source (`Sources/Incur/Parser.swift`) already implements this;
// these tests guard against regressions and document edge-case behavior.

@Suite("AliasStacking")
struct AliasStackingTests {
    // -abc parses as -a -b -c when all three are boolean flags
    @Test func threeBooleansStacked() throws {
        let opts = ParseOptions(
            optionsFields: [
                FieldMeta(name: "all", fieldType: .boolean, alias: "a"),
                FieldMeta(name: "bare", fieldType: .boolean, alias: "b"),
                FieldMeta(name: "color", fieldType: .boolean, alias: "c"),
            ]
        )
        let result = try parse(argv: ["-abc"], options: opts)
        #expect(result.options["all"] == .bool(true))
        #expect(result.options["bare"] == .bool(true))
        #expect(result.options["color"] == .bool(true))
    }

    // -vvv increments a count flag to 3
    @Test func countFlagStackingTriple() throws {
        let opts = ParseOptions(
            optionsFields: [FieldMeta(name: "verbose", fieldType: .count, alias: "v")]
        )
        let result = try parse(argv: ["-vvv"], options: opts)
        #expect(result.options["verbose"] == .int(3))
    }

    // -abf=foo : two booleans then a string with =value attached.
    //
    // The current Swift parser iterates each char in `-abf=foo` as a separate
    // alias; `=` is not a registered alias so it errors. This pins that
    // behavior. POSIX-style `-abf=foo` (ending the stack with `f=value`) is
    // NOT supported by the current implementation.
    @Test func valueWithEqualsInsideStackErrors() throws {
        let opts = ParseOptions(
            optionsFields: [
                FieldMeta(name: "all", fieldType: .boolean, alias: "a"),
                FieldMeta(name: "bare", fieldType: .boolean, alias: "b"),
                FieldMeta(name: "file", fieldType: .string, alias: "f"),
            ]
        )
        #expect(throws: ParseError.self) {
            try parse(argv: ["-abf=foo"], options: opts)
        }
    }

    // -abf foo : two booleans then a string flag whose value is the next argv
    // token. This IS the supported equivalent of `-a -b -f foo`.
    @Test func twoBooleansThenStringValueAsNextToken() throws {
        let opts = ParseOptions(
            optionsFields: [
                FieldMeta(name: "all", fieldType: .boolean, alias: "a"),
                FieldMeta(name: "bare", fieldType: .boolean, alias: "b"),
                FieldMeta(name: "file", fieldType: .string, alias: "f"),
            ]
        )
        let result = try parse(argv: ["-abf", "foo"], options: opts)
        #expect(result.options["all"] == .bool(true))
        #expect(result.options["bare"] == .bool(true))
        #expect(result.options["file"] == .string("foo"))
    }

    // Edge case: `-a-` — single flag with trailing dash.
    //
    // The Swift parser treats every char after the leading `-` as an alias
    // lookup. `-a-` therefore tries `a` (the boolean) then `-` (which is not
    // a registered alias) and throws ParseError. This test documents that
    // behavior; we are not changing Parser.swift in this task.
    @Test func singleAliasWithTrailingDashErrors() throws {
        let opts = ParseOptions(
            optionsFields: [FieldMeta(name: "all", fieldType: .boolean, alias: "a")]
        )
        #expect(throws: ParseError.self) {
            try parse(argv: ["-a-"], options: opts)
        }
    }
}
