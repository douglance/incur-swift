/// Output formatting for the incur framework.
///
/// Serializes a `JSONValue` to a string in the requested `Format`.
///
/// Ported from `formatter.rs`.

/// Serializes a value to the specified format.
public func formatValue(_ value: JSONValue, format: Format) -> String {
    switch format {
    case .json: return formatJSON(value)
    case .jsonl: return formatJSONL(value)
    case .yaml: return formatJSON(value) // YAML not yet implemented; fallback to JSON
    case .markdown: return formatMarkdown(value, path: [])
    case .toon: return formatToon(value)
    case .table: return formatTable(value)
    case .csv: return formatCSV(value)
    }
}

// MARK: - JSON

private func formatJSON(_ value: JSONValue) -> String {
    value.toJSON(pretty: true)
}

// MARK: - JSONL

private func formatJSONL(_ value: JSONValue) -> String {
    if case .array(let arr) = value {
        return arr.map { $0.toJSON(pretty: false) }.joined(separator: "\n")
    }
    return value.toJSON(pretty: false)
}

// MARK: - Toon

private func formatToon(_ value: JSONValue) -> String {
    if value.isScalar {
        return value.scalarToString
    }
    // Fallback to JSON for complex types
    return formatJSON(value)
}

// MARK: - Markdown

private func formatMarkdown(_ value: JSONValue, path: [String]) -> String {
    if value.isScalar {
        if path.isEmpty { return value.scalarToString }
        return "## \(path.joined(separator: "."))\n\n\(value.scalarToString)"
    }

    if case .array(let arr) = value {
        if isArrayOfObjects(value) {
            let tbl = columnarTable(arr)
            if path.isEmpty { return tbl }
            return "## \(path.joined(separator: "."))\n\n\(tbl)"
        }
        let s = arr.map(\.scalarToString).joined(separator: ", ")
        return formatMarkdown(.string(s), path: path)
    }

    if case .object(let obj) = value {
        if path.isEmpty && isFlat(obj) {
            return kvTable(obj)
        }

        let entries = obj.map { ($0, $1) }
        let needsHeadings = !path.isEmpty || entries.count > 1 || entries.contains { !$1.isScalar }

        if needsHeadings {
            let sections: [String] = entries.map { key, val in
                var childPath = path
                childPath.append(key)

                if val.isScalar {
                    return "## \(childPath.joined(separator: "."))\n\n\(val.scalarToString)"
                } else if isArrayOfObjects(val) {
                    let arr = val.arrayValue!
                    return "## \(childPath.joined(separator: "."))\n\n\(columnarTable(arr))"
                } else if case .object(let nested) = val {
                    if isFlat(nested) {
                        return "## \(childPath.joined(separator: "."))\n\n\(kvTable(nested))"
                    }
                    return formatMarkdown(val, path: childPath)
                }
                return "## \(childPath.joined(separator: "."))\n\n\(val.scalarToString)"
            }
            return sections.joined(separator: "\n\n")
        }

        return kvTable(obj)
    }

    return ""
}

// MARK: - Table

private func formatTable(_ value: JSONValue) -> String {
    if value.isScalar { return value.scalarToString }

    if case .array(let arr) = value {
        if arr.isEmpty { return "(empty)" }
        if isArrayOfObjects(value) {
            return asciiTableFromArray(arr)
        }
        return arr.map(\.scalarToString).joined(separator: "\n")
    }

    if case .object(let obj) = value {
        return asciiKVTable(obj)
    }

    return ""
}

// MARK: - CSV

private func formatCSV(_ value: JSONValue) -> String {
    if value.isScalar { return csvEscape(value.scalarToString) }

    if case .array(let arr) = value {
        if arr.isEmpty { return "" }
        if isArrayOfObjects(value) {
            return csvFromArray(arr)
        }
        return arr.map { csvEscape($0.scalarToString) }.joined(separator: "\n")
    }

    if case .object(let obj) = value {
        let keys = obj.keys
        let header = keys.map { csvEscape($0) }.joined(separator: ",")
        let row = keys.map { csvEscape(valueToCellString(obj[$0] ?? .null)) }.joined(separator: ",")
        return "\(header)\n\(row)"
    }

    return ""
}

// MARK: - Shared Helpers

private func isFlat(_ obj: OrderedMap) -> Bool {
    obj.values.allSatisfy(\.isScalar)
}

private func isArrayOfObjects(_ value: JSONValue) -> Bool {
    guard case .array(let arr) = value, !arr.isEmpty else { return false }
    return arr.allSatisfy(\.isObject)
}

private func valueToCellString(_ value: JSONValue) -> String {
    switch value {
    case .null: return ""
    case .bool(let b): return b ? "true" : "false"
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .string(let s): return s
    case .array(let arr): return arr.map { valueToCellString($0) }.joined(separator: ", ")
    case .object: return value.toJSON(pretty: false)
    }
}

// MARK: - Markdown Tables

private func markdownTable(headers: [String], rows: [[String]]) -> String {
    let widths = headers.enumerated().map { i, h in
        max(h.count, rows.map { $0.count > i ? $0[i].count : 0 }.max() ?? 0)
    }

    let pad = { (s: String, i: Int) -> String in
        s.padding(toLength: widths[i], withPad: " ", startingAt: 0)
    }

    let headerRow = "| " + headers.enumerated().map { pad($1, $0) }.joined(separator: " | ") + " |"
    let sep = "|" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "|") + "|"

    let body = rows.map { row in
        let cells = headers.enumerated().map { i, _ in
            pad(row.count > i ? row[i] : "", i)
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    return ([headerRow, sep] + body).joined(separator: "\n")
}

private func kvTable(_ obj: OrderedMap) -> String {
    let headers = ["Key", "Value"]
    let rows = obj.map { [$0, $1.scalarToString] }
    return markdownTable(headers: headers, rows: rows)
}

private func columnarTable(_ items: [JSONValue]) -> String {
    var keys: [String] = []
    var seen = Set<String>()
    for item in items {
        if case .object(let map) = item {
            for key in map.keys {
                if seen.insert(key).inserted {
                    keys.append(key)
                }
            }
        }
    }

    let rows: [[String]] = items.map { item in
        keys.map { k in
            item[k].map(\.scalarToString) ?? ""
        }
    }

    return markdownTable(headers: keys, rows: rows)
}

// MARK: - ASCII Tables

private func asciiTable(headers: [String], rows: [[String]]) -> String {
    let widths = headers.enumerated().map { i, h in
        max(h.count, rows.map { $0.count > i ? $0[i].count : 0 }.max() ?? 0)
    }

    let pad = { (s: String, i: Int) -> String in
        s.padding(toLength: widths[i], withPad: " ", startingAt: 0)
    }

    let sepLine = "+-" + widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-") + "-+"
    let headerRow = "| " + headers.enumerated().map { pad($1, $0) }.joined(separator: " | ") + " |"

    let dataRows = rows.map { row in
        let cells = headers.enumerated().map { i, _ in
            pad(row.count > i ? row[i] : "", i)
        }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    return ([sepLine, headerRow, sepLine] + dataRows + [sepLine]).joined(separator: "\n")
}

private func asciiTableFromArray(_ items: [JSONValue]) -> String {
    var keys: [String] = []
    var seen = Set<String>()
    for item in items {
        if case .object(let map) = item {
            for key in map.keys {
                if seen.insert(key).inserted { keys.append(key) }
            }
        }
    }

    let rows: [[String]] = items.map { item in
        keys.map { k in
            item[k].map { valueToCellString($0) } ?? ""
        }
    }

    return asciiTable(headers: keys, rows: rows)
}

private func asciiKVTable(_ obj: OrderedMap) -> String {
    let headers = ["Key", "Value"]
    let rows = obj.map { [$0, valueToCellString($1)] }
    return asciiTable(headers: headers, rows: rows)
}

// MARK: - CSV Helpers

private func csvEscape(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") {
        return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return s
}

private func csvFromArray(_ items: [JSONValue]) -> String {
    var keys: [String] = []
    var seen = Set<String>()
    for item in items {
        if case .object(let map) = item {
            for key in map.keys {
                if seen.insert(key).inserted { keys.append(key) }
            }
        }
    }

    let header = keys.map { csvEscape($0) }.joined(separator: ",")

    let rows: [String] = items.map { item in
        keys.map { k in
            csvEscape(item[k].map { valueToCellString($0) } ?? "")
        }.joined(separator: ",")
    }

    return ([header] + rows).joined(separator: "\n")
}
