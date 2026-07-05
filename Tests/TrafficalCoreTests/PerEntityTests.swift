import XCTest
@testable import TrafficalCore

final class PerEntityTests: XCTestCase {
    func test_build_entity_id_joins_with_underscore() {
        let context: TrafficalContext = ["productId": .string("prod-42"), "country": .string("US")]
        let entityId = buildEntityId(entityKeys: ["productId", "country"], context: context)
        XCTAssertEqual(entityId, "prod-42_US")
    }

    func test_build_entity_id_returns_nil_when_key_missing() {
        let context: TrafficalContext = ["productId": .string("prod-42")]
        let entityId = buildEntityId(entityKeys: ["productId", "country"], context: context)
        XCTAssertNil(entityId)
    }

    func test_entity_weights_uses_entity_specific_when_available() {
        let bundle = makeBundle()
        let weights = getEntityWeights(
            bundle: bundle,
            policyId: "policy_edge_fixed",
            entityId: "prod-42",
            allocationCount: 2
        )
        XCTAssertEqual(weights, [0.7, 0.3])
    }

    func test_entity_weights_falls_back_to_global() {
        let bundle = makeBundle()
        let weights = getEntityWeights(
            bundle: bundle,
            policyId: "policy_edge_fixed",
            entityId: "prod-new",
            allocationCount: 2
        )
        XCTAssertEqual(weights, [0.5, 0.5])
    }

    func test_entity_weights_falls_back_to_uniform_when_state_missing() {
        let bundle = makeBundle()
        let weights = getEntityWeights(
            bundle: bundle,
            policyId: "policy_missing",
            entityId: "prod-x",
            allocationCount: 3
        )
        XCTAssertEqual(weights, [1.0 / 3, 1.0 / 3, 1.0 / 3])
    }

    func test_resolve_per_entity_picks_allocation_by_weight() {
        let bundle = makeBundle()
        let policy = bundle.layers[0].policies[0]
        let context: TrafficalContext = [
            "userId": .string("user-abc"),
            "productId": .string("prod-42"),
        ]
        let result = resolvePerEntityPolicy(bundle: bundle, policy: policy, context: context, unitKeyValue: "user-abc")
        XCTAssertNotNil(result)
        // weights [0.7, 0.3] for entity prod-42 — the deterministic seed must
        // land on one of the two allocations; we only assert the SDK doesn't
        // crash and returns a real allocation. The exact index is part of the
        // conformance fixture.
        XCTAssertTrue(["variant_a", "variant_b"].contains(result?.allocation.name ?? ""))
    }

    func test_resolve_per_entity_returns_weight_actually_used_as_probability() throws {
        let bundle = makeBundle()
        let policy = bundle.layers[0].policies[0]
        let context: TrafficalContext = [
            "userId": .string("user-abc"),
            "productId": .string("prod-42"),
        ]
        let result = try XCTUnwrap(
            resolvePerEntityPolicy(bundle: bundle, policy: policy, context: context, unitKeyValue: "user-abc")
        )
        // Entity prod-42 has weights [0.7, 0.3]; the propensity must be the
        // weight of the allocation the deterministic selection landed on.
        let expected = result.allocation.name == "variant_a" ? 0.7 : 0.3
        XCTAssertEqual(result.probability, expected, accuracy: 1e-9)
    }

    func test_resolve_per_entity_uniform_probability_when_state_missing() throws {
        let bundle = makeBundle()
        var policy = bundle.layers[0].policies[0]
        policy.id = "policy_missing" // no entityState for this id -> uniform
        let context: TrafficalContext = [
            "userId": .string("user-abc"),
            "productId": .string("prod-42"),
        ]
        let result = try XCTUnwrap(
            resolvePerEntityPolicy(bundle: bundle, policy: policy, context: context, unitKeyValue: "user-abc")
        )
        XCTAssertEqual(result.probability, 0.5, accuracy: 1e-9)
    }

    func test_resolve_per_entity_returns_nil_for_missing_entity_key() {
        let bundle = makeBundle()
        let policy = bundle.layers[0].policies[0]
        let context: TrafficalContext = ["userId": .string("user-abc")] // no productId
        let result = resolvePerEntityPolicy(bundle: bundle, policy: policy, context: context, unitKeyValue: "user-abc")
        XCTAssertNil(result)
    }

    private func makeBundle() -> TrafficalConfigBundle {
        let policy = BundlePolicy(
            id: "policy_edge_fixed",
            state: .running,
            kind: .adaptive,
            allocations: [
                BundleAllocation(id: "alloc_variant_a", name: "variant_a",
                                 bucketRange: BundleBucketRange(start: 0, end: 499),
                                 overrides: ["pricing.discount": .number(10)]),
                BundleAllocation(id: "alloc_variant_b", name: "variant_b",
                                 bucketRange: BundleBucketRange(start: 500, end: 999),
                                 overrides: ["pricing.discount": .number(20)]),
            ],
            conditions: [],
            entityConfig: BundleEntityConfig(
                entityKeys: ["productId"],
                resolutionMode: .bundle
            )
        )
        return TrafficalConfigBundle(
            version: "v",
            orgId: "o",
            projectId: "p",
            env: "e",
            hashing: BundleHashingConfig(unitKey: "userId", bucketCount: 1000),
            parameters: [
                BundleParameter(key: "pricing.discount", type: "number", default: .number(0),
                                layerId: "layer_edge", namespace: ""),
            ],
            layers: [
                BundleLayer(id: "layer_edge", policies: [policy]),
            ],
            entityState: [
                "policy_edge_fixed": BundleEntityPolicyState(
                    global: EntityWeights(entityId: "_global", weights: [0.5, 0.5], computedAt: ""),
                    entities: [
                        "prod-42": EntityWeights(entityId: "prod-42", weights: [0.7, 0.3], computedAt: ""),
                        "prod-99": EntityWeights(entityId: "prod-99", weights: [0.2, 0.8], computedAt: ""),
                    ]
                ),
            ]
        )
    }
}
