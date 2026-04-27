/// Pager helpers for human-facing CLI output.
///
/// Ported from `pager.rs`.

import Foundation

// MARK: - Token Estimation
//
// Heuristic tokenizer ported from the `tokenx` npm package (v1.3.0).
// Used by the `--token-count`, `--token-limit`, and `--token-offset`
// global flags to bound the token budget of an LLM agent. Aims for
// rough parity with OpenAI's tiktoken (the upstream claims ~96%).

private let defaultCharsPerToken = 6
private let shortTokenThreshold = 3

private struct LanguageConfig {
    let pattern: NSRegularExpression
    let averageCharsPerToken: Double
}

private let defaultLanguageConfigs: [LanguageConfig] = {
    let patterns: [(String, Double)] = [
        ("[äöüßẞ]", 3),
        ("[éèêëàâîïôûùüÿçœæáíóúñ]", 3),
        ("[ąćęłńóśźżěščřžýůúďťň]", 3.5),
    ]
    return patterns.compactMap { (p, charsPerToken) -> LanguageConfig? in
        guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { return nil }
        return LanguageConfig(pattern: re, averageCharsPerToken: charsPerToken)
    }
}()

private let whitespaceRegex = try! NSRegularExpression(pattern: "^\\s+$")
// NSRegularExpression uses ICU regex syntax: \uXXXX takes exactly 4 hex digits.
private let cjkRegex = try! NSRegularExpression(
    pattern: "[\\u4E00-\\u9FFF\\u3400-\\u4DBF\\u3000-\\u303F\\uFF00-\\uFFEF\\u30A0-\\u30FF\\u2E80-\\u2EFF\\u31C0-\\u31EF\\u3200-\\u32FF\\u3300-\\u33FF\\uAC00-\\uD7AF\\u1100-\\u11FF\\u3130-\\u318F\\uA960-\\uA97F\\uD7B0-\\uD7FF]"
)
private let numericRegex = try! NSRegularExpression(pattern: "^\\d+(?:[.,]\\d+)*$")
private let punctuationRegex = try! NSRegularExpression(
    pattern: "[.,!?;(){}\\[\\]<>:/\\\\|@#$%\\^&*+=`~_-]"
)
private let alphanumericRegex = try! NSRegularExpression(
    pattern: "^[a-zA-Z0-9\\u00C0-\\u00D6\\u00D8-\\u00F6\\u00F8-\\u00FF]+$"
)

/// Splits text into segments matching the JS `text.split(TOKEN_SPLIT_PATTERN).filter(Boolean)`
/// behavior — splits on runs of whitespace OR runs of punctuation, and keeps the separators.
private func splitIntoSegments(_ text: String) -> [String] {
    if text.isEmpty { return [] }
    var segments: [String] = []
    var buffer = ""
    var bufferKind: SegmentKind = .other

    enum SegmentKind { case whitespace, punctuation, other }

    func kind(of scalar: Character) -> SegmentKind {
        if scalar.isWhitespace || scalar.isNewline { return .whitespace }
        if isPunctuation(scalar) { return .punctuation }
        return .other
    }

    func flush() {
        if !buffer.isEmpty {
            segments.append(buffer)
            buffer.removeAll(keepingCapacity: true)
        }
    }

    for ch in text {
        let k = kind(of: ch)
        if buffer.isEmpty {
            buffer.append(ch)
            bufferKind = k
            continue
        }
        // Whitespace and punctuation runs stay grouped; switching kinds, or
        // either kind beginning/ending, flushes the current buffer.
        if k == bufferKind && (k == .whitespace || k == .punctuation) {
            buffer.append(ch)
        } else if k == .other && bufferKind == .other {
            buffer.append(ch)
        } else {
            flush()
            buffer.append(ch)
            bufferKind = k
        }
    }
    flush()
    return segments
}

private func isPunctuation(_ ch: Character) -> Bool {
    let punct: Set<Character> = [".", ",", "!", "?", ";", "(", ")", "{", "}", "[", "]", "<", ">", ":", "/", "\\", "|", "@", "#", "$", "%", "^", "&", "*", "+", "=", "`", "~", "_", "-"]
    return punct.contains(ch)
}

private func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.firstMatch(in: text, options: [], range: range) != nil
}

private func languageCharsPerToken(for segment: String) -> Double? {
    for cfg in defaultLanguageConfigs where matches(cfg.pattern, segment) {
        return cfg.averageCharsPerToken
    }
    return nil
}

private func estimateSegmentTokens(_ segment: String) -> Int {
    if matches(whitespaceRegex, segment) { return 0 }
    if matches(cjkRegex, segment) { return segment.unicodeScalars.count }
    if matches(numericRegex, segment) { return 1 }
    if segment.count <= shortTokenThreshold { return 1 }
    if matches(punctuationRegex, segment) {
        return segment.count > 1 ? Int((Double(segment.count) / 2).rounded(.up)) : 1
    }
    let charsPerToken = languageCharsPerToken(for: segment) ?? Double(defaultCharsPerToken)
    return Int((Double(segment.count) / charsPerToken).rounded(.up))
}

/// Estimates the token count of `text` using the `tokenx` heuristic.
///
/// Matches `estimateTokenCount` from the JS `tokenx` package.
public func estimateTokenCount(_ text: String) -> Int {
    if text.isEmpty { return 0 }
    return splitIntoSegments(text).reduce(0) { $0 + estimateSegmentTokens($1) }
}

/// Returns a substring of `text` corresponding to tokens `[start, end)`.
///
/// Mirrors `sliceByTokens` from the JS `tokenx` package. Negative indices
/// count from the end. `end == nil` means "to the end".
public func sliceByTokens(_ text: String, start: Int = 0, end: Int? = nil) -> String {
    if text.isEmpty { return "" }
    var totalTokens = 0
    if start < 0 || (end != nil && end! < 0) {
        totalTokens = estimateTokenCount(text)
    }
    let normalizedStart = start < 0 ? max(0, totalTokens + start) : max(0, start)
    let normalizedEnd: Int
    if let end {
        normalizedEnd = end < 0 ? max(0, totalTokens + end) : end
    } else {
        normalizedEnd = Int.max
    }
    if normalizedStart >= normalizedEnd { return "" }

    let segments = splitIntoSegments(text)
    var parts: [String] = []
    var currentTokenPos = 0
    for segment in segments {
        if currentTokenPos >= normalizedEnd { break }
        let segTokens = estimateSegmentTokens(segment)
        let extracted = extractSegmentPart(
            segment: segment,
            segmentTokenStart: currentTokenPos,
            segmentTokenCount: segTokens,
            targetStart: normalizedStart,
            targetEnd: normalizedEnd
        )
        if !extracted.isEmpty {
            parts.append(extracted)
        }
        currentTokenPos += segTokens
    }
    return parts.joined()
}

private func extractSegmentPart(
    segment: String,
    segmentTokenStart: Int,
    segmentTokenCount: Int,
    targetStart: Int,
    targetEnd: Int
) -> String {
    if segmentTokenCount == 0 {
        return (segmentTokenStart >= targetStart && segmentTokenStart < targetEnd) ? segment : ""
    }
    let segmentTokenEnd = segmentTokenStart + segmentTokenCount
    if segmentTokenStart >= targetEnd || segmentTokenEnd <= targetStart { return "" }
    let overlapStart = max(0, targetStart - segmentTokenStart)
    let overlapEnd = min(segmentTokenCount, targetEnd - segmentTokenStart)
    if overlapStart == 0 && overlapEnd == segmentTokenCount { return segment }
    let charCount = segment.count
    let charStart = Int(floor(Double(overlapStart) / Double(segmentTokenCount) * Double(charCount)))
    let charEnd = Int((Double(overlapEnd) / Double(segmentTokenCount) * Double(charCount)).rounded(.up))
    let safeStart = max(0, min(charStart, charCount))
    let safeEnd = max(safeStart, min(charEnd, charCount))
    let startIdx = segment.index(segment.startIndex, offsetBy: safeStart)
    let endIdx = segment.index(segment.startIndex, offsetBy: safeEnd)
    return String(segment[startIdx..<endIdx])
}

/// Returns `true` when stdout is interactive and paging makes sense.
public func stdoutIsInteractive() -> Bool {
    #if canImport(Darwin)
    return isatty(fileno(stdout)) != 0
    #elseif canImport(Glibc)
    return isatty(fileno(stdout)) != 0
    #else
    return false
    #endif
}

/// Attempts to write `output` to the configured pager.
///
/// Respects `$PAGER` when set, otherwise falls back to `less -FRX`.
/// Returns `true` when a pager was successfully started and completed,
/// `false` when no pager could be launched.
///
/// Available on macOS and Linux only. Foundation's `Process` is not exposed on
/// iOS/tvOS/watchOS/visionOS, so this function is a no-op on those platforms
/// and always returns `false`.
public func pageOutput(_ output: String) -> Bool {
    #if os(macOS) || os(Linux)
    let pagerEnv = ProcessInfo.processInfo.environment["PAGER"]
    let hasPagerEnv = pagerEnv != nil && !pagerEnv!.trimmingCharacters(in: .whitespaces).isEmpty

    let process = Process()

    if hasPagerEnv {
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", pagerEnv!]
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/less")
        process.arguments = ["-FRX"]
    }

    let pipe = Pipe()
    process.standardInput = pipe

    do {
        try process.run()
    } catch {
        return false
    }

    let data = output.data(using: .utf8) ?? Data()
    // Write to pipe and close; ignore broken pipe errors
    do {
        try pipe.fileHandleForWriting.write(contentsOf: data)
    } catch {
        // Broken pipe is expected if pager exits early
    }
    pipe.fileHandleForWriting.closeFile()

    process.waitUntilExit()
    return process.terminationStatus == 0
    #else
    _ = output
    return false
    #endif
}
