import XCTest
@testable import TrafficalCore

/// Locks the ECMAScript `Number::toString` canonical stringify (spec S2).
final class CanonicalNumberTests: XCTestCase {
    func test_matches_ecmascript_number_toString() {
        let cases: [(Double, String)] = [
            (42, "42"),
            (100, "100"),
            (100.0, "100"),
            (1.5, "1.5"),
            (0.1, "0.1"),
            (0.5, "0.5"),
            (-42.5, "-42.5"),
            (1e-7, "1e-7"),
            (1e-6, "0.000001"),
            (1e15, "1000000000000000"),
            (1e21, "1e+21"),
            // 2^53 + 1 collapses to the parsed double 2^53 -> canonical form.
            (9007199254740993, "9007199254740992"),
            (-0.0, "0"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(canonicalNumberString(value), expected, "for \(value)")
        }
    }

    func test_never_traps_on_non_finite() {
        XCTAssertEqual(canonicalNumberString(.nan), "NaN")
        XCTAssertEqual(canonicalNumberString(.infinity), "Infinity")
        XCTAssertEqual(canonicalNumberString(-.infinity), "-Infinity")
        // A value that would have trapped the old String(Int64(n)) path.
        XCTAssertEqual(canonicalNumberString(1e19), "10000000000000000000")
    }
}
