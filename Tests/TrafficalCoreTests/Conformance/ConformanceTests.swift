import XCTest
@testable import TrafficalCore

/// Runs the language-agnostic test vectors from `sdk-spec/test-vectors/fixtures`.
///
/// The fixtures live in a git submodule rooted at the repository top level.
/// This test file lives at `Tests/TrafficalCoreTests/Conformance/` so we walk
/// four levels up to find the repo root, then descend into the submodule.
final class ConformanceTests: XCTestCase {

    func test_bundle_basic() throws {
        try runFixture(name: "basic")
    }

    func test_bundle_conditions() throws {
        try runFixture(name: "conditions")
    }

    func test_bundle_contextual() throws {
        try runFixture(name: "contextual")
    }

    // `bundle_edge_policies` + `expected_resolve` land alongside Stage 4 once
    // server-mode and edge-policy plumbing is wired into the engine harness.

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

            // 1. Hashing — fixture maps layerId -> { "bucket": <int> }.
            if let hashingMap = testCase["expectedHashing"] as? [String: Any] {
                guard let unit = context[bundle.hashing.unitKey] else {
                    XCTFail("[\(name) / \(caseName)] missing unit key in context")
                    continue
                }
                let unitKeyValue = unit.stringProjection ?? ""
                for (layerId, raw) in hashingMap {
                    let expectedBucket: Int? = {
                        if let dict = raw as? [String: Any] { return numericInt(dict["bucket"]) }
                        return numericInt(raw)
                    }()
                    guard let expectedBucket = expectedBucket else { continue }
                    let actual = computeBucket(
                        unitKeyValue: unitKeyValue,
                        layerId: layerId,
                        bucketCount: bundle.hashing.bucketCount
                    )
                    XCTAssertEqual(
                        actual,
                        expectedBucket,
                        "[\(name) / \(caseName)] bucket mismatch for layer \(layerId)"
                    )
                }
            }

            // 2. Assignments — build defaults from the bundle so every key resolves.
            if let expectedAssignmentsRaw = testCase["expectedAssignments"] as? [String: Any] {
                var defaults: [String: TrafficalParameterValue] = [:]
                for param in bundle.parameters {
                    defaults[param.key] = param.default
                }

                let resolved = resolveParameters(bundle: bundle, context: context, defaults: defaults)

                for (key, expectedRaw) in expectedAssignmentsRaw {
                    let paramType = bundle.parameters.first(where: { $0.key == key })?.type ?? "json"
                    let expectedValue = TrafficalParameterValue.from(any: expectedRaw, type: paramType)
                    XCTAssertEqual(
                        resolved[key],
                        expectedValue,
                        "[\(name) / \(caseName)] parameter \(key) mismatch"
                    )
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
        let url = fixtureURL("bundle_\(name).json")
        let data = try Data(contentsOf: url)
        return try TrafficalBundleDecoder.decode(data)
    }

    private func loadExpected(name: String) throws -> [String: Any] {
        let url = fixtureURL("expected_\(name).json")
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("expected_\(name).json is not a JSON object")
            return [:]
        }
        return dict
    }

    private func fixtureURL(_ fileName: String) -> URL {
        // #file -> .../Tests/TrafficalCoreTests/Conformance/ConformanceTests.swift
        // Walk up to repo root then into the submodule.
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
