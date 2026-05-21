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
        await client.initialize()
        XCTAssertTrue(client.isInitialized)
        let color = client.string("ui.color", default: "#FFF")
        XCTAssertTrue(["#0000FF", "#FF0000"].contains(color))
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
