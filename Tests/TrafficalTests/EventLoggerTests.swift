import XCTest
@testable import Traffical
@testable import TrafficalCore

final class EventLoggerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        MockURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventLoggerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_flush_posts_events_in_a_single_batch() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            capturedBody = request.httpBody
            return .init(statusCode: 200, headers: [:], body: Data("{\"accepted\":2}".utf8))
        }
        let logger = makeLogger(batchSize: 50, intervalMs: 0)
        logger.log(.track(makeTrackEvent("a")))
        logger.log(.track(makeTrackEvent("b")))
        try await logger.flush()

        let payload = try XCTUnwrap(capturedBody)
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        let events = json?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.count, 2)
        XCTAssertEqual(events?[0]["event"] as? String, "a")
        XCTAssertEqual(events?[1]["event"] as? String, "b")
    }

    func test_flush_persists_failed_batch_and_retries_next_flush() async throws {
        var attempt = 0
        MockURLProtocol.handler = { _ in
            attempt += 1
            if attempt == 1 {
                return .init(statusCode: 500, headers: [:], body: Data())
            }
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        let logger = makeLogger(batchSize: 50, intervalMs: 0)
        logger.log(.track(makeTrackEvent("a")))
        do {
            try await logger.flush()
            XCTFail("expected first flush to throw")
        } catch {
            // expected
        }

        // Second flush should pick up the persisted batch and retry.
        try await logger.flush()
        // After successful retry, the failed-batch file should be gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("failed-events-proj-prod.json").path))
        XCTAssertEqual(attempt, 2)
    }

    func test_batch_size_trigger_flushes_async() async throws {
        let flushExpectation = expectation(description: "flush")
        MockURLProtocol.handler = { _ in
            flushExpectation.fulfill()
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let logger = makeLogger(batchSize: 2, intervalMs: 0)
        logger.log(.track(makeTrackEvent("a")))
        logger.log(.track(makeTrackEvent("b")))
        await fulfillment(of: [flushExpectation], timeout: 2.0)
    }

    func test_background_visibility_triggers_flush() async throws {
        let flushExpectation = expectation(description: "background flush")
        MockURLProtocol.handler = { _ in
            flushExpectation.fulfill()
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let lifecycle = ManualLifecycleProvider()
        let logger = makeLogger(batchSize: 50, intervalMs: 0, lifecycle: lifecycle)
        logger.log(.track(makeTrackEvent("a")))
        lifecycle.emit(.background)
        await fulfillment(of: [flushExpectation], timeout: 2.0)
    }

    // MARK: - Wire shape (sdk-spec events.schema.json)

    func test_exposure_payload_carries_config_version_and_layer_propensity() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            capturedBody = request.httpBody
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let logger = makeLogger(batchSize: 50, intervalMs: 0)
        let exposure = TrafficalExposureEvent(
            base: makeBase(),
            decisionId: "dec_1",
            assignments: ["x": .string("t")],
            layers: [
                TrafficalLayerResolution(
                    layerId: "L",
                    bucket: 42,
                    policyId: "p_ctx",
                    allocationName: "treatment",
                    probability: 0.25,
                    modelVersion: "2026-07-02T12:00:00Z"
                ),
            ],
            configVersion: "v42"
        )
        logger.log(.exposure(exposure))
        try await logger.flush()

        let events = try eventsFrom(capturedBody)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "exposure")
        XCTAssertEqual(events[0]["configVersion"] as? String, "v42")
        let layers = try XCTUnwrap(events[0]["layers"] as? [[String: Any]])
        XCTAssertEqual(layers[0]["probability"] as? Double, 0.25)
        XCTAssertEqual(layers[0]["modelVersion"] as? String, "2026-07-02T12:00:00Z")
    }

    func test_decision_payload_carries_config_version_and_omits_nil_fields() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            capturedBody = request.httpBody
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let logger = makeLogger(batchSize: 50, intervalMs: 0)
        let decision = TrafficalDecisionEvent(
            base: makeBase(),
            assignments: ["x": .string("t")],
            layers: [
                // Static policy: probability/modelVersion stay nil and must be
                // omitted from the wire payload entirely.
                TrafficalLayerResolution(layerId: "L", bucket: 7, policyId: "p_static", allocationName: "control"),
            ],
            configVersion: "v42"
        )
        logger.log(.decision(decision))
        try await logger.flush()

        let events = try eventsFrom(capturedBody)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "decision")
        XCTAssertEqual(events[0]["configVersion"] as? String, "v42")
        let layers = try XCTUnwrap(events[0]["layers"] as? [[String: Any]])
        XCTAssertNil(layers[0]["probability"])
        XCTAssertNil(layers[0]["modelVersion"])
    }

    func test_config_version_omitted_when_nil() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            capturedBody = request.httpBody
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let logger = makeLogger(batchSize: 50, intervalMs: 0)
        let exposure = TrafficalExposureEvent(
            base: makeBase(),
            decisionId: "dec_1",
            assignments: [:],
            layers: []
        )
        logger.log(.exposure(exposure))
        try await logger.flush()

        let events = try eventsFrom(capturedBody)
        XCTAssertNil(events[0]["configVersion"])
    }

    // MARK: - Helpers

    private func makeLogger(batchSize: Int, intervalMs: Int, lifecycle: LifecycleProvider? = nil) -> EventLogger {
        let http = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk",
            session: MockURLProtocol.session()
        )
        return EventLogger(
            http: http,
            projectId: "proj",
            env: "prod",
            lifecycleProvider: lifecycle ?? ManualLifecycleProvider(),
            configuration: EventLogger.Configuration(batchSize: batchSize, flushIntervalMs: intervalMs, maxQueueSize: 100),
            directory: tempDir
        )
    }

    private func makeTrackEvent(_ name: String) -> TrafficalTrackEvent {
        return TrafficalTrackEvent(base: makeBase(), event: name)
    }

    private func makeBase() -> TrafficalBaseEvent {
        return TrafficalBaseEvent(
            id: TrafficalIDGenerator.trackEventId(),
            orgId: "org",
            projectId: "proj",
            env: "prod",
            unitKey: "user",
            timestamp: TrafficalTime.now(),
            sdkName: trafficalSDKName,
            sdkVersion: trafficalSDKVersion
        )
    }

    private func eventsFrom(_ body: Data?) throws -> [[String: Any]] {
        let payload = try XCTUnwrap(body)
        let json = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        return try XCTUnwrap(json?["events"] as? [[String: Any]])
    }
}
