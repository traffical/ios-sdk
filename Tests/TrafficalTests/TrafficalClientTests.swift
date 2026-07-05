import XCTest
@testable import Traffical
@testable import TrafficalCore

final class TrafficalClientTests: XCTestCase {
    private var tempDir: URL!
    private var lifecycle: ManualLifecycleProvider!

    override func setUpWithError() throws {
        MockURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        lifecycle = ManualLifecycleProvider()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Bundle mode

    func test_bundle_mode_returns_caller_defaults_before_initialize() {
        let client = makeClient(mode: .bundle)
        // No localConfig, no cached bundle, no network — defaults pass through.
        XCTAssertEqual(client.string("ui.color", default: "#FFF"), "#FFF")
    }

    func test_bundle_mode_resolves_from_local_config() {
        let bundle = makeSampleBundle()
        let client = makeClient(mode: .bundle, localConfig: bundle)
        let color = client.string("ui.color", default: "#FFF")
        XCTAssertTrue(["#0000FF", "#FF0000"].contains(color), "got \(color)")
    }

    func test_initialize_fetches_bundle_over_http() async throws {
        MockURLProtocol.handler = { _ in
            return .init(
                statusCode: 200,
                headers: ["ETag": "\"v1\""],
                body: Data(self.sampleBundleJSON.utf8)
            )
        }
        let client = makeClient(mode: .bundle)
        XCTAssertNil(client.lastRefreshAt)
        await client.initialize()
        XCTAssertTrue(client.isInitialized)
        XCTAssertTrue(client.bundleLoaded)
        XCTAssertEqual(client.configVersion, "v")
        XCTAssertNotNil(client.lastRefreshAt)
        let color = client.string("ui.color", default: "#FFF")
        XCTAssertTrue(["#0000FF", "#FF0000"].contains(color))
    }

    func test_debug_accessors_before_initialize() {
        let client = makeClient(mode: .bundle)
        XCTAssertFalse(client.bundleLoaded)
        XCTAssertNil(client.configVersion)
        XCTAssertNil(client.lastRefreshAt)
    }

    func test_initialize_in_server_mode_uses_resolve_endpoint() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.contains("v1/resolve") ?? false)
            return .init(
                statusCode: 200,
                headers: [:],
                body: Data("""
                {
                  "decisionId": "dec_1",
                  "assignments": { "ui.color": "#0F0" },
                  "metadata": {
                    "timestamp": "2026-05-21T00:00:00Z",
                    "unitKeyValue": "u",
                    "layers": []
                  }
                }
                """.utf8)
            )
        }
        let client = makeClient(mode: .server)
        await client.initialize()
        XCTAssertEqual(client.string("ui.color", default: "#FFF"), "#0F0")
    }

    func test_decide_returns_full_decision_result() {
        let client = makeClient(mode: .bundle, localConfig: makeSampleBundle())
        let decision = client.decide(defaults: ["ui.color": .string("#FFF")])
        XCTAssertFalse(decision.decisionId.isEmpty)
        XCTAssertFalse(decision.metadata.unitKeyValue.isEmpty)
    }

    func test_overrides_apply_after_resolution() {
        let client = makeClient(mode: .bundle, localConfig: makeSampleBundle())
        client.applyOverrides(["ui.color": .string("#OVR")])
        let value = client.string("ui.color", default: "#FFF")
        XCTAssertEqual(value, "#OVR")
        client.clearOverrides()
        XCTAssertNotEqual(client.string("ui.color", default: "#FFF"), "#OVR")
    }

    func test_typed_getters_fall_back_when_bundle_missing_key() {
        let client = makeClient(mode: .bundle, localConfig: makeSampleBundle())
        XCTAssertEqual(client.bool("unknown.flag", default: true), true)
        XCTAssertEqual(client.int("unknown.count", default: 42), 42)
    }

    func test_track_emits_event_to_logger() {
        let client = makeClient(mode: .bundle, localConfig: makeSampleBundle())
        client.track("purchase", properties: ["orderId": "ord_1"], value: 99.99)
        // The event is queued — drain is tested in EventLoggerTests.
        // Here we just assert the public API doesn't crash and that there is
        // at least a stable ID to attribute against.
        XCTAssertFalse(client.getStableID().isEmpty)
    }

    func test_identify_clears_exposure_dedup() {
        let client = makeClient(mode: .bundle, localConfig: makeSampleBundle())
        let first = client.getStableID()
        client.identify("user_logged_in_42")
        XCTAssertEqual(client.getStableID(), "user_logged_in_42")
        XCTAssertNotEqual(client.getStableID(), first)
    }

    // MARK: - Event contract (configVersion + propensity)

    func test_events_carry_config_version_of_evaluated_bundle() async throws {
        var batchBodies: [Data] = []
        let flushed = expectation(description: "events flushed")
        MockURLProtocol.handler = { request in
            if request.url?.path.contains("v1/events/batch") == true {
                if let body = request.httpBody { batchBodies.append(body) }
                flushed.fulfill()
            }
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        let client = makeClient(mode: .bundle, localConfig: makeSampleBundle())
        _ = client.string("ui.color", default: "#FFF") // queues decision + exposure
        lifecycle.emit(.background) // triggers flush
        await fulfillment(of: [flushed], timeout: 2.0)

        let body = try XCTUnwrap(batchBodies.first)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let events = try XCTUnwrap(json?["events"] as? [[String: Any]])
        let exposure = try XCTUnwrap(events.first(where: { ($0["type"] as? String) == "exposure" }))
        let decision = try XCTUnwrap(events.first(where: { ($0["type"] as? String) == "decision" }))
        XCTAssertEqual(exposure["configVersion"] as? String, "v")
        XCTAssertEqual(decision["configVersion"] as? String, "v")
        // Static policy: layers must NOT carry a probability.
        let layers = try XCTUnwrap(exposure["layers"] as? [[String: Any]])
        XCTAssertNil(layers[0]["probability"])
    }

    func test_disk_cached_bundle_round_trips_contextual_model() async throws {
        MockURLProtocol.handler = { _ in
            return .init(
                statusCode: 200,
                headers: ["ETag": "\"v1\""],
                body: Data(self.contextualBundleJSON.utf8)
            )
        }
        let first = makeClient(mode: .bundle)
        await first.initialize()

        // A fresh client seeded only from the disk cache must resolve the
        // contextual policy identically — probability + modelVersion intact.
        MockURLProtocol.handler = { _ in .init(statusCode: 500, headers: [:], body: Data()) }
        let second = makeClient(mode: .bundle)
        let decision = second.decide(defaults: ["ui.heroVariant": .string("fallback")])
        XCTAssertEqual(decision.metadata.configVersion, "v-ctx")
        let layer = try XCTUnwrap(decision.metadata.layers.first(where: { $0.layerId == "layer_hero" }))
        XCTAssertEqual(layer.policyId, "policy_ctx")
        // Empty coefficients -> uniform softmax over the two allocations.
        XCTAssertEqual(layer.probability ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(layer.modelVersion, "2026-07-02T12:00:00Z")
    }

    // MARK: - Helpers

    private func makeClient(mode: TrafficalClientOptions.EvaluationMode, localConfig: TrafficalConfigBundle? = nil) -> TrafficalClient {
        let options = TrafficalClientOptions(
            orgId: "org",
            projectId: "proj",
            env: "prod",
            apiKey: "pk",
            baseURL: URL(string: "https://sdk.test")!,
            localConfig: localConfig,
            evaluationMode: mode,
            refreshIntervalMs: 0
        )
        return TrafficalClient(
            options: options,
            urlSession: MockURLProtocol.session(),
            keychain: InMemoryKeychainStore(),
            directory: tempDir,
            lifecycleProvider: lifecycle
        )
    }

    private func makeSampleBundle() -> TrafficalConfigBundle {
        return try! TrafficalBundleDecoder.decode(Data(sampleBundleJSON.utf8))
    }

    private let contextualBundleJSON = """
    {
      "version": "v-ctx",
      "orgId": "org",
      "projectId": "proj",
      "env": "prod",
      "hashing": { "unitKey": "userId", "bucketCount": 1000 },
      "parameters": [
        { "key": "ui.heroVariant", "type": "string", "default": "hero_control", "layerId": "layer_hero", "namespace": "ui" }
      ],
      "layers": [
        {
          "id": "layer_hero",
          "policies": [
            {
              "id": "policy_ctx",
              "state": "running",
              "kind": "adaptive",
              "allocations": [
                { "name": "control", "bucketRange": [0, 499], "overrides": { "ui.heroVariant": "hero_control" } },
                { "name": "bold", "bucketRange": [500, 999], "overrides": { "ui.heroVariant": "hero_bold" } }
              ],
              "conditions": [],
              "stateVersion": "2026-06-30T00:00:00Z",
              "contextualModel": {
                "gamma": 1.0,
                "actionProbabilityFloor": 0.05,
                "defaultAllocationScore": 0,
                "coefficients": {},
                "generatedAt": "2026-07-02T12:00:00Z"
              }
            }
          ]
        }
      ]
    }
    """

    private let sampleBundleJSON = """
    {
      "version": "v",
      "orgId": "org",
      "projectId": "proj",
      "env": "prod",
      "hashing": { "unitKey": "userId", "bucketCount": 1000 },
      "parameters": [
        { "key": "ui.color", "type": "string", "default": "#000000", "layerId": "layer_ui", "namespace": "ui" }
      ],
      "layers": [
        {
          "id": "layer_ui",
          "policies": [
            {
              "id": "policy_ab",
              "state": "running",
              "kind": "static",
              "allocations": [
                { "name": "control", "bucketRange": [0, 499], "overrides": { "ui.color": "#0000FF" } },
                { "name": "treatment", "bucketRange": [500, 999], "overrides": { "ui.color": "#FF0000" } }
              ],
              "conditions": []
            }
          ]
        }
      ]
    }
    """
}
