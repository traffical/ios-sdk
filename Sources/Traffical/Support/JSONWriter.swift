import Foundation

/// The SDK's only path to `JSONSerialization.data(withJSONObject:)` (spec S11).
///
/// Foundation raises an Objective-C `NSInvalidArgumentException` — which Swift
/// `try` / `try?` cannot catch — when the object holds a NaN or ±Infinity
/// number or a non-JSON type. That exception terminates the host app. Every
/// payload the SDK writes (event batches, the failed-event backlog, the bundle
/// and resolve caches, edge requests, cache keys) therefore goes through here:
///
/// 1. Non-finite numbers are replaced with JSON `null`, the same output as
///    JavaScript's `JSON.stringify(NaN)`, so cross-SDK payloads agree.
/// 2. The sanitized object is checked with `isValidJSONObject`; anything still
///    invalid is reported as a thrown Swift error instead of an exception.
///
/// The `raw_json_write` SwiftLint rule bans direct calls everywhere else.
enum TrafficalJSONWriter {
    struct InvalidObject: Error, CustomStringConvertible {
        var description: String { "object is not JSON-serializable" }
    }

    static func data(_ object: Any, options: JSONSerialization.WritingOptions = []) throws -> Data {
        let sanitized = sanitize(object)
        guard JSONSerialization.isValidJSONObject(sanitized) else { throw InvalidObject() }
        // swiftlint:disable:next raw_json_write
        return try JSONSerialization.data(withJSONObject: sanitized, options: options)
    }

    /// Recursively replaces non-finite numbers with `NSNull`. Booleans,
    /// integers, finite doubles, strings and `NSNull` pass through untouched.
    static func sanitize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues(sanitize)
        }
        if let array = value as? [Any] {
            return array.map(sanitize)
        }
        if value is String { return value }
        // Swift Int / Double / Bool all bridge to NSNumber. Inspect the bridged
        // value but return the original so integer and boolean encodings are
        // preserved exactly.
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return value }
            return number.doubleValue.isFinite ? value : NSNull()
        }
        return value
    }
}
