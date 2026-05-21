import XCTest
@testable import TrafficalCore

final class ResolutionTests: XCTestCase {

    private func makeBundle(layers: [BundleLayer], parameters: [BundleParameter]) -> TrafficalConfigBundle {
        TrafficalConfigBundle(
            version: "2026-05-21T00:00:00Z",
            orgId: "org_test",
            projectId: "proj_test",
            env: "production",
            hashing: BundleHashingConfig(unitKey: "userId", bucketCount: 1000),
            parameters: parameters,
            layers: layers
        )
    }

    func test_returns_defaults_when_no_bundle() {
        let result = resolveParameters(bundle: nil, context: [:], defaults: ["x": .string("default")])
        XCTAssertEqual(result["x"], .string("default"))
    }

    func test_returns_defaults_when_no_unit_key() {
        let bundle = makeBundle(layers: [], parameters: [])
        let result = resolveParameters(bundle: bundle, context: [:], defaults: ["x": .string("default")])
        XCTAssertEqual(result["x"], .string("default"))
    }

    func test_returns_bundle_defaults_when_no_policy_matches() {
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "layer_1", policies: []),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("bundle_default"),
                                layerId: "layer_1", namespace: ""),
            ]
        )
        let result = resolveParameters(
            bundle: bundle,
            context: ["userId": .string("user_1")],
            defaults: ["x": .string("caller_default")]
        )
        XCTAssertEqual(result["x"], .string("bundle_default"))
    }

    func test_returns_policy_override_when_user_matches() {
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "layer_1", policies: [
                    BundlePolicy(
                        id: "policy_1",
                        state: .running,
                        kind: .static,
                        allocations: [
                            BundleAllocation(id: "a_0", name: "control",
                                             bucketRange: BundleBucketRange(start: 0, end: 999),
                                             overrides: ["x": .string("treatment")]),
                        ],
                        conditions: []
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("bundle_default"),
                                layerId: "layer_1", namespace: ""),
            ]
        )
        let result = resolveParameters(
            bundle: bundle,
            context: ["userId": .string("user_1")],
            defaults: ["x": .string("caller_default")]
        )
        XCTAssertEqual(result["x"], .string("treatment"))
    }

    func test_skips_policy_when_conditions_fail() {
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "layer_1", policies: [
                    BundlePolicy(
                        id: "policy_1",
                        state: .running,
                        kind: .static,
                        allocations: [
                            BundleAllocation(id: "a_0", name: "treatment",
                                             bucketRange: BundleBucketRange(start: 0, end: 999),
                                             overrides: ["x": .string("treatment")]),
                        ],
                        conditions: [
                            BundleCondition(field: "country", op: "eq", value: "DE"),
                        ]
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("bundle_default"),
                                layerId: "layer_1", namespace: ""),
            ]
        )
        let result = resolveParameters(
            bundle: bundle,
            context: ["userId": .string("u"), "country": .string("US")],
            defaults: ["x": .string("d")]
        )
        XCTAssertEqual(result["x"], .string("bundle_default"))
    }

    func test_eligible_bucket_range_skips_non_eligible() {
        // We need a bucket OUTSIDE the eligible range. user "u" + layer "L"
        // gives a deterministic bucket; we pick a tiny eligible range so most
        // users fall outside.
        let bucket = computeBucket(unitKeyValue: "u", layerId: "L", bucketCount: 1000)
        let outsideRange: BundleBucketRange
        if bucket == 0 {
            outsideRange = BundleBucketRange(start: 999, end: 999)
        } else {
            outsideRange = BundleBucketRange(start: 0, end: bucket - 1)
        }

        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "L", policies: [
                    BundlePolicy(
                        id: "p",
                        state: .running,
                        kind: .static,
                        allocations: [
                            BundleAllocation(id: "a", name: "T",
                                             bucketRange: BundleBucketRange(start: 0, end: 999),
                                             overrides: ["x": .string("treatment")]),
                        ],
                        conditions: [],
                        eligibleBucketRange: outsideRange.contains(bucket)
                            ? BundleBucketRange(start: 0, end: 0) // force non-match
                            : outsideRange
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ]
        )
        let result = resolveParameters(bundle: bundle, context: ["userId": .string("u")], defaults: ["x": .string("c")])
        XCTAssertEqual(result["x"], .string("d"))
    }

    func test_attribution_only_layer_is_tracked() {
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "layer_with_params", policies: [
                    BundlePolicy(
                        id: "p1",
                        state: .running,
                        kind: .static,
                        allocations: [
                            BundleAllocation(id: "a", name: "control",
                                             bucketRange: BundleBucketRange(start: 0, end: 999),
                                             overrides: ["x": .string("treat")]),
                        ],
                        conditions: []
                    ),
                ]),
                BundleLayer(id: "layer_attribution_only", policies: [
                    BundlePolicy(
                        id: "p2",
                        state: .running,
                        kind: .static,
                        allocations: [
                            BundleAllocation(id: "b", name: "x",
                                             bucketRange: BundleBucketRange(start: 0, end: 999),
                                             overrides: [:]),
                        ],
                        conditions: []
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"),
                                layerId: "layer_with_params", namespace: ""),
            ]
        )

        let decision = decide(
            bundle: bundle,
            context: ["userId": .string("u")],
            defaults: ["x": .string("c")]
        )
        XCTAssertEqual(decision.assignments["x"], .string("treat"))
        XCTAssertEqual(decision.metadata.layers.count, 2)
        let attributionOnlyLayer = decision.metadata.layers.first(where: { $0.layerId == "layer_attribution_only" })
        XCTAssertEqual(attributionOnlyLayer?.attributionOnly, true)
        let withParamsLayer = decision.metadata.layers.first(where: { $0.layerId == "layer_with_params" })
        XCTAssertEqual(withParamsLayer?.attributionOnly, false)
    }

    func test_decision_has_id_and_timestamp() {
        let bundle = makeBundle(layers: [], parameters: [])
        let decision = decide(
            bundle: bundle,
            context: ["userId": .string("u")],
            defaults: ["x": .string("c")]
        )
        XCTAssertFalse(decision.decisionId.isEmpty)
        XCTAssertFalse(decision.metadata.timestamp.isEmpty)
        XCTAssertEqual(decision.metadata.unitKeyValue, "u")
    }
}
