/// Filter expressions for selecting and slicing output data.
///
/// Ported from `filter.rs`. Parses dot-separated key paths with optional
/// array slices and applies them to `JSONValue` trees.

/// A single segment in a filter path.
public enum FilterSegment: Sendable, Equatable {
    /// A named key to descend into an object.
    case key(String)
    /// An array slice `[start, end)`.
    case slice(start: Int, end: Int)
}

/// A filter path is an ordered list of segments to traverse.
public typealias FilterPath = [FilterSegment]

/// Parses a filter expression string into structured filter paths.
public func parseFilterExpression(_ expression: String) -> [FilterPath] {
    let tokens = splitTopLevelCommas(expression)
    return tokens.map { parseToken($0) }
}

/// Applies parsed filter paths to data, returning a filtered copy.
public func applyFilter(data: JSONValue, paths: [FilterPath]) -> JSONValue {
    if paths.isEmpty { return data }

    // Special case: single key selecting a scalar
    if paths.count == 1 && paths[0].count == 1 {
        if case .key(let key) = paths[0][0] {
            if case .array(let arr) = data {
                return .array(arr.map { applyFilter(data: $0, paths: paths) })
            }
            if case .object(let obj) = data {
                if let val = obj[key] {
                    if val.isScalar { return val }
                    var result = OrderedMap()
                    result[key] = val
                    return .object(result)
                }
            }
            return .null
        }
    }

    if case .array(let arr) = data {
        return .array(arr.map { applyFilter(data: $0, paths: paths) })
    }

    var result = OrderedMap()
    for path in paths {
        mergeFilter(&result, data: data, segments: path, index: 0)
    }
    return .object(result)
}

// MARK: - Internals

private func splitTopLevelCommas(_ expression: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var depth = 0

    for ch in expression {
        switch ch {
        case "[":
            depth += 1
            current.append(ch)
        case "]":
            depth -= 1
            current.append(ch)
        case "," where depth == 0:
            if !current.isEmpty { tokens.append(current) }
            current = ""
        default:
            current.append(ch)
        }
    }
    if !current.isEmpty { tokens.append(current) }
    return tokens
}

private func parseToken(_ token: String) -> FilterPath {
    var path: FilterPath = []
    var remaining = token[token.startIndex...]

    while !remaining.isEmpty {
        if let bracketIdx = remaining.firstIndex(of: "[") {
            // Parse dot-separated keys before the bracket
            let before = remaining[remaining.startIndex..<bracketIdx]
            for part in before.split(separator: ".") where !part.isEmpty {
                path.append(.key(String(part)))
            }

            // Parse the slice [start,end]
            let afterBracket = remaining[bracketIdx...]
            let closeBracket = afterBracket.firstIndex(of: "]") ?? remaining.endIndex
            let inner = remaining[remaining.index(after: bracketIdx)..<closeBracket]
            let parts = inner.split(separator: ",")
            if parts.count == 2 {
                let start = Int(parts[0]) ?? 0
                let end = Int(parts[1]) ?? 0
                path.append(.slice(start: start, end: end))
            } else if parts.count == 1 {
                let idx = Int(parts[0]) ?? 0
                path.append(.slice(start: idx, end: idx + 1))
            }

            if closeBracket < remaining.endIndex {
                let nextIdx = remaining.index(after: closeBracket)
                if nextIdx < remaining.endIndex {
                    let rest = remaining[nextIdx...]
                    remaining = rest.hasPrefix(".") ? rest.dropFirst() : rest
                } else {
                    remaining = remaining[remaining.endIndex...]
                }
            } else {
                remaining = remaining[remaining.endIndex...]
            }
        } else {
            for part in remaining.split(separator: ".") where !part.isEmpty {
                path.append(.key(String(part)))
            }
            break
        }
    }

    return path
}

private func mergeFilter(
    _ target: inout OrderedMap,
    data: JSONValue,
    segments: [FilterSegment],
    index: Int
) {
    guard index < segments.count else { return }
    guard case .object(let obj) = data else { return }

    switch segments[index] {
    case .key(let key):
        guard let val = obj[key] else { return }

        // Last segment — copy the value
        if index + 1 >= segments.count {
            target[key] = val
            return
        }

        // Peek at next segment
        if case .slice(let start, let end) = segments[index + 1] {
            if case .array(let arr) = val {
                let sliced = Array(arr.dropFirst(start).prefix(end - start))

                if index + 2 >= segments.count {
                    target[key] = .array(sliced)
                } else {
                    let mapped: [JSONValue] = sliced.map { item in
                        var sub = OrderedMap()
                        mergeFilter(&sub, data: item, segments: segments, index: index + 2)
                        return .object(sub)
                    }
                    target[key] = .array(mapped)
                }
            }
            return
        }

        // Next segment is a key — recurse
        if case .object = val {
            var nested: OrderedMap
            if case .object(let existing) = target[key] {
                nested = existing
            } else {
                nested = OrderedMap()
            }
            mergeFilter(&nested, data: val, segments: segments, index: index + 1)
            target[key] = .object(nested)
        }

    case .slice:
        // Slice at root level — shouldn't happen
        break
    }
}
