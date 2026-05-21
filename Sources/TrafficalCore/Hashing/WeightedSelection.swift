import Foundation

/// Deterministic weighted selection using FNV-1a hashing.
///
/// Used by per-entity weighted resolution and contextual bandit scoring. The
/// `seed` string is hashed and projected to `[0, 1)` then walked through the
/// cumulative weights; the first bucket whose cumulative sum exceeds the
/// random fraction wins. Order matters and must match the JS implementation
/// exactly so that the same seed produces the same index.
public func weightedSelection(weights: [Double], seed: String) -> Int {
    if weights.isEmpty { return 0 }
    if weights.count == 1 { return 0 }

    let hash = fnv1a(seed)
    let random = Double(hash % 10_000) / 10_000.0

    var cumulative: Double = 0
    for (index, weight) in weights.enumerated() {
        cumulative += weight
        if random < cumulative {
            return index
        }
    }
    return weights.count - 1
}
