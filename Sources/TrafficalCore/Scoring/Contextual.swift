import Foundation

/// Resolves a contextual-bandit policy via softmax scoring + probability
/// floor + deterministic weighted selection.
///
/// Placeholder for Stage 2 — Stage 1 deliberately returns `nil` so the engine
/// falls through to standard bucket-based resolution. The real implementation
/// lands alongside the `bundle_contextual` conformance fixture.
public func resolveContextualPolicy(
    policy: BundlePolicy,
    context: TrafficalContext,
    unitKeyValue: String
) -> BundleAllocation? {
    return nil
}
