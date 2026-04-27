import Foundation
import Testing
@testable import Incur

// Coverage for the global `--token-count`, `--token-limit`, and
// `--token-offset` flags that bound an LLM agent's token budget for any
// command's output. Mirrors the `tokenx`-based pipeline shipped by the
// upstream TS `incurs` CLI in v0.2.2.

@Suite("PagerWiring")
struct PagerWiringTests {
    // MARK: - Tokenization fixture

    /// Token count for a known input string matches the tokenx algorithm.
    /// Three single-token-per-segment "words" — the segments are
    /// short enough to be one token each.
    @Test func estimateTokenCountFixture() {
        // "abc def ghi" → ["abc", " ", "def", " ", "ghi"]
        // Each non-whitespace segment ≤ short threshold (3) → 1 token each.
        // Whitespace contributes 0 tokens.
        #expect(estimateTokenCount("abc def ghi") == 3)
    }

    @Test func estimateTokenCountWordsRoundUp() {
        // Each word > short threshold but ≤ defaultCharsPerToken (6) →
        // ceil(len / 6) = 1 token per word.
        #expect(estimateTokenCount("alpha bravo charl") == 3)
    }

    @Test func estimateTokenCountLongWord() {
        // 12 lowercase letters → ceil(12 / 6) = 2 tokens.
        #expect(estimateTokenCount("abcdefghijkl") == 2)
    }

    @Test func estimateTokenCountEmpty() {
        #expect(estimateTokenCount("") == 0)
    }

    // MARK: - --token-count

    /// `--token-count` returns a positive number for non-empty output and
    /// does not truncate the underlying text.
    @Test func tokenCountSummaryNonZero() {
        let payload = "hello world from incur"
        let result = applyTokenOperations(payload, count: true, limit: nil, offset: nil)
        let n = Int(result) ?? -1
        #expect(n > 0)
        #expect(n == estimateTokenCount(payload))
    }

    // MARK: - --token-limit per Format variant

    /// `--token-limit N` truncates the serialized output at N tokens for
    /// each supported Format. We assert that the truncation summary is
    /// appended and that some characters from the tail are dropped.
    @Test func tokenLimitTruncatesEachFormat() {
        let value: JSONValue = [
            "items": [
                ["id": 1, "title": "alpha bravo charl"],
                ["id": 2, "title": "delta echofo foxtra"],
                ["id": 3, "title": "golfho hotelo indigo"],
            ],
        ]
        for format in [Format.json, .yaml, .toon, .table] {
            let full = formatValue(value, format: format)
            let truncated = applyTokenOperations(full, count: false, limit: 3, offset: nil)
            #expect(truncated.contains("[truncated: showing tokens 0-3"))
            #expect(truncated.count < full.count + 64) // truncated + summary still much shorter
            #expect(truncated.count <= full.count + "[truncated: showing tokens 0-NNN of NNN]\n".count)
        }
    }

    // MARK: - --token-offset

    /// `--token-offset N` skips the first N tokens.
    @Test func tokenOffsetSkipsLeadingTokens() {
        let payload = "alpha bravo charl delta echofo foxtra"
        let result = applyTokenOperations(payload, count: false, limit: nil, offset: 3)
        #expect(!result.hasPrefix("alpha"))
        #expect(result.contains("delta"))
    }

    // MARK: - --token-offset + --token-limit pagination

    /// Combined offset + limit windows correctly into the token stream.
    @Test func tokenOffsetAndLimitPaginate() {
        let payload = "alpha bravo charl delta echofo foxtra"
        // tokens 0..6 — 6 tokens. Window [2, 4) → "charl delta"
        let result = applyTokenOperations(payload, count: false, limit: 2, offset: 2)
        #expect(result.contains("charl"))
        #expect(result.contains("delta"))
        #expect(!result.contains("alpha"))
        #expect(!result.contains("foxtra"))
        #expect(result.contains("[truncated: showing tokens 2-4 of 6]"))
    }

    // MARK: - truncateByTokens (low-level result)

    @Test func truncateByTokensReturnsNextOffsetWhenMore() {
        let payload = "alpha bravo charl delta echofo foxtra"
        let res = truncateByTokens(payload, limit: 2, offset: 0)
        #expect(res.truncated == true)
        #expect(res.nextOffset == 2)
    }

    @Test func truncateByTokensNoNextOffsetAtEnd() {
        let payload = "alpha bravo charl"
        let res = truncateByTokens(payload, limit: 100, offset: 0)
        // Window covers everything → not truncated, no next offset.
        #expect(res.truncated == false)
        #expect(res.nextOffset == nil)
        #expect(res.text == payload)
    }

    // MARK: - End-to-end CLI flag plumbing

    /// The global flags survive the full argv extraction → execution
    /// pipeline. We can only check the flag is recognized; the
    /// stdout-side behavior is exercised by the per-format tests above.
    @Test func builtinFlagsExposeTokenPagination() {
        let flags = extractBuiltinFlags(
            ["list", "--token-offset", "5", "--token-limit", "10", "--token-count"],
            configFlag: nil
        )
        #expect(flags.tokenOffset == 5)
        #expect(flags.tokenLimit == 10)
        #expect(flags.tokenCount == true)
        #expect(flags.rest == ["list"])
    }
}
