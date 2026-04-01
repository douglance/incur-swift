import Foundation

/// A dynamic JSON value type, equivalent to `serde_json::Value` in Rust.
///
/// This is the foundational type used throughout the incur framework for
/// passing parsed arguments, options, env vars, and command output.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(OrderedMap)

    // MARK: - Convenience constructors

    public static func from(_ value: Any?) -> JSONValue {
        guard let value else { return .null }
        switch value {
        case let b as Bool: return .bool(b)
        case let i as Int: return .int(i)
        case let d as Double: return .double(d)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.map { JSONValue.from($0) })
        case let d as [String: Any]:
            var map = OrderedMap()
            for (k, v) in d { map[k] = JSONValue.from(v) }
            return .object(map)
        default: return .string(String(describing: value))
        }
    }

    // MARK: - Accessors

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d == d.rounded(.towardZero) ? Int(d) : nil
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: OrderedMap? {
        if case .object(let m) = self { return m }
        return nil
    }

    public var isNumber: Bool {
        switch self {
        case .int, .double: return true
        default: return false
        }
    }

    public var isBoolean: Bool {
        if case .bool = self { return true }
        return false
    }

    public var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    public var isScalar: Bool {
        switch self {
        case .null, .bool, .int, .double, .string: return true
        default: return false
        }
    }

    /// Subscript for object access: `value["key"]`
    public subscript(key: String) -> JSONValue? {
        get {
            if case .object(let m) = self { return m[key] }
            return nil
        }
    }

    /// Subscript for array access: `value[0]`
    public subscript(index: Int) -> JSONValue? {
        get {
            if case .array(let a) = self, index >= 0 && index < a.count { return a[index] }
            return nil
        }
    }

    /// Returns the value as a UInt64, if it represents a non-negative integer.
    public var uint64Value: UInt64? {
        switch self {
        case .int(let i) where i >= 0: return UInt64(i)
        case .double(let d) where d >= 0 && d == d.rounded(.towardZero): return UInt64(d)
        default: return nil
        }
    }
}

// MARK: - ExpressibleBy Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var map = OrderedMap()
        for (k, v) in elements { map[k] = v }
        self = .object(map)
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode(OrderedMap.self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - CustomStringConvertible

extension JSONValue: CustomStringConvertible {
    public var description: String {
        scalarToString
    }

    /// Converts a scalar value to its display string.
    public var scalarToString: String {
        switch self {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return String(i)
        case .double(let d):
            if d == d.rounded(.towardZero) && !d.isInfinite && !d.isNaN {
                return String(Int(d))
            }
            return String(d)
        case .string(let s): return s
        case .array: return toJSON(pretty: false)
        case .object: return toJSON(pretty: false)
        }
    }
}

// MARK: - JSON Serialization

extension JSONValue {
    /// Converts to a JSON string.
    public func toJSON(pretty: Bool = true, sortedKeys: Bool = false) -> String {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = []
        if pretty { formatting.insert(.prettyPrinted) }
        if sortedKeys { formatting.insert(.sortedKeys) }
        encoder.outputFormatting = formatting
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return str
    }

    /// Parses a JSON string into a JSONValue.
    public static func parse(_ json: String) -> JSONValue? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - OrderedMap

/// An ordered dictionary that preserves insertion order, used for JSON objects.
public struct OrderedMap: Sendable, Equatable, Hashable {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public var values: [JSONValue] {
        keys.map { storage[$0]! }
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil {
                    keys.append(key)
                }
                storage[key] = newValue
            } else {
                storage[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }

    public func contains(key: String) -> Bool {
        storage[key] != nil
    }

    public mutating func merge(_ other: OrderedMap) {
        for key in other.keys {
            self[key] = other[key]
        }
    }

    public func map<T>(_ transform: (String, JSONValue) -> T) -> [T] {
        keys.map { key in transform(key, storage[key]!) }
    }

    public func filter(_ predicate: (String, JSONValue) -> Bool) -> OrderedMap {
        var result = OrderedMap()
        for key in keys {
            let value = storage[key]!
            if predicate(key, value) {
                result[key] = value
            }
        }
        return result
    }
}

// MARK: - OrderedMap Codable

extension OrderedMap: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var map = OrderedMap()
        for key in container.allKeys {
            let value = try container.decode(JSONValue.self, forKey: key)
            map[key.stringValue] = value
        }
        self = map
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for key in keys {
            let codingKey = DynamicCodingKey(stringValue: key)!
            try container.encode(storage[key]!, forKey: codingKey)
        }
    }
}

// MARK: - OrderedMap Sequence

extension OrderedMap: Sequence {
    public func makeIterator() -> IndexingIterator<[(String, JSONValue)]> {
        keys.map { ($0, storage[$0]!) }.makeIterator()
    }
}

// MARK: - OrderedMap Literals

extension OrderedMap: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init()
        for (k, v) in elements { self[k] = v }
    }
}

// MARK: - Dynamic Coding Key

struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
