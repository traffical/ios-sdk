import Foundation

/// Evaluates a single condition against an evaluation context.
///
/// Operators (from the spec): `eq`, `neq`, `in`, `nin`, `gt`, `gte`, `lt`,
/// `lte`, `contains`, `startsWith`, `endsWith`, `regex`, `exists`, `notExists`.
public func evaluateCondition(_ condition: BundleCondition, context: TrafficalContext) -> Bool {
    let value = context[condition.field] ?? .null

    switch condition.op {
    case "exists":
        return !value.isMissing
    case "notExists":
        return value.isMissing
    case "eq":
        return equals(value, condition.value)
    case "neq":
        return !equals(value, condition.value)
    case "in":
        guard let candidates = condition.values else { return false }
        return candidates.contains(where: { equals(value, $0) })
    case "nin":
        guard let candidates = condition.values else { return true }
        return !candidates.contains(where: { equals(value, $0) })
    case "gt":
        guard let lhs = value.numberProjection, let rhs = condition.value?.numberProjection else { return false }
        return lhs > rhs
    case "gte":
        guard let lhs = value.numberProjection, let rhs = condition.value?.numberProjection else { return false }
        return lhs >= rhs
    case "lt":
        guard let lhs = value.numberProjection, let rhs = condition.value?.numberProjection else { return false }
        return lhs < rhs
    case "lte":
        guard let lhs = value.numberProjection, let rhs = condition.value?.numberProjection else { return false }
        return lhs <= rhs
    case "contains":
        guard let haystack = value.stringProjection, let needle = condition.value?.stringProjection else { return false }
        return haystack.contains(needle)
    case "startsWith":
        guard let haystack = value.stringProjection, let needle = condition.value?.stringProjection else { return false }
        return haystack.hasPrefix(needle)
    case "endsWith":
        guard let haystack = value.stringProjection, let needle = condition.value?.stringProjection else { return false }
        return haystack.hasSuffix(needle)
    case "regex":
        guard let haystack = value.stringProjection, let pattern = condition.value?.stringProjection else { return false }
        return matchesRegex(haystack: haystack, pattern: pattern)
    default:
        // Unknown operator — treat as non-match, never crash the engine.
        return false
    }
}

/// All conditions must pass for a policy to be eligible.
public func evaluateConditions(_ conditions: [BundleCondition], context: TrafficalContext) -> Bool {
    for condition in conditions {
        if !evaluateCondition(condition, context: context) { return false }
    }
    return true
}

private func equals(_ lhs: TrafficalContextValue, _ rhs: TrafficalContextValue?) -> Bool {
    guard let rhs = rhs else { return false }
    if lhs == rhs { return true }
    // Allow loose numeric / string equality so `"42" == 42` matches when one
    // side comes from a JSON string and the other from a numeric literal.
    if let l = lhs.numberProjection, let r = rhs.numberProjection { return l == r }
    if let l = lhs.stringProjection, let r = rhs.stringProjection { return l == r }
    return false
}

private func matchesRegex(haystack: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(haystack.startIndex..., in: haystack)
    return regex.firstMatch(in: haystack, options: [], range: range) != nil
}
