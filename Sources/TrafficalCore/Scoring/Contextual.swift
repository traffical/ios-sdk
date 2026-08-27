import Foundation

/// Resolves a contextual-bandit policy.
///
/// Pipeline (must match every Traffical SDK exactly):
///   1. For each allocation, compute a linear score: `intercept + sum(coef * context)`.
///      Missing context fields and unknown categorical values fall back to
///      the `missing` term embedded in the coefficient.
///   2. Apply softmax with temperature `gamma` to convert scores -> probabilities.
///   3. Apply `actionProbabilityFloor`: anything below the floor is clamped, then
///      renormalize.
///   4. Seed the SHA-256 v2 hash with `"ctx:" + unitKeyValue + ":" + policyId`
///      and use `weightedSelection` to deterministically pick an allocation index.
///
/// Returns the chosen allocation together with its floored-softmax probability
/// (the propensity logged on exposure/decision events for off-policy training).
///
/// Returns `nil` when the policy has no `contextualModel` (graceful fall-through
/// to bucket-based allocation) or no allocations to pick from.
public func resolveContextualPolicy(
    policy: BundlePolicy,
    context: TrafficalContext,
    unitKeyValue: String
) -> (allocation: BundleAllocation, probability: Double)? {
    guard let model = policy.contextualModel else { return nil }
    if policy.allocations.isEmpty { return nil }

    // 1. Score each allocation in policy.allocations order — order matters
    // because weightedSelection uses array indices.
    //
    // Coefficients are keyed by allocation `key` — the stable identifier —
    // with `name` as the fallback for bundles produced before `key` existed.
    // Keying by `name` alone is the silent-failure mode this indirection
    // exists to prevent: the lookup misses for every allocation whose display
    // name differs from its key ("Treatment A" vs "treatment-a"), those
    // allocations score defaultAllocationScore, and the trained model degrades to a
    // uniform softmax with nothing raised anywhere. Locked by the sdk-spec
    // `bundle_contextual_key_differs` vector.
    let scores: [Double] = policy.allocations.map { allocation in
        if let coefficients = model.coefficients[allocation.key ?? allocation.name] {
            return computeAllocationScore(coefficients: coefficients, context: context)
        } else {
            return model.defaultAllocationScore
        }
    }

    // 2. Softmax.
    let rawProbabilities = softmaxProbabilities(scores: scores, gamma: model.gamma)

    // 3. Probability floor + renormalize.
    let probabilities = applyProbabilityFloor(
        probabilities: rawProbabilities,
        floor: model.actionProbabilityFloor
    )

    // 4. Deterministic weighted selection.
    let seed = "ctx:\(unitKeyValue):\(policy.id)"
    let index = weightedSelection(weights: probabilities, seed: seed)
    guard index >= 0 && index < policy.allocations.count else { return nil }
    return (policy.allocations[index], probabilities[index])
}

/// Linear score for one allocation given the trained coefficients and the
/// current context.
public func computeAllocationScore(
    coefficients: BundleAllocationCoefficients,
    context: TrafficalContext
) -> Double {
    var score = coefficients.intercept

    for numeric in coefficients.numeric {
        if let value = context[numeric.key]?.numberProjection {
            score += numeric.coef * value
        } else {
            score += numeric.missing
        }
    }

    for categorical in coefficients.categorical {
        if let raw = context[categorical.key]?.stringProjection,
           let coef = categorical.values[raw] {
            score += coef
        } else {
            score += categorical.missing
        }
    }

    return score
}

/// Softmax with temperature gamma. Numerically stable: subtracts the max
/// before exponentiating so large positive scores do not overflow.
///
/// S6: the temperature used for scaling is `safeGamma = max(gamma, 1e-10)`,
/// never the raw gamma. A gamma of 0 (or below 1e-10) is clamped to 1e-10,
/// yielding a near-deterministic-but-defined distribution — NOT an argmax
/// shortcut and NOT a reset to temperature 1.
public func softmaxProbabilities(scores: [Double], gamma: Double) -> [Double] {
    guard !scores.isEmpty else { return [] }
    let safeGamma = Swift.max(gamma, 1e-10)

    let maxScore = scores.max() ?? 0
    let exps = scores.map { Foundation.exp(($0 - maxScore) / safeGamma) }
    let sum = exps.reduce(0, +)
    guard sum > 0 else {
        // All scores collapsed to zero — return uniform distribution.
        let uniform = 1.0 / Double(scores.count)
        return Array(repeating: uniform, count: scores.count)
    }
    return exps.map { $0 / sum }
}

/// Clamp any probability below the floor up to the floor, then renormalize so
/// the distribution still sums to 1.0. Ensures continued exploration even for
/// allocations that the model has learned to strongly dispreference.
///
/// S6: the floor applied per allocation is `effectiveFloor = min(floor, 1/n)`,
/// where `n` is the number of allocations, so flooring can never demand more
/// than 100% of the probability mass. When `floor <= 0`, flooring is skipped.
public func applyProbabilityFloor(probabilities: [Double], floor: Double) -> [Double] {
    guard floor > 0, !probabilities.isEmpty else { return probabilities }

    let effectiveFloor = Swift.min(floor, 1.0 / Double(probabilities.count))
    let clamped = probabilities.map { Swift.max($0, effectiveFloor) }
    let sum = clamped.reduce(0, +)
    guard sum > 0 else { return probabilities }
    return clamped.map { $0 / sum }
}
