import Foundation

/// Any JSON value. Ops and documents keep fields they don't know as-is, so
/// files survive a round trip through apps that are older or newer.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// JavaScript truthiness.
    public var isTruthy: Bool {
        switch self {
        case .null: false
        case .bool(let b): b
        case .number(let n): n != 0 && !n.isNaN
        case .string(let s): !s.isEmpty
        case .array, .object: true
        }
    }

    /// JavaScript `Number(v)`; nil when the result isn't finite.
    public var jsNumber: Double? {
        let n: Double
        switch self {
        case .null: n = 0
        case .bool(let b): n = b ? 1 : 0
        case .number(let x): n = x
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            n = t.isEmpty ? 0 : (Double(t) ?? .nan)
        case .array(let a):
            if a.isEmpty { n = 0 } else if a.count == 1 { return a[0].jsNumber } else { return nil }
        case .object: return nil
        }
        return n.isFinite ? n : nil
    }

    public subscript(key: String) -> JSONValue? {
        object?[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard let a = array, index >= 0, index < a.count else { return nil }
        return a[index]
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n.isFinite ? n : 0)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
}

extension JSONValue {
    public init(_ n: Double) { self = .number(n) }
    public init(_ n: Int) { self = .number(Double(n)) }

    /// Canonical, compact JSON (sorted keys) — the cache and file form.
    public func jsonData(pretty: Bool = false) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(self)) ?? Data("null".utf8)
    }

    public var jsonString: String { String(decoding: jsonData(), as: UTF8.self) }

    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public static func parse(_ string: String) throws -> JSONValue {
        try parse(Data(string.utf8))
    }
}