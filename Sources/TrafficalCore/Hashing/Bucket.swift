import Foundation

/// Computes the bucket for a unit + layer pair.
///
/// `bucket = fnv1a(unitKeyValue + ":" + layerId) % bucketCount`
public func computeBucket(unitKeyValue: String, layerId: String, bucketCount: Int) -> Int {
    let hash = fnv1a("\(unitKeyValue):\(layerId)")
    return Int(hash % UInt32(bucketCount))
}

/// Finds the first allocation whose bucket range contains the given bucket.
public func findMatchingAllocation(bucket: Int, in allocations: [BundleAllocation]) -> BundleAllocation? {
    return allocations.first { $0.bucketRange.contains(bucket) }
}
