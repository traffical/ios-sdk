import XCTest
@testable import TrafficalCore

final class ConditionsTests: XCTestCase {
    private let ctx: TrafficalContext = [
        "country": .string("US"),
        "age": .number(28),
        "premium": .bool(true),
        "name": .string("Marcel"),
    ]

    func test_eq() {
        XCTAssertTrue(evaluateCondition(.init(field: "country", op: "eq", value: "US"), context: ctx))
        XCTAssertFalse(evaluateCondition(.init(field: "country", op: "eq", value: "DE"), context: ctx))
    }

    func test_neq() {
        XCTAssertTrue(evaluateCondition(.init(field: "country", op: "neq", value: "DE"), context: ctx))
        XCTAssertFalse(evaluateCondition(.init(field: "country", op: "neq", value: "US"), context: ctx))
    }

    func test_in_nin() {
        XCTAssertTrue(evaluateCondition(.init(field: "country", op: "in", values: ["US", "CA"]), context: ctx))
        XCTAssertFalse(evaluateCondition(.init(field: "country", op: "in", values: ["DE"]), context: ctx))
        XCTAssertTrue(evaluateCondition(.init(field: "country", op: "nin", values: ["DE"]), context: ctx))
    }

    func test_numeric_comparisons() {
        XCTAssertTrue(evaluateCondition(.init(field: "age", op: "gt", value: 18), context: ctx))
        XCTAssertTrue(evaluateCondition(.init(field: "age", op: "gte", value: 28), context: ctx))
        XCTAssertTrue(evaluateCondition(.init(field: "age", op: "lt", value: 30), context: ctx))
        XCTAssertTrue(evaluateCondition(.init(field: "age", op: "lte", value: 28), context: ctx))
        XCTAssertFalse(evaluateCondition(.init(field: "age", op: "gt", value: 100), context: ctx))
    }

    func test_string_predicates() {
        XCTAssertTrue(evaluateCondition(.init(field: "name", op: "contains", value: "arce"), context: ctx))
        XCTAssertTrue(evaluateCondition(.init(field: "name", op: "startsWith", value: "Mar"), context: ctx))
        XCTAssertTrue(evaluateCondition(.init(field: "name", op: "endsWith", value: "cel"), context: ctx))
    }

    func test_regex() {
        XCTAssertTrue(evaluateCondition(.init(field: "name", op: "regex", value: "^M.+l$"), context: ctx))
        XCTAssertFalse(evaluateCondition(.init(field: "name", op: "regex", value: "^Z"), context: ctx))
    }

    func test_exists_notExists() {
        XCTAssertTrue(evaluateCondition(.init(field: "country", op: "exists"), context: ctx))
        XCTAssertFalse(evaluateCondition(.init(field: "country", op: "notExists"), context: ctx))
        XCTAssertTrue(evaluateCondition(.init(field: "missing_field", op: "notExists"), context: ctx))
    }

    func test_all_must_match() {
        let conditions = [
            BundleCondition(field: "country", op: "eq", value: "US"),
            BundleCondition(field: "age", op: "gte", value: 18),
        ]
        XCTAssertTrue(evaluateConditions(conditions, context: ctx))

        let withFail = conditions + [BundleCondition(field: "country", op: "eq", value: "DE")]
        XCTAssertFalse(evaluateConditions(withFail, context: ctx))
    }

    func test_unknown_operator_does_not_crash() {
        XCTAssertFalse(evaluateCondition(.init(field: "country", op: "bogus", value: "US"), context: ctx))
    }

    // MARK: - S3 strict typing (no coercion)

    func test_eq_is_strictly_typed() {
        let c: TrafficalContext = ["age": .number(42), "ageStr": .string("42")]
        // number 42 does not equal string "42" and vice versa.
        XCTAssertFalse(evaluateCondition(.init(field: "age", op: "eq", value: .string("42")), context: c))
        XCTAssertTrue(evaluateCondition(.init(field: "age", op: "eq", value: .number(42)), context: c))
        XCTAssertFalse(evaluateCondition(.init(field: "ageStr", op: "eq", value: .number(42)), context: c))
    }

    func test_relational_requires_numeric_context_and_value() {
        let c: TrafficalContext = ["build": .string("500")]
        // string "500" is NOT coerced to a number for gte.
        XCTAssertFalse(evaluateCondition(.init(field: "build", op: "gte", value: .number(500)), context: c))
        let n: TrafficalContext = ["build": .number(500)]
        XCTAssertTrue(evaluateCondition(.init(field: "build", op: "gte", value: .number(500)), context: n))
    }

    // MARK: - S5 omitted relational value never matches

    func test_omitted_relational_value_never_matches() {
        let c: TrafficalContext = ["score": .number(1000)]
        XCTAssertFalse(evaluateCondition(.init(field: "score", op: "gte"), context: c))
        XCTAssertFalse(evaluateCondition(.init(field: "score", op: "lt"), context: c))
    }

    // MARK: - S3 dot-notation nested lookup

    func test_nested_object_lookup() {
        let c: TrafficalContext = ["user": .object(["plan": .string("pro")])]
        XCTAssertTrue(evaluateCondition(.init(field: "user.plan", op: "eq", value: .string("pro")), context: c))
        XCTAssertTrue(evaluateCondition(.init(field: "user.missing", op: "notExists"), context: c))
    }

    func test_nested_array_index_and_length() {
        let c: TrafficalContext = ["tags": .array([.string("a"), .string("b"), .string("c")])]
        XCTAssertTrue(evaluateCondition(.init(field: "tags.0", op: "eq", value: .string("a")), context: c))
        XCTAssertTrue(evaluateCondition(.init(field: "tags.length", op: "eq", value: .number(3)), context: c))
        XCTAssertTrue(evaluateCondition(.init(field: "tags.length", op: "gte", value: .number(2)), context: c))
        // out-of-range index -> undefined -> notExists matches.
        XCTAssertTrue(evaluateCondition(.init(field: "tags.9", op: "notExists"), context: c))
    }

    func test_nested_lookup_through_primitive_is_undefined() {
        let c: TrafficalContext = ["user": .string("marcel")]
        // Reaching a segment on a primitive yields undefined, never throws.
        XCTAssertTrue(evaluateCondition(.init(field: "user.plan", op: "notExists"), context: c))
        XCTAssertFalse(evaluateCondition(.init(field: "user.plan", op: "exists"), context: c))
    }
}
