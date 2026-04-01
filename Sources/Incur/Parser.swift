/// Argv and environment variable parser for the incur framework.
///
/// Ported from `parser.rs`. Takes raw argv tokens and parses them against
/// `FieldMeta` metadata, producing a `ParseResult` with coerced values.

/// Options controlling how `parse` interprets argv tokens.
public struct ParseOptions: Sendable {
    /// Field metadata for positional args (order matters).
    public let argsFields: [FieldMeta]
    /// Field metadata for named options.
    public let optionsFields: [FieldMeta]
    /// Map of option names (snake_case) to single-char aliases.
    public let aliases: [String: Character]
    /// Config-backed default values, merged under argv.
    public let defaults: OrderedMap?

    public init(
        argsFields: [FieldMeta] = [],
        optionsFields: [FieldMeta] = [],
        aliases: [String: Character] = [:],
        defaults: OrderedMap? = nil
    ) {
        self.argsFields = argsFields
        self.optionsFields = optionsFields
        self.aliases = aliases
        self.defaults = defaults
    }
}

/// The result of parsing argv tokens.
public struct ParseResult: Sendable {
    /// Parsed positional arguments.
    public var args: OrderedMap
    /// Parsed named options.
    public var options: OrderedMap

    public init(args: OrderedMap = OrderedMap(), options: OrderedMap = OrderedMap()) {
        self.args = args
        self.options = options
    }
}

// MARK: - Internal lookup tables

/// Pre-computed lookup tables for fast option resolution.
private struct OptionNames {
    var known: Set<String> = []
    var kebabToSnake: [String: String] = [:]
    var aliasToName: [Character: String] = [:]
    var fieldTypes: [String: FieldType] = [:]

    static func build(fields: [FieldMeta], aliases: [String: Character]) -> OptionNames {
        var names = OptionNames()
        for field in fields {
            let snake = field.name
            names.known.insert(snake)
            names.fieldTypes[snake] = field.fieldType

            let kebab = toKebab(snake)
            if kebab != snake {
                names.kebabToSnake[kebab] = snake
            }

            if let alias = field.alias {
                names.aliasToName[alias] = snake
            }
        }
        // Explicit aliases override field-level aliases.
        for (name, ch) in aliases {
            names.aliasToName[ch] = name
        }
        return names
    }

    /// Resolve a raw long-option name (kebab or snake) to its canonical snake_case name.
    func normalize(_ raw: String) -> String? {
        let name = kebabToSnake[raw] ?? toSnake(raw)
        return known.contains(name) ? name : nil
    }

    func isBoolean(_ name: String) -> Bool {
        fieldTypes[name] == .boolean
    }

    func isCount(_ name: String) -> Bool {
        fieldTypes[name] == .count
    }

    func isArray(_ name: String) -> Bool {
        if case .array = fieldTypes[name] { return true }
        return false
    }
}

// MARK: - Helpers

/// Sets an option value, collecting into arrays for array-typed fields.
private func setOption(_ raw: inout OrderedMap, name: String, value: String, names: OptionNames) {
    if names.isArray(name) {
        if var existing = raw[name]?.arrayValue {
            existing.append(.string(value))
            raw[name] = .array(existing)
        } else {
            raw[name] = .array([.string(value)])
        }
    } else {
        raw[name] = .string(value)
    }
}

/// Coerces a `JSONValue` to match the expected `FieldType`.
private func coerce(_ value: JSONValue, fieldType: FieldType) throws -> JSONValue {
    switch fieldType {
    case .number:
        if case .string(let s) = value, let d = Double(s) {
            if d == d.rounded(.towardZero) && !d.isInfinite && !d.isNaN, let i = Int(exactly: d) {
                return .int(i)
            }
            return .double(d)
        }
        return value
    case .boolean:
        if case .string(let s) = value {
            return .bool(s == "true" || s == "1")
        }
        return value
    case .array(let inner):
        if case .array(let arr) = value {
            return .array(try arr.map { try coerce($0, fieldType: inner) })
        }
        return value
    case .enum(let variants):
        if case .string(let s) = value {
            guard variants.contains(s) else {
                throw ParseError(message: "Invalid value \"\(s)\". Expected one of: \(variants.joined(separator: ", "))")
            }
        }
        return value
    default:
        return value
    }
}

// MARK: - Public API

/// Parses raw argv tokens against schema metadata.
///
/// Supports:
/// - `--key value` and `--key=value` long options
/// - `--no-flag` boolean negation
/// - `-f value` short aliases
/// - `-abc` stacked short aliases (all but last must be boolean/count)
/// - `-vvv` count flag incrementing
/// - `--tag x --tag y` array collection
/// - Positional arguments assigned to `argsFields` in order
/// - Coercion from strings to numbers/booleans based on field type
public func parse(argv: [String], options: ParseOptions) throws -> ParseResult {
    let names = OptionNames.build(fields: options.optionsFields, aliases: options.aliases)

    var positionals: [String] = []
    var rawOptions = OrderedMap()

    var i = 0
    while i < argv.count {
        let token = argv[i]

        if token.hasPrefix("--no-") && token.count > 5 {
            // --no-flag negation
            let rawName = String(token.dropFirst(5))
            guard let name = names.normalize(rawName) else {
                throw ParseError(message: "Unknown flag: \(token)")
            }
            rawOptions[name] = .bool(false)
            i += 1
        } else if token.hasPrefix("--") {
            let rest = String(token.dropFirst(2))
            if let eqIdx = rest.firstIndex(of: "=") {
                // --flag=value
                let rawName = String(rest[rest.startIndex..<eqIdx])
                guard let name = names.normalize(rawName) else {
                    throw ParseError(message: "Unknown flag: --\(rawName)")
                }
                let val = String(rest[rest.index(after: eqIdx)...])
                setOption(&rawOptions, name: name, value: val, names: names)
                i += 1
            } else {
                // --flag [value]
                guard let name = names.normalize(rest) else {
                    throw ParseError(message: "Unknown flag: \(token)")
                }
                if names.isCount(name) {
                    let prev = rawOptions[name]?.intValue ?? 0
                    rawOptions[name] = .int(prev + 1)
                    i += 1
                } else if names.isBoolean(name) {
                    rawOptions[name] = .bool(true)
                    i += 1
                } else {
                    guard i + 1 < argv.count else {
                        throw ParseError(message: "Missing value for flag: \(token)")
                    }
                    let value = argv[i + 1]
                    setOption(&rawOptions, name: name, value: value, names: names)
                    i += 2
                }
            }
        } else if token.hasPrefix("-") && !token.hasPrefix("--") && token.count >= 2 {
            // -f or -abc (stacked short aliases)
            let chars = Array(token.dropFirst())
            for (j, ch) in chars.enumerated() {
                guard let name = names.aliasToName[ch] else {
                    throw ParseError(message: "Unknown flag: -\(ch)")
                }
                let isLast = j == chars.count - 1

                if !isLast {
                    // Non-last chars must be boolean or count
                    if names.isCount(name) {
                        let prev = rawOptions[name]?.intValue ?? 0
                        rawOptions[name] = .int(prev + 1)
                    } else if names.isBoolean(name) {
                        rawOptions[name] = .bool(true)
                    } else {
                        throw ParseError(message: "Non-boolean flag -\(ch) must be last in a stacked alias")
                    }
                } else if names.isCount(name) {
                    let prev = rawOptions[name]?.intValue ?? 0
                    rawOptions[name] = .int(prev + 1)
                } else if names.isBoolean(name) {
                    rawOptions[name] = .bool(true)
                } else {
                    guard i + 1 < argv.count else {
                        throw ParseError(message: "Missing value for flag: -\(ch)")
                    }
                    let value = argv[i + 1]
                    setOption(&rawOptions, name: name, value: value, names: names)
                    i += 1
                }
            }
            i += 1
        } else {
            positionals.append(token)
            i += 1
        }
    }

    // Assign positionals to args fields in order.
    var args = OrderedMap()
    for (idx, field) in options.argsFields.enumerated() {
        if idx < positionals.count {
            args[field.name] = .string(positionals[idx])
        }
    }

    // Coerce raw option values to match field types.
    for field in options.optionsFields {
        if let val = rawOptions[field.name] {
            rawOptions[field.name] = try coerce(val, fieldType: field.fieldType)
        }
    }

    // Merge defaults (defaults < argv — argv wins).
    if let defaults = options.defaults {
        for (key, defaultVal) in defaults {
            let normalised = toSnake(key)

            guard let field = options.optionsFields.first(where: { $0.name == normalised }) else {
                throw ParseError(message: "Unknown config option: \(key)")
            }

            if !rawOptions.contains(key: normalised) {
                // Validate type compatibility
                let valid: Bool
                switch field.fieldType {
                case .number: valid = defaultVal.isNumber || defaultVal.isNull
                case .boolean: valid = defaultVal.isBoolean || defaultVal.isNull
                case .array: valid = defaultVal.isArray || defaultVal.isNull
                default: valid = true
                }
                guard valid else {
                    throw ParseError(message: "Invalid config default for \"\(key)\": expected \(field.fieldType.displayName), got \(defaultVal)")
                }
                rawOptions[normalised] = defaultVal
            }
        }
    }

    // Merge field-level defaults for fields not yet set.
    for field in options.optionsFields {
        if !rawOptions.contains(key: field.name), let defaultVal = field.defaultValue {
            rawOptions[field.name] = defaultVal
        }
    }

    // Coerce args too.
    for field in options.argsFields {
        if let val = args[field.name] {
            args[field.name] = try coerce(val, fieldType: field.fieldType)
        }
    }

    return ParseResult(args: args, options: rawOptions)
}

/// Parses environment variables against field metadata.
public func parseEnv(fields: [FieldMeta], source: [String: String]) -> OrderedMap {
    var result = OrderedMap()

    for field in fields {
        let envKey = field.envName ?? field.name.uppercased()

        if let raw = source[envKey] {
            let value = coerceEnv(raw, fieldType: field.fieldType)
            result[field.name] = value
        }
    }

    return result
}

/// Coerces a raw env-var string to the expected field type.
private func coerceEnv(_ value: String, fieldType: FieldType) -> JSONValue {
    switch fieldType {
    case .number:
        if let d = Double(value) {
            if d == d.rounded(.towardZero) && !d.isInfinite && !d.isNaN, let i = Int(exactly: d) {
                return .int(i)
            }
            return .double(d)
        }
        return .string(value)
    case .boolean:
        return .bool(value == "true" || value == "1")
    default:
        return .string(value)
    }
}
