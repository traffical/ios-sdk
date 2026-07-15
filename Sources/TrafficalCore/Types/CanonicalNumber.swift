import Foundation

/// Canonical numeric stringification (spec S2).
///
/// A numeric unit-key value MUST be stringified with the single canonical rule
/// **ECMAScript `Number::toString`** (equivalently, `String()` applied to the
/// number parsed from JSON) so the *same* numeric key produces the *same*
/// string — and therefore the same hash bucket — on every Traffical SDK.
///
/// Swift's `String(Double)` already yields the shortest round-trippable digit
/// sequence, but formats it differently from ECMAScript (`100.0` vs `100`,
/// `9.007199254740992e+15` vs `9007199254740992`). This routine reuses Swift's
/// shortest digits and reformats them per the ECMAScript `Number::toString`
/// grammar (ES2015 §7.1.12.1 / §6.1.6.1.20).
///
/// This function is **total**: it never traps. Non-finite inputs render the
/// ECMAScript spellings (`"NaN"`, `"Infinity"`, `"-Infinity"`) instead of
/// crashing (spec S2 host-crash guard). This replaces the old trapping
/// `String(Int64(n))`, which crashed on magnitudes ≥ 2^63 and truncated
/// fractionals.
public func canonicalNumberString(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
    if value == 0 { return "0" } // covers both +0 and -0 (ECMAScript: -0 -> "0")
    if value < 0 { return "-" + canonicalNumberString(-value) }

    // Swift's shortest round-trippable representation, e.g. "100.0", "1.5",
    // "9.007199254740992e+15", "1e+21".
    let swift = String(value)
    var mantissa = swift
    var expE = 0
    if let eIdx = swift.firstIndex(where: { $0 == "e" || $0 == "E" }) {
        mantissa = String(swift[swift.startIndex..<eIdx])
        expE = Int(swift[swift.index(after: eIdx)...]) ?? 0
    }

    var intPart = mantissa
    var fracPart = ""
    if let dot = mantissa.firstIndex(of: ".") {
        intPart = String(mantissa[mantissa.startIndex..<dot])
        fracPart = String(mantissa[mantissa.index(after: dot)...])
    }

    // value = Int(digits) * 10^baseExp
    var digits = intPart + fracPart
    var baseExp = expE - fracPart.count
    // Trailing zeros are captured by the exponent (Swift only emits them for
    // integer-valued doubles, e.g. "100.0"); strip so `s` is minimal.
    while digits.count > 1 && digits.hasSuffix("0") { digits.removeLast(); baseExp += 1 }
    while digits.count > 1 && digits.hasPrefix("0") { digits.removeFirst() }

    // ECMAScript variables: value = s * 10^(n - k), s has k digits.
    let k = digits.count
    let n = baseExp + k

    // Integer, no decimal point: s followed by (n - k) zeros.
    if k <= n && n <= 21 {
        return digits + String(repeating: "0", count: n - k)
    }
    // Decimal point inside the digit run.
    if 0 < n && n <= 21 {
        let idx = digits.index(digits.startIndex, offsetBy: n)
        return String(digits[..<idx]) + "." + String(digits[idx...])
    }
    // Leading "0.000…" form.
    if -6 < n && n <= 0 {
        return "0." + String(repeating: "0", count: -n) + digits
    }
    // Exponential form.
    let e = n - 1
    let expStr = (e >= 0 ? "+" : "-") + String(abs(e))
    if k == 1 { return digits + "e" + expStr }
    return String(digits.first!) + "." + String(digits.dropFirst()) + "e" + expStr
}
