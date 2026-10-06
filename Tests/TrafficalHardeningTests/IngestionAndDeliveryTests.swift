import XCTest
import Traffical
import TrafficalCore

/// Validation at every ingestion point (S8/S11), the S8 source order, and the
/// bounded event pipeline.
final class IngestionAndDeliveryTests: HardeningTestCase {

    // MARK: - Ingestion order and ETag

    func test_disk_cache_wins_over_local_config() throws {
        // Last-good cache: full-range layer sets ui.size = 2.
        try Data(Bundles.baseText.utf8).write(to: bundleCacheURL)
        // localConfig: same bundle but ui.size override 99.
        var local = Bundles.baseObject()
        CrashRegressionTests.mutateLayer(&local, id: "layer_full") { policy in
            policy["allocations"] = [["name": "everyone", "key": "everyone", "bucketRange": [0, 999], "overrides": ["ui.size": 99]]]
        }
        let client = makeClient(localConfig: CrashRegressionTests.decodeOrFail(Bundles.text(local)))
        XCTAssertEqual(client.int("ui.size", default: 0, context: ["userId": .string("u1")]), 2, "S8: cache before localConfig")
    }

    func test_local_config_does_not_send_stale_etag() async throws {
        // A previous session stored an ETag for a cache that is now gone.
        UserDefaults(suiteName: "io.traffical.sdk")?.set("\"stale\"", forKey: "etag-proj_test-production")
        defer { UserDefaults(suiteName: "io.traffical.sdk")?.removeObject(forKey: "etag-proj_test-production") }
        StubServer.onConfig { .init(text: Bundles.baseText) }

        let client = makeClient(localConfig: CrashRegressionTests.decodeOrFail(Bundles.baseText))
        await client.initialize()
        let request = StubServer.requests(matching: "v1/config").first
        XCTAssertNil(request?.headers["If-None-Match"], "a 304 must not pin the build-time bundle")
    }

    func test_undecodable_cache_file_is_deleted() throws {
        try Data("{\"truncated\": ".utf8).write(to: bundleCacheURL)
        let client = makeClient()
        _ = client.decide(context: [:], defaults: Bundles.defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleCacheURL.path))
        XCTAssertEqual(client.getDiagnostics().rejectedBundles, 1)
    }

    func test_rejected_fetch_keeps_last_good() async {
        var bad = Bundles.baseObject()
        bad["hashing"] = ["unitKey": "", "bucketCount": 1000]
        var call = 0
        StubServer.onConfig {
            call += 1
            return call == 1 ? .init(text: Bundles.baseText) : .init(text: Bundles.text(bad))
        }
        let client = makeClient()
        await client.initialize()
        try? await client.refreshConfig()
        XCTAssertEqual(client.int("ui.size", default: 0, context: ["userId": .string("u1")]), 2)
        XCTAssertEqual(client.getDiagnostics().rejectedBundles, 1)
        XCTAssertTrue(errors.reports.contains { $0.tag == "fetchConfig" && $0.message.contains("hashing.unitKey") })
    }

    func test_reason_is_reported_on_every_decision() {
        let empty = makeClient()
        XCTAssertEqual(empty.decide(context: [:], defaults: Bundles.defaults).metadata.reason, .noBundle)

        let client = makeClient(localConfig: CrashRegressionTests.decodeOrFail(Bundles.baseText))
        XCTAssertEqual(client.decide(context: ["userId": .string("u1")], defaults: Bundles.defaults).metadata.reason, .resolved)
        // No unit key: every layer is skipped.
        XCTAssertEqual(client.decide(context: ["userId": .null], defaults: Bundles.defaults).metadata.reason, .default)
    }

    func test_unknown_policy_state_is_inactive() {
        var bundle = Bundles.baseObject()
        CrashRegressionTests.mutateLayer(&bundle, id: "layer_full") { $0["state"] = "archived_v2" }
        let client = makeClient(localConfig: CrashRegressionTests.decodeOrFail(Bundles.text(bundle)))
        XCTAssertEqual(client.int("ui.size", default: 0, context: ["userId": .string("u1")]), 1, "falls back to the parameter default")
    }

    // MARK: - Event pipeline bounds

    func test_permanent_4xx_is_dropped_not_retried() async {
        StubServer.onEvents { .init(status: 400) }
        let client = makeClient()
        client.track("a")
        await client.flushEvents()
        StubServer.onEvents { .init() }
        await client.flushEvents()
        XCTAssertEqual(StubServer.requests(matching: "v1/events").count, 1, "the poison batch is not resent")
        XCTAssertEqual(client.getDiagnostics().droppedEvents, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedEventsURL.path))
    }

    func test_429_is_retried() async {
        StubServer.onEvents { .init(status: 429) }
        let client = makeClient()
        client.track("a")
        await client.flushEvents()
        StubServer.onEvents { .init() }
        await client.flushEvents()
        XCTAssertEqual(StubServer.requests(matching: "v1/events").count, 2)
        XCTAssertEqual(deliveredEvents().filter { $0["event"] as? String == "a" }.count, 2)
    }

    func test_persisted_backlog_is_bounded_and_chunked() async throws {
        let events = (0..<2_000).map { i -> [String: Any] in
            ["type": "track", "event": "e\(i)", "orgId": "o", "projectId": "p", "env": "e", "unitKey": "u", "timestamp": "t"]
        }
        try JSONSerialization.data(withJSONObject: events).write(to: failedEventsURL)
        StubServer.onEvents { .init() }
        let client = makeClient()
        await client.flushEvents()

        let batches = StubServer.requests(matching: "v1/events")
        let sizes = batches.compactMap { request -> Int? in
            ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])
                .flatMap { $0["events"] as? [Any] }?.count
        }
        XCTAssertEqual(sizes.reduce(0, +), 500, "bounded to maxQueueSize, newest kept")
        XCTAssertTrue(sizes.allSatisfy { $0 <= 100 }, "delivered in chunks: \(sizes)")
        XCTAssertEqual(client.getDiagnostics().droppedEvents, 1_500)
        XCTAssertEqual(deliveredEvents().last?["event"] as? String, "e1999")
    }

    func test_oversized_backlog_file_is_discarded_unread() async throws {
        let big = Data(repeating: UInt8(ascii: " "), count: 6 * 1024 * 1024)
        try big.write(to: failedEventsURL)
        StubServer.onEvents { .init() }
        let client = makeClient()
        client.track("fresh")
        await client.flushEvents()
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedEventsURL.path))
        XCTAssertEqual(deliveredEvents().map { $0["event"] as? String }, ["fresh"])
    }

    func test_concurrent_flushes_do_not_double_send() async {
        StubServer.onEvents { .init() }
        let client = makeClient()
        for i in 0..<20 { client.track("e\(i)") }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await client.flushEvents() } }
        }
        let names = deliveredEvents().compactMap { $0["event"] as? String }
        XCTAssertEqual(names.count, 20)
        XCTAssertEqual(Set(names).count, 20, "no event delivered twice")
    }
}
