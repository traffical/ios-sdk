import XCTest
@testable import Traffical
@testable import TrafficalCore

/// Validates event payloads against `sdk-spec/schemas/events.schema.json`.
///
/// Two guarantees:
///  1. The shared `events_conformance.json` vectors classify exactly as the
///     spec says (valid vs. invalid — the invalid cases violate the
///     `probability` (0, 1] bound).
///  2. REAL payloads emitted by the SDK's `EventLogger` (exposure, decision,
///     track) validate against the schema.
///
/// `EventSchemaValidator` is a focused validator implementing the subset of
/// the events schema those vectors exercise (base + per-type required fields,
/// property typing, the ExposureLayerInfo `probability` bound, track `values`
/// number map, and TrackAttribution constraints). It is intentionally not a
/// general draft-07 engine.
final class EventsSchemaConformanceTests: XCTestCase {

    func test_events_conformance_vectors() throws {
        let data = try Data(contentsOf: fixtureURL("events_conformance.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(root["testCases"] as? [[String: Any]])
        XCTAssertFalse(cases.isEmpty)

        for testCase in cases {
            let name = (testCase["name"] as? String) ?? "<unnamed>"
            let expectedValid = (testCase["valid"] as? Bool) ?? false
            let event = try XCTUnwrap(testCase["event"] as? [String: Any], "\(name): no event")
            let errors = EventSchemaValidator.validate(event)
            if expectedValid {
                XCTAssertTrue(errors.isEmpty, "\(name) should validate but: \(errors)")
            } else {
                XCTAssertFalse(errors.isEmpty, "\(name) should be rejected but validated clean")
            }
        }
    }

    func test_real_sdk_payloads_validate_against_schema() async throws {
        var batchBodies: [Data] = []
        let flushed = expectation(description: "events flushed")
        MockURLProtocol.handler = { request in
            if request.url?.path.contains("v1/events/batch") == true {
                if let body = request.httpBody { batchBodies.append(body) }
                flushed.fulfill()
            }
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lifecycle = ManualLifecycleProvider()

        let bundle = try TrafficalBundleDecoder.decode(Data(contextualBundleJSON.utf8))
        let options = TrafficalClientOptions(
            orgId: "org", projectId: "proj", env: "prod", apiKey: "pk",
            baseURL: URL(string: "https://sdk.test")!,
            localConfig: bundle, evaluationMode: .bundle, refreshIntervalMs: 0
        )
        let client = TrafficalClient(
            options: options,
            urlSession: MockURLProtocol.session(),
            keychain: InMemoryKeychainStore(),
            directory: tempDir,
            lifecycleProvider: lifecycle
        )

        _ = client.string("ui.heroVariant", default: "fallback") // decision + exposure (contextual -> probability + modelVersion)
        client.track("purchase", properties: ["orderId": "ord_1"], options: .init(value: 42.5, values: ["margin": 8.0]))
        lifecycle.emit(.background) // flush
        await fulfillment(of: [flushed], timeout: 2.0)

        let body = try XCTUnwrap(batchBodies.first)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let events = try XCTUnwrap(json?["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { ($0["type"] as? String) == "exposure" })
        XCTAssertTrue(events.contains { ($0["type"] as? String) == "decision" })
        XCTAssertTrue(events.contains { ($0["type"] as? String) == "track" })

        for event in events {
            let errors = EventSchemaValidator.validate(event)
            XCTAssertTrue(errors.isEmpty, "\(event["type"] ?? "?") payload failed schema: \(errors)\n\(event)")
        }
    }

    // MARK: - Helpers

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

    private let contextualBundleJSON = """
    {
      "version": "v-ctx", "orgId": "org", "projectId": "proj", "env": "prod",
      "hashing": { "unitKey": "userId", "bucketCount": 1000 },
      "parameters": [
        { "key": "ui.heroVariant", "type": "string", "default": "hero_control", "layerId": "layer_hero", "namespace": "ui" }
      ],
      "layers": [{
        "id": "layer_hero",
        "policies": [{
          "id": "policy_ctx", "state": "running", "kind": "adaptive",
          "allocations": [
            { "name": "control", "bucketRange": [0, 499], "overrides": { "ui.heroVariant": "hero_control" } },
            { "name": "bold", "bucketRange": [500, 999], "overrides": { "ui.heroVariant": "hero_bold" } }
          ],
          "conditions": [],
          "contextualModel": {
            "gamma": 1.0, "actionProbabilityFloor": 0.05, "defaultAllocationScore": 0,
            "coefficients": {}, "generatedAt": "2026-07-02T12:00:00Z"
          }
        }]
      }]
    }
    """
}

/// Focused validator for `events.schema.json` (draft-07 subset).
enum EventSchemaValidator {
    static func validate(_ event: [String: Any]) -> [String] {
        var errors: [String] = []

        // BaseEvent required + type enum.
        for field in ["type", "orgId", "projectId", "env", "unitKey", "timestamp"] {
            if !(event[field] is String) { errors.append("base.\(field) missing/not-string") }
        }
        let type = event["type"] as? String
        guard let type = type, ["exposure", "decision", "track"].contains(type) else {
            errors.append("type not one of exposure/decision/track")
            return errors
        }

        switch type {
        case "exposure", "decision":
            if !(event["assignments"] is [String: Any]) { errors.append("\(type).assignments missing/not-object") }
            guard let layers = event["layers"] as? [[String: Any]] else {
                errors.append("\(type).layers missing/not-array")
                return errors
            }
            for layer in layers { errors.append(contentsOf: validateLayer(layer)) }
        case "track":
            if !(event["event"] is String) { errors.append("track.event missing/not-string") }
            if let value = event["value"], !(value is NSNumber) { errors.append("track.value not-number") }
            if let values = event["values"] {
                if let map = values as? [String: Any] {
                    for (k, v) in map where !(v is NSNumber) { errors.append("track.values.\(k) not-number") }
                } else {
                    errors.append("track.values not-object")
                }
            }
            if let attribution = event["attribution"] as? [[String: Any]] {
                for attr in attribution { errors.append(contentsOf: validateAttribution(attr)) }
            }
        default:
            break
        }
        return errors
    }

    private static func validateLayer(_ layer: [String: Any]) -> [String] {
        var errors: [String] = []
        if !(layer["layerId"] is String) { errors.append("layer.layerId missing/not-string") }
        // bucket: integer required.
        if let n = layer["bucket"] as? NSNumber {
            if n.doubleValue.rounded() != n.doubleValue { errors.append("layer.bucket not-integer") }
        } else {
            errors.append("layer.bucket missing/not-integer")
        }
        // probability: number in (0, 1] when present.
        if let p = layer["probability"] {
            if let n = p as? NSNumber {
                let d = n.doubleValue
                if !(d > 0 && d <= 1) { errors.append("layer.probability out of (0,1]: \(d)") }
            } else {
                errors.append("layer.probability not-number")
            }
        }
        if let mv = layer["modelVersion"], !(mv is String) { errors.append("layer.modelVersion not-string") }
        return errors
    }

    private static func validateAttribution(_ attr: [String: Any]) -> [String] {
        var errors: [String] = []
        for field in ["layerId", "policyId", "allocationName"] {
            if !(attr[field] is String) { errors.append("attribution.\(field) missing/not-string") }
        }
        if let w = attr["weight"] {
            if let n = w as? NSNumber {
                let d = n.doubleValue
                if !(d >= 0 && d <= 1) { errors.append("attribution.weight out of [0,1]") }
            } else {
                errors.append("attribution.weight not-number")
            }
        }
        if let model = attr["model"] as? String {
            let allowed = ["first_touch", "last_touch", "linear", "time_decay", "position_based"]
            if !allowed.contains(model) { errors.append("attribution.model not in enum") }
        }
        return errors
    }
}
