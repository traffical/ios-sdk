import XCTest
@testable import TrafficalCore

/// Edge-policy conformance:
///
/// - `expected_edge_policies.json` lists `edgeResults` directly. The SDK
///   threads them into `ResolveOptions` and the engine should produce the
///   expected assignments + layers without re-computing the per-entity step.
///
/// - `expected_resolve.json` simulates the edge worker: given `entity_weights`,
///   compute the edge results from weights + seed, then call `decide`. We
///   reproduce that pipeline here in test code (it's exactly what the edge
///   worker does in production — the SDK does the same when running in
///   `.server` mode, where the worker pre-computes the answer for us).
final class EdgePoliciesConformanceTests: XCTestCase {

    func test_expected_edge_policies_fixtures() throws {
        let fixture = try loadJSON(named: "expected_edge_policies.json")
        let bundle = try loadBundle(named: "bundle_edge_policies.json")

        guard let testCases = fixture["testCases"] as? [[String: Any]] else {
            XCTFail("expected_edge_policies has no testCases")
            return
        }

        for testCase in testCases {
            let caseName = (testCase["name"] as? String) ?? "<unnamed>"
            let context = decodeContext(testCase["context"] as? [String: Any] ?? [:])
            let defaultsRaw = testCase["defaults"] as? [String: Any] ?? [:]
            let defaults = decodeDefaults(defaultsRaw, bundle: bundle)

            // Build edgeResults from the fixture directly.
            var edgeResults: [String: EdgeResult] = [:]
            if let arr = testCase["edgeResults"] as? [[String: Any]] {
                for entry in arr {
                    guard
                        let policyId = entry["policyId"] as? String,
                        let entityId = entry["entityId"] as? String,
                        let index = numericInt(entry["allocationIndex"])
                    else { continue }
                    edgeResults[policyId] = EdgeResult(allocationIndex: index, entityId: entityId)
                }
            }

            let decision = decide(
                bundle: bundle,
                context: context,
                defaults: defaults,
                options: ResolveOptions(edgeResults: edgeResults)
            )

            assertAssignments(decision: decision, expected: testCase["expectedAssignments"] as? [String: Any] ?? [:],
                              bundle: bundle, caseName: "edge:\(caseName)")
            assertLayers(decision: decision, expected: testCase["expectedLayers"] as? [[String: Any]] ?? [],
                         caseName: "edge:\(caseName)")
        }
    }

    func test_expected_resolve_fixtures_simulate_edge_worker() throws {
        let fixture = try loadJSON(named: "expected_resolve.json")
        let bundle = try loadBundle(named: "bundle_edge_policies.json")
        let entityWeights = try loadJSON(named: "entity_weights.json")

        guard let testCases = fixture["testCases"] as? [[String: Any]] else {
            XCTFail("expected_resolve has no testCases")
            return
        }

        for testCase in testCases {
            let caseName = (testCase["name"] as? String) ?? "<unnamed>"
            let request = testCase["request"] as? [String: Any] ?? [:]
            let context = decodeContext(request["context"] as? [String: Any] ?? [:])
            let parameters = request["parameters"] as? [String]

            // Pre-compute edge results from entity weights — this is what
            // the edge worker does in production.
            let edgeResults = computeEdgeResults(bundle: bundle, context: context, entityWeights: entityWeights)

            // Verify our pre-computed edge results match the fixture's expectations.
            if let expectedEdge = testCase["expectedEdgeResults"] as? [[String: Any]] {
                let expectedMap = expectedEdge.reduce(into: [String: Int]()) { acc, entry in
                    if let pid = entry["policyId"] as? String, let idx = numericInt(entry["allocationIndex"]) {
                        acc[pid] = idx
                    }
                }
                for (policyId, expectedIndex) in expectedMap {
                    XCTAssertEqual(
                        edgeResults[policyId]?.allocationIndex,
                        expectedIndex,
                        "[resolve:\(caseName)] edge result mismatch for \(policyId)"
                    )
                }
                XCTAssertEqual(
                    edgeResults.count,
                    expectedMap.count,
                    "[resolve:\(caseName)] number of edge results"
                )
            }

            // Defaults: either every bundle parameter, or filtered to the
            // requested parameters list.
            var defaults: [String: TrafficalParameterValue] = [:]
            for param in bundle.parameters {
                if let filter = parameters, !filter.contains(param.key) { continue }
                defaults[param.key] = param.default
            }

            let decision = decide(
                bundle: bundle,
                context: context,
                defaults: defaults,
                options: ResolveOptions(edgeResults: edgeResults)
            )

            assertAssignments(decision: decision, expected: testCase["expectedAssignments"] as? [String: Any] ?? [:],
                              bundle: bundle, caseName: "resolve:\(caseName)")
            assertLayers(decision: decision, expected: testCase["expectedLayers"] as? [[String: Any]] ?? [],
                         caseName: "resolve:\(caseName)")
        }
    }

    // MARK: - Edge worker simulation

    /// Re-implements what the edge worker does in production: for every
    /// edge-mode policy in the bundle, compute the allocation index using
    /// `weightedSelection(weights, seed:)`, with weights coming from the
    /// `entity_weights.json` KV store (with a uniform fallback).
    private func computeEdgeResults(
        bundle: TrafficalConfigBundle,
        context: TrafficalContext,
        entityWeights: [String: Any]
    ) -> [String: EdgeResult] {
        guard let unit = context[bundle.hashing.unitKey], let unitKeyValue = unit.stringProjection else {
            return [:]
        }

        var out: [String: EdgeResult] = [:]
        for layer in bundle.layers {
            for policy in layer.policies {
                guard let entityConfig = policy.entityConfig, entityConfig.resolutionMode == .edge else { continue }
                guard let entityId = buildEntityId(entityKeys: entityConfig.entityKeys, context: context) else { continue }

                // Allocation count: dynamic from context, or fixed allocations.
                let allocationCount: Int
                if let dynamic = entityConfig.dynamicAllocations {
                    guard let n = context[dynamic.countKey]?.numberProjection, n > 0 else { continue }
                    allocationCount = Int(n.rounded(.down))
                } else {
                    allocationCount = policy.allocations.count
                }
                guard allocationCount > 0 else { continue }

                let weights = lookupWeights(
                    entityWeights: entityWeights,
                    policyId: policy.id,
                    entityId: entityId,
                    allocationCount: allocationCount
                )

                let index = weightedSelection(weights: weights, seed: "\(entityId):\(unitKeyValue):\(policy.id)")
                out[policy.id] = EdgeResult(allocationIndex: index, entityId: entityId)
            }
        }
        return out
    }

    private func lookupWeights(
        entityWeights: [String: Any],
        policyId: String,
        entityId: String,
        allocationCount: Int
    ) -> [Double] {
        if let policyState = entityWeights[policyId] as? [String: Any] {
            if let entities = policyState["entities"] as? [String: Any],
               let entity = entities[entityId] as? [String: Any],
               let weights = entity["weights"] as? [Any] {
                let parsed = weights.compactMap { numericDouble($0) }
                if parsed.count == allocationCount { return parsed }
            }
            if let global = policyState["_global"] as? [String: Any],
               let weights = global["weights"] as? [Any] {
                let parsed = weights.compactMap { numericDouble($0) }
                if parsed.count == allocationCount { return parsed }
            }
        }
        let uniform = 1.0 / Double(allocationCount)
        return Array(repeating: uniform, count: allocationCount)
    }

    // MARK: - Assertions

    private func assertAssignments(
        decision: TrafficalDecisionResult,
        expected: [String: Any],
        bundle: TrafficalConfigBundle,
        caseName: String
    ) {
        for (key, rawValue) in expected {
            let paramType = bundle.parameters.first(where: { $0.key == key })?.type ?? "json"
            let expectedValue = TrafficalParameterValue.from(any: rawValue, type: paramType)
            XCTAssertEqual(
                decision.assignments[key],
                expectedValue,
                "[\(caseName)] parameter \(key) mismatch"
            )
        }
    }

    private func assertLayers(
        decision: TrafficalDecisionResult,
        expected: [[String: Any]],
        caseName: String
    ) {
        XCTAssertEqual(decision.metadata.layers.count, expected.count, "[\(caseName)] layer count mismatch")
        for expectedLayer in expected {
            guard let layerId = expectedLayer["layerId"] as? String else { continue }
            guard let actual = decision.metadata.layers.first(where: { $0.layerId == layerId }) else {
                XCTFail("[\(caseName)] no actual layer with id \(layerId)")
                continue
            }
            if let bucket = numericInt(expectedLayer["bucket"]) {
                XCTAssertEqual(actual.bucket, bucket, "[\(caseName)] bucket for \(layerId)")
            }
            if let policyId = expectedLayer["policyId"] as? String {
                XCTAssertEqual(actual.policyId, policyId, "[\(caseName)] policyId for \(layerId)")
            }
            if let allocationName = expectedLayer["allocationName"] as? String {
                XCTAssertEqual(actual.allocationName, allocationName, "[\(caseName)] allocationName for \(layerId)")
            }
            if let allocationId = expectedLayer["allocationId"] as? String {
                XCTAssertEqual(actual.allocationId, allocationId, "[\(caseName)] allocationId for \(layerId)")
            }
            if let attributionOnly = expectedLayer["attributionOnly"] as? Bool {
                XCTAssertEqual(actual.attributionOnly, attributionOnly, "[\(caseName)] attributionOnly for \(layerId)")
            }
        }
    }

    // MARK: - Decoding helpers

    private func decodeDefaults(_ raw: [String: Any], bundle: TrafficalConfigBundle) -> [String: TrafficalParameterValue] {
        var out: [String: TrafficalParameterValue] = [:]
        for (key, value) in raw {
            let paramType = bundle.parameters.first(where: { $0.key == key })?.type ?? "json"
            out[key] = TrafficalParameterValue.from(any: value, type: paramType)
        }
        return out
    }

    private func decodeContext(_ raw: [String: Any]) -> TrafficalContext {
        var out: TrafficalContext = [:]
        for (k, v) in raw { out[k] = TrafficalContextValue.from(any: v) }
        return out
    }

    private func loadBundle(named name: String) throws -> TrafficalConfigBundle {
        let data = try Data(contentsOf: fixtureURL(named: name))
        return try TrafficalBundleDecoder.decode(data)
    }

    private func loadJSON(named name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL(named: name))
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TrafficalBundleDecodingError.invalid("\(name) is not a JSON object")
        }
        return dict
    }

    private func fixtureURL(named name: String) -> URL {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent() // Conformance/
            .deletingLastPathComponent() // TrafficalCoreTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        return repoRoot
            .appendingPathComponent("sdk-spec")
            .appendingPathComponent("test-vectors")
            .appendingPathComponent("fixtures")
            .appendingPathComponent(name)
    }
}
