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
///   4. Seed FNV-1a with `"ctx:" + unitKeyValue + ":" + policyId` and use
///      `weightedSelection` to deterministically pick an allocation index.
///
/// Returns `nil` when the policy has no `contextualModel` (graceful fall-through
/// to bucket-based allocation) or no allocations to pick from.
public func resolveContextualPolicy(
    policy: BundlePolicy,
    context: TrafficalContext,
    unitKeyValue: String
) -> BundleAllocation? {
    guard let model = policy.contextualModel else { return nil }
    if policy.allocations.isEmpty { return nil }

    // 1. Score each allocation in policy.allocations order — order matters
    // because weightedSelection uses array indices.
    let scores: [Double] = policy.allocations.map { allocation in
        if let coefficients = model.coefficients[allocation.name] {
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
    return policy.allocations[index]
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
public func softmaxProbabilities(scores: [Double], gamma: Double) -> [Double] {
    guard !scores.isEmpty else { return [] }
    let safeGamma = gamma <= 0 ? 1 : gamma

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
public func applyProbabilityFloor(probabilities: [Double], floor: Double) -> [Double] {
    guard floor > 0, !probabilities.isEmpty else { return probabilities }

    let clamped = probabilities.map { max($0, floor) }
    let sum = clamped.reduce(0, +)
    guard sum > 0 else { return probabilities }
    return clamped.map { $0 / sum }
}
