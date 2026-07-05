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

    func test_returns_bundle_defaults_when_no_unit_key() {
        let bundle = makeBundle(
            layers: [BundleLayer(id: "L", policies: [])],
            parameters: [BundleParameter(key: "x", type: "string", default: .string("bundle_d"), layerId: "L", namespace: "")]
        )
        let result = resolveParameters(bundle: bundle, context: [:], defaults: ["x": .string("caller_d")])
        XCTAssertEqual(result["x"], .string("bundle_d"))
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

    // MARK: - Propensity (layers[].probability / layers[].modelVersion)

    func test_static_policy_layer_omits_probability() {
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "L", policies: [
                    BundlePolicy(
                        id: "p_static",
                        state: .running,
                        kind: .static,
                        allocations: [
                            BundleAllocation(id: "a", name: "control",
                                             bucketRange: BundleBucketRange(start: 0, end: 999),
                                             overrides: ["x": .string("t")]),
                        ],
                        conditions: []
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ]
        )
        let decision = decide(bundle: bundle, context: ["userId": .string("u")], defaults: ["x": .string("c")])
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        XCTAssertEqual(layer?.policyId, "p_static")
        XCTAssertNil(layer?.probability)
        XCTAssertNil(layer?.modelVersion)
    }

    func test_adaptive_bucket_policy_probability_is_bucket_range_share() {
        // 1000 buckets; the chosen allocation's share is (end - start + 1) / 1000.
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "L", policies: [
                    BundlePolicy(
                        id: "p_bandit",
                        state: .running,
                        kind: .adaptive,
                        allocations: [
                            BundleAllocation(id: "a", name: "control",
                                             bucketRange: BundleBucketRange(start: 0, end: 249),
                                             overrides: ["x": .string("control")]),
                            BundleAllocation(id: "b", name: "treatment",
                                             bucketRange: BundleBucketRange(start: 250, end: 999),
                                             overrides: ["x": .string("treatment")]),
                        ],
                        conditions: [],
                        stateVersion: "2026-07-01T00:00:00Z"
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ]
        )
        let decision = decide(bundle: bundle, context: ["userId": .string("u")], defaults: ["x": .string("c")])
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        let expectedShare = layer?.allocationName == "control" ? 0.25 : 0.75
        XCTAssertEqual(layer?.probability ?? -1, expectedShare, accuracy: 1e-9)
        // modelVersion is reserved for linear_contextual policies.
        XCTAssertNil(layer?.modelVersion)
    }

    func test_contextual_policy_layer_carries_probability_and_model_version() {
        let model = BundleContextualModel(
            gamma: 1.0,
            actionProbabilityFloor: 0.1,
            defaultAllocationScore: 0,
            coefficients: [:],
            generatedAt: "2026-07-02T12:00:00Z"
        )
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "L", policies: [
                    BundlePolicy(
                        id: "p_ctx",
                        state: .running,
                        kind: .adaptive,
                        allocations: [
                            BundleAllocation(id: "a", name: "control",
                                             bucketRange: BundleBucketRange(start: 0, end: 499),
                                             overrides: ["x": .string("control")]),
                            BundleAllocation(id: "b", name: "treatment",
                                             bucketRange: BundleBucketRange(start: 500, end: 999),
                                             overrides: ["x": .string("treatment")]),
                        ],
                        conditions: [],
                        stateVersion: "2026-06-30T00:00:00Z",
                        contextualModel: model
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ]
        )
        let decision = decide(bundle: bundle, context: ["userId": .string("u")], defaults: ["x": .string("c")])
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        XCTAssertEqual(layer?.policyId, "p_ctx")
        // No trained coefficients -> uniform softmax over two allocations.
        XCTAssertEqual(layer?.probability ?? -1, 0.5, accuracy: 1e-9)
        // generatedAt wins over stateVersion when the model ships one.
        XCTAssertEqual(layer?.modelVersion, "2026-07-02T12:00:00Z")
    }

    func test_contextual_model_version_prefers_generated_at_over_alias() {
        let model = BundleContextualModel(
            gamma: 1.0,
            actionProbabilityFloor: 0.1,
            defaultAllocationScore: 0,
            coefficients: [:],
            generatedAt: "2026-07-02T12:00:00Z",
            modelVersion: "2026-07-01T00:00:00Z"
        )
        let decision = decide(
            bundle: makeContextualBundle(model: model, stateVersion: "2026-06-30T00:00:00Z"),
            context: ["userId": .string("u")],
            defaults: ["x": .string("c")]
        )
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        XCTAssertEqual(layer?.modelVersion, "2026-07-02T12:00:00Z")
    }

    func test_contextual_model_version_falls_back_to_alias_when_no_generated_at() {
        let model = BundleContextualModel(
            gamma: 1.0,
            actionProbabilityFloor: 0.1,
            defaultAllocationScore: 0,
            coefficients: [:],
            modelVersion: "2026-07-01T00:00:00Z"
        )
        let decision = decide(
            bundle: makeContextualBundle(model: model, stateVersion: "2026-06-30T00:00:00Z"),
            context: ["userId": .string("u")],
            defaults: ["x": .string("c")]
        )
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        XCTAssertEqual(layer?.modelVersion, "2026-07-01T00:00:00Z")
    }

    private func makeContextualBundle(model: BundleContextualModel, stateVersion: String?) -> TrafficalConfigBundle {
        makeBundle(
            layers: [
                BundleLayer(id: "L", policies: [
                    BundlePolicy(
                        id: "p_ctx",
                        state: .running,
                        kind: .adaptive,
                        allocations: [
                            BundleAllocation(id: "a", name: "control",
                                             bucketRange: BundleBucketRange(start: 0, end: 999),
                                             overrides: ["x": .string("control")]),
                        ],
                        conditions: [],
                        stateVersion: stateVersion,
                        contextualModel: model
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ]
        )
    }

    func test_contextual_model_version_falls_back_to_state_version() {
        let model = BundleContextualModel(
            gamma: 1.0,
            actionProbabilityFloor: 0.1,
            defaultAllocationScore: 0,
            coefficients: [:]
        )
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "L", policies: [
                    BundlePolicy(
                        id: "p_ctx",
                        state: .running,
                        kind: .adaptive,
                        allocations: [
                            BundleAllocation(id: "a", name: "control",
                                             bucketRange: BundleBucketRange(start: 0, end: 999),
                                             overrides: ["x": .string("control")]),
                        ],
                        conditions: [],
                        stateVersion: "2026-06-30T00:00:00Z",
                        contextualModel: model
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ]
        )
        let decision = decide(bundle: bundle, context: ["userId": .string("u")], defaults: ["x": .string("c")])
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        XCTAssertEqual(layer?.modelVersion, "2026-06-30T00:00:00Z")
    }

    func test_per_entity_bundle_policy_probability_is_weight_used() {
        let policy = BundlePolicy(
            id: "p_entity",
            state: .running,
            kind: .adaptive,
            allocations: [
                BundleAllocation(id: "a", name: "variant_a",
                                 bucketRange: BundleBucketRange(start: 0, end: 499),
                                 overrides: ["x": .string("a")]),
                BundleAllocation(id: "b", name: "variant_b",
                                 bucketRange: BundleBucketRange(start: 500, end: 999),
                                 overrides: ["x": .string("b")]),
            ],
            conditions: [],
            entityConfig: BundleEntityConfig(entityKeys: ["productId"], resolutionMode: .bundle)
        )
        let bundle = TrafficalConfigBundle(
            version: "2026-05-21T00:00:00Z",
            orgId: "org_test",
            projectId: "proj_test",
            env: "production",
            hashing: BundleHashingConfig(unitKey: "userId", bucketCount: 1000),
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ],
            layers: [BundleLayer(id: "L", policies: [policy])],
            entityState: [
                "p_entity": BundleEntityPolicyState(
                    global: EntityWeights(entityId: "_global", weights: [0.5, 0.5], computedAt: ""),
                    entities: [
                        "prod-42": EntityWeights(entityId: "prod-42", weights: [0.7, 0.3], computedAt: ""),
                    ]
                ),
            ]
        )
        let decision = decide(
            bundle: bundle,
            context: ["userId": .string("u"), "productId": .string("prod-42")],
            defaults: ["x": .string("c")]
        )
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        XCTAssertEqual(layer?.policyId, "p_entity")
        let expected = layer?.allocationName == "variant_a" ? 0.7 : 0.3
        XCTAssertEqual(layer?.probability ?? -1, expected, accuracy: 1e-9)
    }

    func test_per_entity_zero_weight_selection_omits_probability() {
        // All-zero entity weights: weightedSelection falls through to the last
        // index with weight 0. The events schema requires probability in
        // (0, 1], so the layer must omit it rather than emit 0.
        let policy = BundlePolicy(
            id: "p_entity",
            state: .running,
            kind: .adaptive,
            allocations: [
                BundleAllocation(id: "a", name: "variant_a",
                                 bucketRange: BundleBucketRange(start: 0, end: 499),
                                 overrides: ["x": .string("a")]),
                BundleAllocation(id: "b", name: "variant_b",
                                 bucketRange: BundleBucketRange(start: 500, end: 999),
                                 overrides: ["x": .string("b")]),
            ],
            conditions: [],
            entityConfig: BundleEntityConfig(entityKeys: ["productId"], resolutionMode: .bundle)
        )
        let bundle = TrafficalConfigBundle(
            version: "2026-05-21T00:00:00Z",
            orgId: "org_test",
            projectId: "proj_test",
            env: "production",
            hashing: BundleHashingConfig(unitKey: "userId", bucketCount: 1000),
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ],
            layers: [BundleLayer(id: "L", policies: [policy])],
            entityState: [
                "p_entity": BundleEntityPolicyState(
                    global: EntityWeights(entityId: "_global", weights: [0, 0], computedAt: ""),
                    entities: [
                        "prod-42": EntityWeights(entityId: "prod-42", weights: [0, 0], computedAt: ""),
                    ]
                ),
            ]
        )
        let decision = decide(
            bundle: bundle,
            context: ["userId": .string("u"), "productId": .string("prod-42")],
            defaults: ["x": .string("c")]
        )
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        XCTAssertEqual(layer?.policyId, "p_entity")
        XCTAssertNil(layer?.probability)
    }

    func test_adaptive_bucket_share_above_one_omits_probability() {
        // A misconfigured allocation spanning more buckets than the layer has
        // would yield a share > 1 — outside the schema's (0, 1] — so the
        // layer must omit the probability instead of emitting it raw.
        let bundle = makeBundle(
            layers: [
                BundleLayer(id: "L", policies: [
                    BundlePolicy(
                        id: "p_bandit",
                        state: .running,
                        kind: .adaptive,
                        allocations: [
                            BundleAllocation(id: "a", name: "control",
                                             bucketRange: BundleBucketRange(start: 0, end: 1999),
                                             overrides: ["x": .string("control")]),
                        ],
                        conditions: []
                    ),
                ]),
            ],
            parameters: [
                BundleParameter(key: "x", type: "string", default: .string("d"), layerId: "L", namespace: ""),
            ]
        )
        let decision = decide(bundle: bundle, context: ["userId": .string("u")], defaults: ["x": .string("c")])
        let layer = decision.metadata.layers.first(where: { $0.layerId == "L" })
        XCTAssertEqual(layer?.policyId, "p_bandit")
        XCTAssertNil(layer?.probability)
    }

    // MARK: - configVersion

    func test_decide_records_config_version_from_bundle() {
        let bundle = makeBundle(layers: [], parameters: [])
        let decision = decide(bundle: bundle, context: ["userId": .string("u")], defaults: ["x": .string("c")])
        XCTAssertEqual(decision.metadata.configVersion, "2026-05-21T00:00:00Z")
    }

    func test_decide_config_version_nil_without_bundle() {
        let decision = decide(bundle: nil, context: [:], defaults: ["x": .string("c")])
        XCTAssertNil(decision.metadata.configVersion)
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

    // MARK: - Per-layer unit key (multi-entity randomization)

    private func makeMixedUnitBundle() -> TrafficalConfigBundle {
        TrafficalConfigBundle(
            version: "2026-05-21T00:00:00Z",
            orgId: "org_test",
            projectId: "proj_test",
            env: "production",
            hashing: BundleHashingConfig(unitKey: "userId", bucketCount: 1000),
            parameters: [
                BundleParameter(key: "ui.theme", type: "string", default: .string("light"),
                                layerId: "layer_user_ui", namespace: "ui"),
                BundleParameter(key: "pricing.merchantDiscount", type: "number", default: .number(0),
                                layerId: "layer_merchant_pricing", namespace: "pricing"),
            ],
            layers: [
                BundleLayer(id: "layer_user_ui", policies: [
                    BundlePolicy(id: "policy_ui_theme", state: .running, kind: .static,
                                 allocations: [
                                    BundleAllocation(id: "a_ctrl", name: "control",
                                                     bucketRange: BundleBucketRange(start: 0, end: 499),
                                                     overrides: ["ui.theme": .string("light")]),
                                    BundleAllocation(id: "a_dark", name: "dark_mode",
                                                     bucketRange: BundleBucketRange(start: 500, end: 999),
                                                     overrides: ["ui.theme": .string("dark")]),
                                 ],
                                 conditions: []),
                ]),
                BundleLayer(id: "layer_merchant_pricing", unitKey: "merchantId", policies: [
                    BundlePolicy(id: "policy_merchant_discount", state: .running, kind: .static,
                                 allocations: [
                                    BundleAllocation(id: "a_no", name: "no_discount",
                                                     bucketRange: BundleBucketRange(start: 0, end: 499),
                                                     overrides: ["pricing.merchantDiscount": .number(0)]),
                                    BundleAllocation(id: "a_15", name: "discount_15",
                                                     bucketRange: BundleBucketRange(start: 500, end: 999),
                                                     overrides: ["pricing.merchantDiscount": .number(15)]),
                                 ],
                                 conditions: []),
                ]),
            ]
        )
    }

    func test_per_layer_unit_key_both_present() {
        let bundle = makeMixedUnitBundle()
        let decision = decide(
            bundle: bundle,
            context: ["userId": .string("user-abc"), "merchantId": .string("merchant-1")],
            defaults: ["ui.theme": .string("light"), "pricing.merchantDiscount": .number(0)]
        )

        // layer_user_ui: hashes on userId (project default) → bucket 641 → dark_mode
        let uiLayer = decision.metadata.layers.first(where: { $0.layerId == "layer_user_ui" })
        XCTAssertNotNil(uiLayer)
        XCTAssertEqual(uiLayer?.bucket, 641)
        XCTAssertNil(uiLayer?.unitKey)
        XCTAssertNil(uiLayer?.unitKeyValue)

        // layer_merchant_pricing: hashes on merchantId → bucket 764 → discount_15
        let pricingLayer = decision.metadata.layers.first(where: { $0.layerId == "layer_merchant_pricing" })
        XCTAssertNotNil(pricingLayer)
        XCTAssertEqual(pricingLayer?.bucket, 764)
        XCTAssertEqual(pricingLayer?.unitKey, "merchantId")
        XCTAssertEqual(pricingLayer?.unitKeyValue, "merchant-1")
        XCTAssertEqual(pricingLayer?.allocationName, "discount_15")

        XCTAssertEqual(decision.assignments["pricing.merchantDiscount"], .number(15))
    }

    func test_per_layer_unit_key_merchant_missing() {
        let bundle = makeMixedUnitBundle()
        let decision = decide(
            bundle: bundle,
            context: ["userId": .string("user-abc")],
            defaults: ["ui.theme": .string("light"), "pricing.merchantDiscount": .number(0)]
        )

        // user layer still resolves
        let uiLayer = decision.metadata.layers.first(where: { $0.layerId == "layer_user_ui" })
        XCTAssertNotNil(uiLayer)
        XCTAssertEqual(uiLayer?.bucket, 641)

        // merchant layer is skipped
        let pricingLayer = decision.metadata.layers.first(where: { $0.layerId == "layer_merchant_pricing" })
        XCTAssertNotNil(pricingLayer)
        XCTAssertEqual(pricingLayer?.bucket, -1)
        XCTAssertEqual(pricingLayer?.unitKey, "merchantId")
        XCTAssertEqual(pricingLayer?.unitKeyValue, "")

        // Bundle default returned for the skipped layer
        XCTAssertEqual(decision.assignments["pricing.merchantDiscount"], .number(0))
    }

    func test_per_layer_unit_key_project_key_missing() {
        let bundle = makeMixedUnitBundle()
        let decision = decide(
            bundle: bundle,
            context: ["merchantId": .string("merchant-1")],
            defaults: ["ui.theme": .string("light"), "pricing.merchantDiscount": .number(0)]
        )

        // user layer skipped — project unitKey (userId) not in context
        let uiLayer = decision.metadata.layers.first(where: { $0.layerId == "layer_user_ui" })
        XCTAssertNotNil(uiLayer)
        XCTAssertEqual(uiLayer?.bucket, -1)

        // merchant layer resolves independently
        let pricingLayer = decision.metadata.layers.first(where: { $0.layerId == "layer_merchant_pricing" })
        XCTAssertNotNil(pricingLayer)
        XCTAssertEqual(pricingLayer?.bucket, 764)
        XCTAssertEqual(pricingLayer?.allocationName, "discount_15")
        XCTAssertEqual(decision.assignments["pricing.merchantDiscount"], .number(15))

        // ui.theme should be the bundle default since layer was skipped
        XCTAssertEqual(decision.assignments["ui.theme"], .string("light"))
    }

    func test_per_layer_unit_key_both_missing() {
        let bundle = makeMixedUnitBundle()
        let decision = decide(
            bundle: bundle,
            context: [:],
            defaults: ["ui.theme": .string("light"), "pricing.merchantDiscount": .number(0)]
        )

        // Both layers skipped
        for layer in decision.metadata.layers {
            XCTAssertEqual(layer.bucket, -1)
        }

        // Bundle defaults returned
        XCTAssertEqual(decision.assignments["ui.theme"], .string("light"))
        XCTAssertEqual(decision.assignments["pricing.merchantDiscount"], .number(0))
    }

    func test_bundle_decoding_reads_layer_unit_key() throws {
        let json: [String: Any] = [
            "version": "2024-01-01T00:00:00.000Z",
            "orgId": "org_test",
            "projectId": "proj_test",
            "env": "production",
            "hashing": ["unitKey": "userId", "bucketCount": 1000],
            "parameters": [],
            "layers": [
                ["id": "L1", "policies": []],
                ["id": "L2", "unitKey": "merchantId", "policies": []],
            ]
        ]
        let bundle = try TrafficalBundleDecoder.decode(json)
        XCTAssertNil(bundle.layers[0].unitKey)
        XCTAssertEqual(bundle.layers[1].unitKey, "merchantId")
    }

    func test_bundle_decoding_reads_contextual_model_generated_at() throws {
        let json: [String: Any] = [
            "version": "2024-01-01T00:00:00.000Z",
            "orgId": "org_test",
            "projectId": "proj_test",
            "env": "production",
            "hashing": ["unitKey": "userId", "bucketCount": 1000],
            "parameters": [],
            "layers": [
                [
                    "id": "L1",
                    "policies": [
                        [
                            "id": "p_ctx",
                            "state": "running",
                            "kind": "adaptive",
                            "allocations": [
                                ["name": "control", "bucketRange": [0, 999], "overrides": [:]],
                            ],
                            "conditions": [],
                            "contextualModel": [
                                "gamma": 1.0,
                                "actionProbabilityFloor": 0.05,
                                "defaultAllocationScore": 0,
                                "coefficients": [:],
                                "generatedAt": "2026-07-02T12:00:00Z",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let bundle = try TrafficalBundleDecoder.decode(json)
        XCTAssertEqual(bundle.layers[0].policies[0].contextualModel?.generatedAt, "2026-07-02T12:00:00Z")
    }

    func test_bundle_decoding_reads_contextual_model_version_alias() throws {
        let json: [String: Any] = [
            "version": "2024-01-01T00:00:00.000Z",
            "orgId": "org_test",
            "projectId": "proj_test",
            "env": "production",
            "hashing": ["unitKey": "userId", "bucketCount": 1000],
            "parameters": [],
            "layers": [
                [
                    "id": "L1",
                    "policies": [
                        [
                            "id": "p_ctx",
                            "state": "running",
                            "kind": "adaptive",
                            "allocations": [
                                ["name": "control", "bucketRange": [0, 999], "overrides": [:]],
                            ],
                            "conditions": [],
                            "contextualModel": [
                                "gamma": 1.0,
                                "actionProbabilityFloor": 0.05,
                                "defaultAllocationScore": 0,
                                "coefficients": [:],
                                "modelVersion": "2026-07-01T00:00:00Z",
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let bundle = try TrafficalBundleDecoder.decode(json)
        let model = bundle.layers[0].policies[0].contextualModel
        XCTAssertNil(model?.generatedAt)
        XCTAssertEqual(model?.modelVersion, "2026-07-01T00:00:00Z")
    }
}
