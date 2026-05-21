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
}
