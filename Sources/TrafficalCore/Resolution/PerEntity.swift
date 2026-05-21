import Foundation

/// Resolves a per-entity adaptive policy in bundle mode.
///
/// Placeholder for Stage 2 — Stage 1 returns `nil` so the engine treats
/// per-entity-bundle policies as a no-match and skips to the next policy.
/// Real implementation in Stage 2 reads `bundle.entityState[policyId]`,
/// builds the entity ID from `entityConfig.entityKeys`, looks up weights,
/// and uses `weightedSelection` to pick an allocation.
public func resolvePerEntityPolicy(
    bundle: TrafficalConfigBundle,
    policy: BundlePolicy,
    context: TrafficalContext,
    unitKeyValue: String
) -> (allocation: BundleAllocation, entityId: String)? {
    return nil
}
