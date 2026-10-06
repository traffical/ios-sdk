import Foundation

/// Why a bundle was rejected. `path` is a dotted pointer to the offending node.
public struct TrafficalBundleValidationFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// Dotted path, e.g. `layers[2].policies[0].allocations[1].bucketRange`.
    public let path: String
    /// Human-readable reason, safe to log. Never contains bundle values.
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }

    public var description: String { path.isEmpty ? reason : "\(path): \(reason)" }
}

/// Structural validation for a decoded config bundle (spec S8 + S11).
///
/// Mirrors `@traffical/core`'s `validateConfigBundle` for every field the
/// resolver dereferences, plus the S11 `bucketCount` upper bound. Applied at
/// EVERY ingestion point — the fetched bundle, `localConfig`, and the disk
/// cache — and the answer is yes or no: a bundle that half-parses produces
/// silently wrong buckets, which is worse than serving last-good.
///
/// Deliberately not validated: parameter defaults and allocation override
/// values (any JSON value is legal), condition operands, and fields the
/// resolver only reads optionally.
public enum TrafficalBundleValidator {
    public static func validate(_ bundle: TrafficalConfigBundle) -> TrafficalBundleValidationFailure? {
        if bundle.hashing.unitKey.isEmpty {
            return fail("hashing.unitKey", "missing or not a non-empty string")
        }
        let bucketCount = bundle.hashing.bucketCount
        if bucketCount < 1 || bucketCount > TrafficalNumeric.maxBucketCount {
            return fail("hashing.bucketCount", "not an integer in [1, \(TrafficalNumeric.maxBucketCount)]")
        }

        for (i, param) in bundle.parameters.enumerated() {
            if param.key.isEmpty { return fail("parameters[\(i)].key", "missing or not a non-empty string") }
            if param.layerId.isEmpty { return fail("parameters[\(i)].layerId", "missing or not a non-empty string") }
        }

        for (li, layer) in bundle.layers.enumerated() {
            let layerAt = "layers[\(li)]"
            if layer.id.isEmpty { return fail("\(layerAt).id", "missing or not a non-empty string") }
            for (pi, policy) in layer.policies.enumerated() {
                let policyAt = "\(layerAt).policies[\(pi)]"
                if policy.id.isEmpty { return fail("\(policyAt).id", "missing or not a non-empty string") }
                for (ci, condition) in policy.conditions.enumerated() {
                    let condAt = "\(policyAt).conditions[\(ci)]"
                    if condition.field.isEmpty { return fail("\(condAt).field", "missing or not a non-empty string") }
                    if condition.op.isEmpty { return fail("\(condAt).op", "missing or not a non-empty string") }
                }
                for (ai, allocation) in policy.allocations.enumerated() {
                    let allocAt = "\(policyAt).allocations[\(ai)]"
                    if allocation.name.isEmpty { return fail("\(allocAt).name", "missing or not a non-empty string") }
                    let range = allocation.bucketRange
                    if range.start < 0 || range.end < range.start {
                        return fail("\(allocAt).bucketRange", "bounds are negative or inverted")
                    }
                    if range.end > TrafficalNumeric.maxSafeInteger {
                        return fail("\(allocAt).bucketRange", "bounds are not safe integers")
                    }
                }
            }
        }
        return nil
    }

    private static func fail(_ path: String, _ reason: String) -> TrafficalBundleValidationFailure {
        TrafficalBundleValidationFailure(path: path, reason: reason)
    }
}
