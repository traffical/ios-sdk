import Foundation

/// Computes the bucket for a unit + layer pair.
///
/// ```
/// digest  = SHA256(AssignmentHash.input(unitKeyValue, layerId))
/// hashInt = first 64 bits of digest, unsigned big-endian
/// bucket  = hashInt % bucketCount
/// ```
public func computeBucket(unitKeyValue: String, layerId: String, bucketCount: Int) -> Int {
    let digest = AssignmentHash.digest(AssignmentHash.input(unitKeyValue: unitKeyValue, layerId: layerId))
    return AssignmentHash.bucket(digest, modulus: bucketCount)
}

/// Finds the first allocation whose bucket range contains the given bucket.
public func findMatchingAllocation(bucket: Int, in allocations: [BundleAllocation]) -> BundleAllocation? {
    return allocations.first { $0.bucketRange.contains(bucket) }
}
