import XCTest
@testable import Traffical
@testable import TrafficalCore

/// Wires `sdk-spec/test-vectors/fixtures/exposure_shape.json` as a conformance
/// vector for `trackExposure()` (spec 0.7.0 S4/S8).
///
/// For each case we build the decision the vector describes, pre-seed the
/// session dedup from `alreadyExposed`, drive the real client's
/// `trackExposure()`, and capture what it emits to `/v1/events/batch`.
///
/// Asserted — the dimensions the 0.7.0 iOS SDK conforms to:
///  - EXACTLY the expected number of exposure events (ONE per call, or ZERO
///    when nothing survives attributionOnly + session-dedup filtering).
///  - The single event carries ONLY the newly-exposed, non-attributionOnly
///    layers (identified by layerId + allocationName).
///  - Every emitted event validates against `events.schema.json` (the focused
///    subset validator in `EventsSchemaConformanceTests`).
///
/// NOT asserted here: assignment NARROWING to the newly-exposed layers'
/// parameters. iOS still ships the full `decision.assignments`; full-vs-narrowed
/// cross-SDK alignment is a documented Phase-2 item (see the fixture's own
/// `description`). We only guard that the emitted assignments are a SUPERSET of
/// the expected (narrowed) set, so the vector still catches a dropped assignment.
final class ExposureShapeConformanceTests: XCTestCase {

    override func setUpWithError() throws {
        MockURLProtocol.reset()
    }

    func test_exposure_shape_conformance() async throws {
        let data = try Data(contentsOf: fixtureURL("exposure_shape.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(root["testCases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)

        for testCase in cases {
            try await runCase(testCase)
        }
    }

    private func runCase(_ testCase: [String: Any]) async throws {
        let name = (testCase["name"] as? String) ?? "<unnamed>"
        let unitKey = try XCTUnwrap(testCase["unitKey"] as? String, "\(name): unitKey")
        let configVersion = testCase["configVersion"] as? String
        let assignments = decodeAssignments(testCase["assignments"] as? [String: Any] ?? [:])
        let resolvedLayers = (testCase["resolvedLayers"] as? [[String: Any]] ?? []).map(decodeLayer)
        let alreadyExposed = testCase["alreadyExposed"] as? [[String: Any]] ?? []
        let expectedEvents = testCase["expectedEvents"] as? [[String: Any]] ?? []

        // Fresh, isolated client + lifecycle so only this case's events flush.
        let lifecycle = ManualLifecycleProvider()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExposureShape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var exposureEvents: [[String: Any]] = []
        let flushed = expectation(description: "flushed-\(name)")
        MockURLProtocol.handler = { request in
            if request.url?.path.contains("v1/events/batch") == true {
                if let body = request.httpBody,
                   let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                   let events = json["events"] as? [[String: Any]] {
                    exposureEvents += events.filter { ($0["type"] as? String) == "exposure" }
                }
                flushed.fulfill()
            }
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        let options = TrafficalClientOptions(
            orgId: "org", projectId: "proj-\(UUID().uuidString)", env: "prod", apiKey: "pk",
            baseURL: URL(string: "https://sdk.test")!,
            evaluationMode: .bundle, refreshIntervalMs: 0
        )
        let client = TrafficalClient(
            options: options,
            urlSession: MockURLProtocol.session(),
            keychain: InMemoryKeychainStore(),
            directory: dir,
            lifecycleProvider: lifecycle
        )

        // Pre-seed session dedup from `alreadyExposed`. The vector keys dedup on
        // (unitKey, layerId, allocationName); the SDK keys on
        // (unitKey, policyId, allocationName), so map layerId -> policyId via the
        // resolved layers.
        for entry in alreadyExposed {
            guard let layerId = entry["layerId"] as? String,
                  let allocationName = entry["allocationName"] as? String,
                  let policyId = resolvedLayers.first(where: { $0.layerId == layerId })?.policyId
            else { continue }
            _ = client.exposureDedup.checkAndMark(unitKey: unitKey, policyId: policyId, allocationName: allocationName)
        }

        let decision = TrafficalDecisionResult(
            decisionId: TrafficalIDGenerator.decisionId(),
            assignments: assignments,
            metadata: TrafficalDecisionMetadata(
                timestamp: "2026-05-21T00:00:00Z",
                unitKeyValue: unitKey,
                layers: resolvedLayers,
                configVersion: configVersion
            )
        )

        client.trackExposure(decision)
        // A track event guarantees the batch flushes even for the zero-exposure
        // cases (so `flushed` always fulfills).
        client.track("_probe")
        lifecycle.emit(.background)
        await fulfillment(of: [flushed], timeout: 2.0)

        // 1) Exactly the expected number of exposure events.
        XCTAssertEqual(exposureEvents.count, expectedEvents.count, "\(name): exposure event count")

        // 2) Emitted layers + schema validity for the single-event cases.
        if let expected = expectedEvents.first, let emitted = exposureEvents.first {
            let expectedLayers = layerKeys(expected["layers"] as? [[String: Any]] ?? [])
            let emittedLayers = layerKeys(emitted["layers"] as? [[String: Any]] ?? [])
            XCTAssertEqual(emittedLayers, expectedLayers, "\(name): exposed (layerId, allocationName) set")

            let errors = EventSchemaValidator.validate(emitted)
            XCTAssertTrue(errors.isEmpty, "\(name): emitted exposure failed schema: \(errors)")

            // Assignments: SUPERSET of the (narrowed) expected set — see the
            // class doc for why exact narrowing is a Phase-2 alignment item.
            let emittedAssign = emitted["assignments"] as? [String: Any] ?? [:]
            for key in (expected["assignments"] as? [String: Any] ?? [:]).keys {
                XCTAssertNotNil(emittedAssign[key], "\(name): emitted assignments missing \(key)")
            }
        }
    }

    // MARK: - Fixture decoding

    private func decodeAssignments(_ raw: [String: Any]) -> [String: TrafficalParameterValue] {
        var out: [String: TrafficalParameterValue] = [:]
        for (key, value) in raw {
            out[key] = TrafficalParameterValue.from(any: value, type: inferType(of: value))
        }
        return out
    }

    private func decodeLayer(_ d: [String: Any]) -> TrafficalLayerResolution {
        return TrafficalLayerResolution(
            layerId: (d["layerId"] as? String) ?? "",
            bucket: numericInt(d["bucket"]) ?? 0,
            policyId: d["policyId"] as? String,
            policyKey: d["policyKey"] as? String,
            allocationId: d["allocationId"] as? String,
            allocationName: d["allocationName"] as? String,
            allocationKey: d["allocationKey"] as? String,
            unitKey: d["unitKey"] as? String,
            unitKeyValue: d["unitKeyValue"] as? String,
            probability: numericDouble(d["probability"]),
            modelVersion: d["modelVersion"] as? String,
            attributionOnly: (d["attributionOnly"] as? Bool) ?? false
        )
    }

    private func layerKeys(_ layers: [[String: Any]]) -> Set<String> {
        return Set(layers.map { "\(($0["layerId"] as? String) ?? "")|\(($0["allocationName"] as? String) ?? "")" })
    }

    private func fixtureURL(_ fileName: String) -> URL {
        let testFile = URL(fileURLWithPath: #file)
        let repoRoot = testFile
            .deletingLastPathComponent() // TrafficalTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        return repoRoot
            .appendingPathComponent("sdk-spec")
            .appendingPathComponent("test-vectors")
            .appendingPathComponent("fixtures")
            .appendingPathComponent(fileName)
    }
}
