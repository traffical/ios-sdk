import Foundation

/// Evaluates a single condition against an evaluation context (spec S3).
///
/// Comparisons are **strictly typed** — there is no `"42" == 42` coercion
/// anywhere. Fields are resolved **flat-key-first, then by dot-notation nested
/// lookup**: a literal `"url.pathname"` key wins over `{ url: { pathname } }`;
/// the nested form (`user.plan`, `tags.0`, `tags.length`) is the fallback.
///
/// Operators: `eq`, `neq`, `in`, `nin`, `gt`, `gte`, `lt`, `lte`, `contains`,
/// `startsWith`, `endsWith`, `regex`, `exists`, `notExists`. An unknown
/// operator fails safe (no match).
public func evaluateCondition(_ condition: BundleCondition, context: TrafficalContext) -> Bool {
    let resolved = resolveField(condition.field, in: context)

    switch condition.op {
    case "exists":
        return isPresent(resolved)
    case "notExists":
        return !isPresent(resolved)

    case "eq":
        return strictEquals(resolved, condition.value)
    case "neq":
        // Exact negation of eq (undefined/absent/type-mismatch -> eq false -> neq true).
        return !strictEquals(resolved, condition.value)

    case "in":
        // Membership by strict equality. If `values` is not an array, `in`
        // does not match; an undefined/absent context value is never a member.
        guard let candidates = condition.values, let lhs = resolved else { return false }
        return candidates.contains(lhs)
    case "nin":
        // If `values` is not an array, `nin` matches; undefined is not a member.
        guard let candidates = condition.values else { return true }
        guard let lhs = resolved else { return true }
        return !candidates.contains(lhs)

    case "gt", "gte", "lt", "lte":
        // Relational ops match ONLY when the resolved context value is a number
        // AND the condition's `value` is a number. A missing threshold (S5)
        // therefore never matches.
        guard case .number(let lhs)? = resolved, case .number(let rhs)? = condition.value else { return false }
        switch condition.op {
        case "gt": return lhs > rhs
        case "gte": return lhs >= rhs
        case "lt": return lhs < rhs
        case "lte": return lhs <= rhs
        default: return false
        }

    case "contains", "startsWith", "endsWith", "regex":
        // String ops match ONLY when both the context value and `value` are
        // strings. No coercion of numbers/booleans.
        guard case .string(let haystack)? = resolved, case .string(let needle)? = condition.value else { return false }
        switch condition.op {
        case "contains": return needle.isEmpty ? true : haystack.contains(needle)
        case "startsWith": return haystack.hasPrefix(needle)
        case "endsWith": return haystack.hasSuffix(needle)
        case "regex": return matchesRegex(haystack: haystack, pattern: needle)
        default: return false
        }

    default:
        // Unknown operator — treat as non-match, never crash the engine.
        return false
    }
}

/// All conditions must pass for a policy to be eligible. An empty array matches.
public func evaluateConditions(_ conditions: [BundleCondition], context: TrafficalContext) -> Bool {
    for condition in conditions where !evaluateCondition(condition, context: context) {
        return false
    }
    return true
}

// MARK: - Field lookup (flat key first, then dot-notation nested)

/// Resolves `field` against `context` (spec "Field lookup").
///
/// 1. **Flat key.** If `context` has an entry whose key equals the full
///    `field` string (dots included), that value is returned — a `.null`
///    entry is still a hit (treated as absent by the operators) and no
///    traversal runs.
/// 2. **Nested.** Otherwise the field is split on `.` and walked:
///    - Each segment indexes into the current value **only when that value is
///      a non-null object**; array elements are addressed by their
///      numeric-string index (`tags.0`), and arrays additionally support
///      `.length`.
///    - A segment reached on `null`, a primitive, or an out-of-range index
///      yields `nil` (the "field is absent" signal).
///
/// Precedence: `["a.b": 1, "a": ["b": 2]]` resolves `a.b` to `1`. Never throws.
/// Also used by the engine's `filterContext` so a dotted `allowedFields` entry
/// captures the same value a condition would see.
func resolveField(_ field: String, in context: TrafficalContext) -> TrafficalContextValue? {
    if let direct = context[field] {
        return direct
    }
    let segments = field.components(separatedBy: ".")
    guard let first = segments.first else { return nil }
    var current = context[first]
    for seg in segments.dropFirst() {
        guard let cur = current else { return nil }
        switch cur {
        case .object(let obj):
            current = obj[seg]
        case .array(let arr):
            if seg == "length" {
                current = .number(Double(arr.count))
            } else if let idx = arrayIndex(seg), idx < arr.count {
                current = arr[idx]
            } else {
                return nil
            }
        default:
            return nil
        }
    }
    return current
}

// MARK: - Helpers

/// `exists` semantics: present means neither undefined (absent path) nor null.
private func isPresent(_ value: TrafficalContextValue?) -> Bool {
    guard let value = value else { return false }
    return !value.isMissing
}

/// Strict equality: both sides present and structurally equal (same case,
/// same value). `"42"` (string) never equals `42` (number).
private func strictEquals(_ lhs: TrafficalContextValue?, _ rhs: TrafficalContextValue?) -> Bool {
    guard let lhs = lhs, let rhs = rhs else { return false }
    return lhs == rhs
}

private func matchesRegex(haystack: String, pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(haystack.startIndex..., in: haystack)
    return regex.firstMatch(in: haystack, options: [], range: range) != nil
}

/// Parses a dot-path segment as a non-negative array index. A failable
/// `String` parse — it cannot trap.
private func arrayIndex(_ segment: String) -> Int? {
    // swiftlint:disable:next unchecked_int_conversion
    guard let index = Int(segment), index >= 0 else { return nil }
    return index
}
