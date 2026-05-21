import XCTest
@testable import TrafficalCore

final class ContextualTests: XCTestCase {
    func test_score_with_numeric_and_categorical() {
        let coef = BundleAllocationCoefficients(
            intercept: 0.5,
            numeric: [
                BundleNumericCoefficient(key: "engagement_score", coef: 0.3, missing: 0),
            ],
            categorical: [
                BundleCategoricalCoefficient(
                    key: "device_type",
                    values: ["mobile": 0.8, "desktop": -0.2, "tablet": 0.1],
                    missing: 0
                ),
            ]
        )
        let context: TrafficalContext = ["engagement_score": .number(8), "device_type": .string("mobile")]
        let score = computeAllocationScore(coefficients: coef, context: context)
        // 0.5 + 0.3 * 8 + 0.8 = 3.7
        XCTAssertEqual(score, 3.7, accuracy: 0.0001)
    }

    func test_score_with_missing_numeric_falls_back_to_missing() {
        let coef = BundleAllocationCoefficients(
            intercept: 0.5,
            numeric: [
                BundleNumericCoefficient(key: "engagement_score", coef: 0.3, missing: 0.1),
            ],
            categorical: []
        )
        let context: TrafficalContext = [:]
        let score = computeAllocationScore(coefficients: coef, context: context)
        XCTAssertEqual(score, 0.6, accuracy: 0.0001)
    }

    func test_score_with_unknown_categorical_falls_back_to_missing() {
        let coef = BundleAllocationCoefficients(
            intercept: 0,
            numeric: [],
            categorical: [
                BundleCategoricalCoefficient(key: "device_type", values: ["mobile": 1.0], missing: -0.5),
            ]
        )
        let context: TrafficalContext = ["device_type": .string("smartwatch")]
        XCTAssertEqual(computeAllocationScore(coefficients: coef, context: context), -0.5, accuracy: 0.0001)
    }

    func test_softmax_distribution_sums_to_one() {
        let probs = softmaxProbabilities(scores: [0.0, 3.7, 0.0], gamma: 1.0)
        XCTAssertEqual(probs.reduce(0, +), 1.0, accuracy: 0.0001)
        // treatment_a should be the dominant probability.
        XCTAssertGreaterThan(probs[1], probs[0])
        XCTAssertGreaterThan(probs[1], probs[2])
    }

    func test_softmax_handles_uniform_zero() {
        let probs = softmaxProbabilities(scores: [0, 0, 0], gamma: 1.0)
        for p in probs { XCTAssertEqual(p, 1.0 / 3.0, accuracy: 0.0001) }
    }

    func test_probability_floor_clamps_low_values() {
        let probs = applyProbabilityFloor(probabilities: [0.95, 0.04, 0.01], floor: 0.1)
        // All values below 0.1 are raised to 0.1, then renormalized so they sum to 1.
        XCTAssertEqual(probs.reduce(0, +), 1.0, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(probs[1], 0.1 / (0.95 + 0.1 + 0.1) - 1e-6)
        XCTAssertGreaterThanOrEqual(probs[2], 0.1 / (0.95 + 0.1 + 0.1) - 1e-6)
    }

    func test_full_pipeline_picks_treatment_a_for_high_engagement_mobile() {
        // Mirrors the first fixture case from expected_contextual.json.
        let policy = makeContextualPolicy()
        let context: TrafficalContext = [
            "userId": .string("user-high-engage"),
            "engagement_score": .number(8.0),
            "device_type": .string("mobile"),
        ]
        let allocation = resolveContextualPolicy(policy: policy, context: context, unitKeyValue: "user-high-engage")
        XCTAssertEqual(allocation?.name, "treatment_a")
    }

    func test_full_pipeline_falls_back_to_treatment_a_for_missing_context() {
        let policy = makeContextualPolicy()
        let context: TrafficalContext = [
            "userId": .string("user-missing-ctx"),
        ]
        let allocation = resolveContextualPolicy(policy: policy, context: context, unitKeyValue: "user-missing-ctx")
        XCTAssertEqual(allocation?.name, "treatment_a")
    }

    private func makeContextualPolicy() -> BundlePolicy {
        let allocations = [
            BundleAllocation(id: "alloc_control", name: "control",
                             bucketRange: BundleBucketRange(start: 0, end: 332),
                             overrides: ["ui.heroVariant": .string("hero_control")]),
            BundleAllocation(id: "alloc_treatment_a", name: "treatment_a",
                             bucketRange: BundleBucketRange(start: 333, end: 665),
                             overrides: ["ui.heroVariant": .string("hero_bold")]),
            BundleAllocation(id: "alloc_treatment_b", name: "treatment_b",
                             bucketRange: BundleBucketRange(start: 666, end: 999),
                             overrides: ["ui.heroVariant": .string("hero_minimal")]),
        ]
        let model = BundleContextualModel(
            gamma: 1.0,
            actionProbabilityFloor: 0.05,
            defaultAllocationScore: 0,
            coefficients: [
                "control": BundleAllocationCoefficients(
                    intercept: 0,
                    numeric: [.init(key: "engagement_score", coef: 0, missing: 0)],
                    categorical: [.init(key: "device_type",
                                        values: ["mobile": 0, "desktop": 0, "tablet": 0],
                                        missing: 0)]
                ),
                "treatment_a": BundleAllocationCoefficients(
                    intercept: 0.5,
                    numeric: [.init(key: "engagement_score", coef: 0.3, missing: 0)],
                    categorical: [.init(key: "device_type",
                                        values: ["mobile": 0.8, "desktop": -0.2, "tablet": 0.1],
                                        missing: 0)]
                ),
                "treatment_b": BundleAllocationCoefficients(
                    intercept: -0.3,
                    numeric: [.init(key: "engagement_score", coef: 0.1, missing: 0)],
                    categorical: [.init(key: "device_type",
                                        values: ["mobile": -0.5, "desktop": 0.6, "tablet": 0.3],
                                        missing: 0)]
                ),
            ]
        )
        return BundlePolicy(
            id: "policy_contextual",
            state: .running,
            kind: .adaptive,
            allocations: allocations,
            conditions: [],
            contextualModel: model
        )
    }
}
