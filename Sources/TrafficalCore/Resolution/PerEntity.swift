import Foundation

/// Resolves a per-entity adaptive policy in bundle mode.
///
/// The bundle ships `entityState[policyId]` with per-entity weights and a
/// `_global` prior. We:
///   1. Build the entity ID by joining context values for `entityKeys` with `_`.
///   2. Compute allocation count: either dynamic (from a context field) or
///      from the policy's fixed allocations.
///   3. Look up weights — entity-specific, then global prior, then uniform.
///   4. Run deterministic weighted selection seeded by
///      `entityId:unitKeyValue:policyId`.
public func resolvePerEntityPolicy(
    bundle: TrafficalConfigBundle,
    policy: BundlePolicy,
    context: TrafficalContext,
    unitKeyValue: String
) -> (allocation: BundleAllocation, entityId: String)? {
    guard let entityConfig = policy.entityConfig else { return nil }

    // 1. Build entity ID.
    guard let entityId = buildEntityId(entityKeys: entityConfig.entityKeys, context: context) else {
        return nil
    }

    // 2. Determine allocations + allocation count.
    let allocations: [BundleAllocation]
    let allocationCount: Int

    if let dynamic = entityConfig.dynamicAllocations {
        guard let countValue = context[dynamic.countKey]?.numberProjection, countValue > 0 else {
            return nil
        }
        allocationCount = Int(countValue.rounded(.down))
        allocations = (0..<allocationCount).map { i in
            BundleAllocation(
                id: "\(policy.id)_dynamic_\(i)",
                name: String(i),
                bucketRange: BundleBucketRange(start: 0, end: 0),
                overrides: [:]
            )
        }
    } else {
        allocations = policy.allocations
        allocationCount = allocations.count
    }

    guard allocationCount > 0 else { return nil }

    // 3. Look up weights with fallback chain.
    let weights = getEntityWeights(
        bundle: bundle,
        policyId: policy.id,
        entityId: entityId,
        allocationCount: allocationCount
    )

    // 4. Deterministic weighted selection.
    let seed = "\(entityId):\(unitKeyValue):\(policy.id)"
    let index = weightedSelection(weights: weights, seed: seed)
    guard index >= 0 && index < allocations.count else { return nil }
    return (allocations[index], entityId)
}

/// Joins context values for the entity keys with `_`. Returns `nil` when any
/// key is missing — the engine then skips this policy gracefully.
public func buildEntityId(entityKeys: [String], context: TrafficalContext) -> String? {
    var parts: [String] = []
    for key in entityKeys {
        guard let value = context[key], !value.isMissing else { return nil }
        if let s = value.stringProjection { parts.append(s) } else { return nil }
    }
    return parts.joined(separator: "_")
}

/// Returns weights for an entity, with fallback to the global prior and then
/// to uniform weights.
public func getEntityWeights(
    bundle: TrafficalConfigBundle,
    policyId: String,
    entityId: String,
    allocationCount: Int
) -> [Double] {
    let policyState = bundle.entityState?[policyId]

    if let policyState = policyState {
        if let entity = policyState.entities[entityId], entity.weights.count == allocationCount {
            return entity.weights
        }
        if policyState.global.weights.count == allocationCount {
            return policyState.global.weights
        }
    }

    // Fallback: uniform.
    let uniform = 1.0 / Double(allocationCount)
    return Array(repeating: uniform, count: allocationCount)
}
