import Foundation

/// Free-form evaluation context.
///
/// Keys are the unit key (configured per project) plus any additional fields
/// needed for targeting conditions or contextual model scoring.
public typealias TrafficalContext = [String: TrafficalContextValue]

/// A single context field value.
///
/// We mirror `TrafficalJSON` shape so context values can flow into condition
/// operands and contextual model features without lossy conversion.
public indirect enum TrafficalContextValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([TrafficalContextValue])
    case object([String: TrafficalContextValue])

    /// Best-effort string projection used by condition operators that expect a
    /// string (`contains`, `startsWith`, `endsWith`, `regex`).
    public var stringProjection: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if n.rounded() == n { return String(Int64(n)) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /// Best-effort numeric projection used by `gt` / `gte` / `lt` / `lte`.
    public var numberProjection: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }

    /// Whether the value should count as "missing" for `exists`/`notExists`.
    public var isMissing: Bool { if case .null = self { return true } else { return false } }

    /// Converts from a JSON value.
    public static func from(any value: Any?) -> TrafficalContextValue {
        guard let value = value else { return .null }
        if value is NSNull { return .null }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = value as? String { return .string(s) }
        if let arr = value as? [Any] { return .array(arr.map { TrafficalContextValue.from(any: $0) }) }
        if let dict = value as? [String: Any] {
            var out: [String: TrafficalContextValue] = [:]
            for (k, v) in dict { out[k] = TrafficalContextValue.from(any: v) }
            return .object(out)
        }
        return .null
    }

    /// Round-trip back to `Any` for JSON encoding.
    public var asAny: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let arr): return arr.map(\.asAny)
        case .object(let obj):
            var out: [String: Any] = [:]
            for (k, v) in obj { out[k] = v.asAny }
            return out
        }
    }
}

extension TrafficalContextValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension TrafficalContextValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension TrafficalContextValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension TrafficalContextValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
