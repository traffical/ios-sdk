import Foundation

/// A typed runtime value for a parameter.
///
/// The spec allows parameters of type `string`, `number`, `boolean`, or `json`.
/// `JSON` is represented as a wrapped `Any` so we can carry arbitrary
/// dictionaries and arrays through the resolution engine without losing
/// structure, while still being `Sendable` for Swift Concurrency.
public enum TrafficalParameterValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case json(TrafficalJSON)

    /// The canonical type name for spec compatibility.
    public var typeName: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .bool: return "boolean"
        case .json: return "json"
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var jsonValue: TrafficalJSON? { if case .json(let j) = self { return j } else { return nil } }
}

/// A JSON value carried inside parameter values, context, condition operands,
/// and event payloads.
///
/// Modeled as a recursive enum so it stays `Sendable` and `Equatable` — using
/// `Any` would force us to drop both guarantees and would make the engine
/// difficult to test deterministically.
public indirect enum TrafficalJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([TrafficalJSON])
    case object([String: TrafficalJSON])
}

// MARK: - Decoding helpers used across the codebase.

extension TrafficalJSON {
    /// Decodes a JSON value from `Any` produced by `JSONSerialization`.
    public static func from(any value: Any) -> TrafficalJSON {
        if value is NSNull { return .null }
        if let b = value as? Bool, isStrictBool(value) { return .bool(b) }
        if let n = value as? NSNumber {
            // `NSNumber` carries both bool and numeric values. Distinguish by
            // CFNumber type to avoid `1` becoming `true`.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let s = value as? String { return .string(s) }
        if let arr = value as? [Any] { return .array(arr.map(TrafficalJSON.from(any:))) }
        if let dict = value as? [String: Any] {
            var out: [String: TrafficalJSON] = [:]
            for (k, v) in dict { out[k] = TrafficalJSON.from(any: v) }
            return .object(out)
        }
        return .null
    }

    /// Converts back to a JSON-serialisable `Any`.
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

    /// Convenience accessors for typed reads.
    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [TrafficalJSON]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: TrafficalJSON]? { if case .object(let o) = self { return o } else { return nil } }
}

private func isStrictBool(_ value: Any) -> Bool {
    guard let n = value as? NSNumber else { return false }
    return CFGetTypeID(n) == CFBooleanGetTypeID()
}

extension TrafficalParameterValue {
    /// Converts the value to a JSON-serialisable `Any` for encoding into
    /// network payloads.
    public var asAny: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .json(let j): return j.asAny
        }
    }

    /// Decodes a `TrafficalParameterValue` from a JSON value, given the
    /// parameter's declared type from the bundle.
    public static func from(any value: Any, type: String) -> TrafficalParameterValue {
        switch type {
        case "string":
            return .string(value as? String ?? "")
        case "number":
            if isStrictBool(value), let b = value as? Bool { return .number(b ? 1 : 0) }
            if let n = value as? NSNumber { return .number(n.doubleValue) }
            return .number(0)
        case "boolean":
            if isStrictBool(value), let b = value as? Bool { return .bool(b) }
            if let n = value as? NSNumber { return .bool(n.boolValue) }
            return .bool(false)
        case "json":
            return .json(TrafficalJSON.from(any: value))
        default:
            return .json(TrafficalJSON.from(any: value))
        }
    }
}
