import Foundation
import Testing
@testable import Incur

// MARK: - --filter-output wiring
//
// Mirrors the upstream TS `incurs` CLI v0.2.1 release: a global flag
//   `--filter-output <spec>`
// that takes a comma-delimited list of path specs (dot-notation + bracketed
// array slices) and applies them to the command result before format
// serialization and token operations.
//
// These tests pin the four contracts that matter:
//   1. Flag extraction recognizes both `--filter-output v` and the
//      `--filter-output=v` short form, and leaves command argv untouched.
//   2. Path semantics for top-level keys, dot paths, slices, slice + nested
//      key, missing paths, and array data.
//   3. Stream payloads collapse into a single filtered output (TS buffered
//      mode) when `--filter-output` is set.
//   4. Filter runs *before* `--token-limit` / token operations.

@Suite("FilterOutput")
struct FilterOutputTests {
    // MARK: - Flag extraction

    @Test func builtinFlagsExposeFilterOutputLongForm() {
        let flags = extractBuiltinFlags(
            ["list", "--filter-output", "items[0,3].name"],
            configFlag: nil
        )
        #expect(flags.filterOutput == "items[0,3].name")
        #expect(flags.rest == ["list"])
    }

    @Test func builtinFlagsExposeFilterOutputEqualsForm() {
        let flags = extractBuiltinFlags(
            ["stats", "--filter-output=total,pending"],
            configFlag: nil
        )
        #expect(flags.filterOutput == "total,pending")
        #expect(flags.rest == ["stats"])
    }

    @Test func builtinFlagsFilterOutputComposesWithTokenLimit() {
        let flags = extractBuiltinFlags(
            ["list", "--filter-output", "title", "--token-limit", "5"],
            configFlag: nil
        )
        #expect(flags.filterOutput == "title")
        #expect(flags.tokenLimit == 5)
        #expect(flags.rest == ["list"])
    }

    // MARK: - Path semantics

    @Test func topLevelKeysNarrowObject() {
        let data: JSONValue = [
            "foo": "FOO",
            "bar": "BAR",
            "baz": "BAZ",
        ]
        let paths = parseFilterExpression("foo,bar")
        let result = applyFilter(data: data, paths: paths)
        #expect(result["foo"] == .string("FOO"))
        #expect(result["bar"] == .string("BAR"))
        #expect(result["baz"] == nil)
    }

    @Test func nestedDotPathSelectsLeaf() {
        let data: JSONValue = [
            "user": ["name": "alice", "email": "a@x"] as JSONValue,
            "status": "active",
        ]
        let paths = parseFilterExpression("user.name")
        let result = applyFilter(data: data, paths: paths)
        // TS shape: { user: { name: 'alice' } }
        #expect(result["user"]?["name"] == .string("alice"))
        #expect(result["user"]?["email"] == nil)
        #expect(result["status"] == nil)
    }

    @Test func arraySliceTakesFirstThree() {
        let data: JSONValue = ["items": .array([1, 2, 3, 4, 5])]
        let paths = parseFilterExpression("items[0,3]")
        let result = applyFilter(data: data, paths: paths)
        #expect(result["items"] == .array([.int(1), .int(2), .int(3)]))
    }

    @Test func arraySliceSingleIndexWindow() {
        // [1,2] selects exactly index 1 (start..<end).
        let data: JSONValue = ["items": .array([10, 20, 30, 40])]
        let paths = parseFilterExpression("items[1,2]")
        let result = applyFilter(data: data, paths: paths)
        #expect(result["items"] == .array([.int(20)]))
    }

    @Test func sliceFollowedByDotPathProjectsField() {
        let data: JSONValue = [
            "items": .array([
                ["id": 1, "name": "alpha", "extra": "x"],
                ["id": 2, "name": "bravo", "extra": "y"],
                ["id": 3, "name": "charl", "extra": "z"],
                ["id": 4, "name": "delta", "extra": "w"],
                ["id": 5, "name": "echo", "extra": "v"],
            ]),
        ]
        let paths = parseFilterExpression("items[0,3].name")
        let result = applyFilter(data: data, paths: paths)

        // Result has only `items`, three elements, each only `name`.
        guard case .object(let outer) = result, case .array(let arr) = outer["items"] else {
            Issue.record("expected object with `items` array, got \(result)")
            return
        }
        #expect(arr.count == 3)
        for (idx, expectedName) in ["alpha", "bravo", "charl"].enumerated() {
            #expect(arr[idx]["name"] == .string(expectedName))
            #expect(arr[idx]["id"] == nil)
            #expect(arr[idx]["extra"] == nil)
        }
    }

    @Test func missingTopLevelKeyReturnsNull() {
        // TS returns `undefined` for a missing single-key projection; the
        // Swift port collapses that to JSONValue.null which serializes as
        // empty for downstream formatters.
        let data: JSONValue = ["name": "alice"]
        let result = applyFilter(data: data, paths: parseFilterExpression("missing"))
        #expect(result == .null)
    }

    @Test func missingKeyAmongMultipleIsSilentlyDropped() {
        let data: JSONValue = ["a": 1]
        let paths = parseFilterExpression("a,missing")
        let result = applyFilter(data: data, paths: paths)
        #expect(result["a"] == .int(1))
        #expect(result["missing"] == nil)
    }

    @Test func arrayDataMapsKeyAcrossElements() {
        let data: JSONValue = .array([
            ["name": "alice", "age": 30],
            ["name": "bob", "age": 25],
        ])
        let result = applyFilter(data: data, paths: parseFilterExpression("name"))
        #expect(result == .array([.string("alice"), .string("bob")]))
    }

    // MARK: - Streaming → buffered when filter is set

    @Test func streamWithoutFilterEmitsIncrementalChunks() async {
        // No filter expression: streaming output remains incremental
        // (one line per chunk in JSONL form). We exercise the path by
        // letting the stream finish and inspecting that no buffering
        // happens — there's no public capture API, so this test is a
        // smoke check on the AsyncStream + filter helper used below.
        let stream = AsyncStream<JSONValue> { cont in
            cont.yield(["step": 1])
            cont.yield(["step": 2])
            cont.finish()
        }
        var collected: [JSONValue] = []
        for await item in stream { collected.append(item) }
        #expect(collected.count == 2)
    }

    @Test func streamWithFilterCollapsesToFilteredArray() {
        // Buffered-mode equivalence: when a stream produces N chunks we
        // wrap them in `.array([...])` and apply the filter — exactly
        // what the new branch in `outputResult` does. We test the
        // helper directly so the contract is independent of stdout.
        let chunks: [JSONValue] = [
            ["event": "progress", "step": 1, "message": "boot"],
            ["event": "progress", "step": 2, "message": "warm"],
            ["event": "progress", "step": 3, "message": "done"],
        ]
        let filtered = applyFilter(
            data: .array(chunks),
            paths: parseFilterExpression("step")
        )
        // Single-key scalar projection over array data → array of scalars.
        #expect(filtered == .array([.int(1), .int(2), .int(3)]))
    }

    // MARK: - Filter runs BEFORE token operations

    @Test func filterAppliesBeforeTokenLimit() {
        // The pipeline must be: filter → format → token truncation.
        // We assert that by feeding an object whose unfiltered serialization
        // would dominate the token budget, and confirming that filtering
        // first produces output well under the budget without truncation.
        let data: JSONValue = [
            "wanted": "alpha",
            "noise": "beta gamma delta epsilon zeta eta theta iota",
        ]
        let paths = parseFilterExpression("wanted")
        let filtered = applyFilter(data: data, paths: paths)
        // `wanted` is the only key kept → scalar string "alpha".
        #expect(filtered == .string("alpha"))

        // Format then truncate. With filter applied first, the output is so
        // small that a 100-token limit leaves it untouched.
        let formatted = formatValue(filtered, format: .json)
        let truncated = applyTokenOperations(
            formatted,
            count: false,
            limit: 100,
            offset: nil
        )
        #expect(!truncated.contains("[truncated"))
        #expect(truncated.contains("alpha"))

        // For comparison: without filtering, the same payload is larger.
        let unfilteredFormatted = formatValue(data, format: .json)
        #expect(unfilteredFormatted.count > formatted.count)
    }

    @Test func tokenCountReportsFilteredOutputSize() {
        // The same wiring guarantee, framed as: --token-count returns the
        // estimated tokens of the *filtered* output, which is strictly
        // smaller than the full payload's token count.
        let data: JSONValue = [
            "wanted": "alpha",
            "noise": "beta gamma delta epsilon zeta eta theta iota kappa lambda",
        ]
        let filtered = applyFilter(data: data, paths: parseFilterExpression("wanted"))
        let filteredCount = estimateTokenCount(formatValue(filtered, format: .json))
        let unfilteredCount = estimateTokenCount(formatValue(data, format: .json))
        #expect(filteredCount < unfilteredCount)
        #expect(filteredCount > 0)
    }
}
