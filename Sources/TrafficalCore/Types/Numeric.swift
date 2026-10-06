import Foundation

/// Total numeric conversions (spec S11, host safety).
///
/// Swift's `Int(Double)` traps on NaN, ±Infinity and out-of-range values, and
/// fixed-width arithmetic traps on overflow. Every conversion of a value that
/// came from the wire, a cache file, or the host app goes through here instead,
/// so a malformed number degrades to "absent" rather than terminating the host.
public enum TrafficalNumeric {
    /// Largest `hashing.bucketCount` the SDK accepts (S11). Keeps every bucket
    /// computation and bucket-range width well inside `Int` range.
    public static let maxBucketCount = 2_147_483_647

    /// Upper bound for a per-entity dynamic allocation count (S11). The SDK
    /// materialises one allocation per index, so the cap bounds memory.
    public static let maxDynamicAllocations = 10_000

    /// Largest integer every SDK represents exactly (2^53 − 1, JavaScript's
    /// `Number.MAX_SAFE_INTEGER`). Bucket-range bounds above it are malformed.
    public static let maxSafeInteger = 9_007_199_254_740_991

    /// Bounds for a server-suggested refresh cadence, in milliseconds (S11).
    public static let minRefreshMs = 1_000
    public static let maxRefreshMs = 86_400_000

    /// Clamps a server-suggested refresh cadence to [1 s, 24 h] (S11).
    /// Non-finite or non-positive hints are ignored (`nil`): a `0` hint once
    /// produced a hot loop of thousands of config requests per second.
    public static func refreshHintMs(_ ms: Double?) -> Int? {
        guard let ms = finite(ms), ms > 0 else { return nil }
        return int(Swift.min(Swift.max(ms, Double(minRefreshMs)), Double(maxRefreshMs)))
    }

    /// Truncates toward zero and converts to `Int`, or returns `nil` when the
    /// value is non-finite or does not fit. Never traps.
    public static func int(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    /// Returns the value only when it is finite.
    public static func finite(_ value: Double?) -> Double? {
        guard let value = value, value.isFinite else { return nil }
        return value
    }
}
