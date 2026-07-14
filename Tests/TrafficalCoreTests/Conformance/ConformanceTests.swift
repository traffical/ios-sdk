import XCTest
@testable import TrafficalCore

/// Runs the language-agnostic test vectors from `sdk-spec/test-vectors/fixtures`.
///
/// The fixtures live in a git submodule rooted at the repository top level.
/// This test file lives at `Tests/TrafficalCoreTests/Conformance/` so we walk
/// four levels up to find the repo root, then descend into the submodule.
///
/// The runner is data-driven: it enumerates every bundle-mode fixture pair and
/// asserts `expectedHashing` (per-layer bucket + override unit-key value),
/// `expectedAssignments`, `expectedLayers` (bucket / policyId / allocationName,
/// and the *absence* of a policy on skipped bucket -1 layers), and
/// `expectedAllocation` (the chosen allocation, plus a propensity cross-check
/// against `expectedScoring.probabilities`). It NEVER asserts `selectedIndex`.
///
/// `bundle_edge_policies` / `expected_resolve` are exercised by the server/edge
/// harness (`EdgePoliciesConformanceTests`), not here.
final class ConformanceTests: XCTestCase {

    /// Every bundle-mode fixture pair. Includes the previously-skipped unicode /
    /// boundary / per-layer-unit-key vectors and the new 0.7.0 vectors
    /// (numeric unit key S2, empty unit-key skip S1, omitted-value never-match
    /// S5, contextual gamma-zero + high-floor guards S6).
    private static let fixtures: [String] = [
        "basic",
        "conditions",
        "conditions_omitted",
        "contextual",
        "contextual_boundary",
        "contextual_gamma_zero",
        "contextual_high_floor",
        "unicode",
        "numeric_unit_key",
        "empty_unit_key",
        "per_layer_unit_key",
    ]

    func test_all_bundle_fixtures() throws {
        for name in Self.fixtures {
            try runFixture(name: name)
        }
    }

    // MARK: - Runner

    private func runFixture(name: String) throws {
        let bundle = try loadBundle(name: name)
        let expected = try loadExpected(name: name)

        guard let testCases = expected["testCases"] as? [[String: Any]] else {
            XCTFail("[\(name)] expected_\(name).json has no testCases array")
            return
        }

        for testCase in testCases {
            let caseName = (testCase["name"] as? String) ?? "<unnamed>"
            let contextRaw = (testCase["context"] as? [String: Any]) ?? [:]
            let context = decodeContext(contextRaw)

            // Build defaults from every bundle parameter so all layers resolve.
            var defaults: [String: TrafficalParameterValue] = [:]
            for param in bundle.parameters { defaults[param.key] = param.default }

            let decision = decide(bundle: bundle, context: context, defaults: defaults)
            let layersById = Dictionary(
                decision.metadata.layers.map { ($0.layerId, $0) },
                uniquingKeysWith: { a, _ in a }
            )

            // 1. Hashing — per-layer bucket + override unit-key value.
            if let hashingMap = testCase["expectedHashing"] as? [String: Any] {
                for (layerId, raw) in hashingMap {
                    guard let dict = raw as? [String: Any] else { continue }
                    guard let layer = layersById[layerId] else {
                        XCTFail("[\(name)/\(caseName)] no resolved layer \(layerId)")
                        continue
                    }
                    if let expectedBucket = numericInt(dict["bucket"]) {
                        XCTAssertEqual(layer.bucket, expectedBucket,
                                       "[\(name)/\(caseName)] bucket mismatch for \(layerId)")
                    }
                    // Only override layers carry their own unitKeyValue; project-
                    // keyed layers leave it nil (the fixture value is informational).
                    if let expectedUnit = dict["unitKeyValue"] as? String, layer.unitKeyValue != nil {
                        XCTAssertEqual(layer.unitKeyValue, expectedUnit,
                                       "[\(name)/\(caseName)] unitKeyValue mismatch for \(layerId)")
                    }
                }
            }

            // 2. Assignments.
            if let expectedAssignmentsRaw = testCase["expectedAssignments"] as? [String: Any] {
                for (key, expectedRaw) in expectedAssignmentsRaw {
                    let paramType = bundle.parameters.first(where: { $0.key == key })?.type ?? "json"
                    let expectedValue = TrafficalParameterValue.from(any: expectedRaw, type: paramType)
                    XCTAssertEqual(decision.assignments[key], expectedValue,
                                   "[\(name)/\(caseName)] parameter \(key) mismatch")
                }
            }

            // 3. Per-layer expectations, incl. skipped (bucket -1) layers with
            //    no policy match.
            if let expectedLayers = testCase["expectedLayers"] as? [[String: Any]] {
                for expectedLayer in expectedLayers {
                    guard let layerId = expectedLayer["layerId"] as? String else { continue }
                    guard let layer = layersById[layerId] else {
                        XCTFail("[\(name)/\(caseName)] expected layer \(layerId) absent")
                        continue
                    }
                    if let expectedBucket = numericInt(expectedLayer["bucket"]) {
                        XCTAssertEqual(layer.bucket, expectedBucket,
                                       "[\(name)/\(caseName)] \(layerId) bucket")
                    }
                    if let expectedPolicy = expectedLayer["policyId"] as? String {
                        XCTAssertEqual(layer.policyId, expectedPolicy,
                                       "[\(name)/\(caseName)] \(layerId) policyId")
                    } else {
                        // Skipped / unmatched layers MUST carry no policy match.
                        XCTAssertNil(layer.policyId,
                                     "[\(name)/\(caseName)] \(layerId) should have no policy")
                        XCTAssertNil(layer.allocationName,
                                     "[\(name)/\(caseName)] \(layerId) should have no allocation")
                    }
                    if let expectedAlloc = expectedLayer["allocationName"] as? String {
                        XCTAssertEqual(layer.allocationName, expectedAlloc,
                                       "[\(name)/\(caseName)] \(layerId) allocationName")
                    }
                }
            }

            // 4. Contextual: chosen allocation + propensity cross-check.
            if let expectedAllocation = testCase["expectedAllocation"] as? String {
                let chosen = decision.metadata.layers.first { $0.allocationName == expectedAllocation }
                XCTAssertNotNil(chosen,
                                "[\(name)/\(caseName)] expected allocation \(expectedAllocation) not chosen")

                if let chosen = chosen,
                   let scoring = testCase["expectedScoring"] as? [String: Any],
                   let probs = scoring["probabilities"] as? [Any],
                   let policyId = chosen.policyId,
                   let policy = bundle.layers.flatMap({ $0.policies }).first(where: { $0.id == policyId }),
                   let allocIdx = policy.allocations.firstIndex(where: { $0.name == expectedAllocation }),
                   allocIdx < probs.count,
                   let expectedProb = numericDouble(probs[allocIdx]),
                   let actualProb = chosen.probability {
                    XCTAssertEqual(actualProb, expectedProb, accuracy: 1e-4,
                                   "[\(name)/\(caseName)] propensity for \(expectedAllocation)")
                }
            }
        }
    }

    // MARK: - Helpers

    private func decodeContext(_ raw: [String: Any]) -> TrafficalContext {
        var out: TrafficalContext = [:]
        for (k, v) in raw { out[k] = TrafficalContextValue.from(any: v) }
        return out
    }

    private func loadBundle(name: String) throws -> TrafficalConfigBundle {
        let data = try Data(contentsOf: fixtureURL("bundle_\(name).json"))
        return try TrafficalBundleDecoder.decode(data)
    }

    private func loadExpected(name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: fixtureURL("expected_\(name).json"))
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("expected_\(name).json is not a JSON object")
            return [:]
        }
        return dict
    }

    private func fixtureURL(_ fileName: String) -> URL {
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
            .appendingPathComponent(fileName)
    }
}
