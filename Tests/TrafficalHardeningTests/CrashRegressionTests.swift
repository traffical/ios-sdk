import XCTest
import Traffical
import TrafficalCore

/// One test per crash proven against v0.7.0 in release configuration
/// (docs/design/ios-sdk-host-safety-hardening-2026-10.md §1). Each used to
/// terminate the process; each must now degrade and report.
final class CrashRegressionTests: HardeningTestCase {

    // MARK: - #1 NaN / ±Inf reaching JSONSerialization (ObjC exception)

    func test_1a_track_nan_value_serializes_as_null() async {
        StubServer.onEvents { .init() }
        let client = makeClient()
        client.track("purchase", options: .init(value: .nan, values: ["tax": .infinity]))
        await client.flushEvents()

        let track = deliveredEvents().first { $0["type"] as? String == "track" }
        XCTAssertNotNil(track, "the event is delivered, not dropped")
        XCTAssertTrue(track?["value"] is NSNull, "NaN serializes as JSON null")
        XCTAssertTrue((track?["values"] as? [String: Any])?["tax"] is NSNull)
    }

    func test_1b_track_infinite_property() async {
        StubServer.onEvents { .init() }
        let client = makeClient()
        client.track("view", properties: ["price": Double.infinity, "nested": ["x": -Double.infinity]])
        await client.flushEvents()
        XCTAssertEqual(deliveredEvents().count, 1)
    }

    func test_1c_nan_getter_default_rides_the_decision_event() async {
        StubServer.onEvents { .init() }
        let client = makeClient()
        let value = client.double("unknown.param", default: .nan)
        XCTAssertTrue(value.isNaN)
        await client.flushEvents()
    }

    func test_1d_nan_context_in_server_mode() async throws {
        StubServer.onResolve { .init(text: #"{"decisionId":"d","assignments":{},"metadata":{"timestamp":"t","unitKeyValue":"u","layers":[]}}"#) }
        let client = makeClient(mode: .server)
        _ = client.decide(context: ["userId": .string("u"), "score": .number(.nan)], defaults: Bundles.defaults)
        // The background resolve serializes the context.
        try await Task.sleep(nanoseconds: 200_000_000)
        await client.close()
    }

    func test_1e_nan_in_logged_context_field() async {
        StubServer.onConfig { .init(text: Bundles.baseText) }
        StubServer.onEvents { .init() }
        let client = makeClient()
        await client.initialize()
        let decision = client.decide(
            context: ["userId": .string("u1"), "price": .number(.nan), "score": .number(-.infinity)],
            defaults: Bundles.defaults
        )
        client.trackExposure(decision)
        await client.flushEvents()
        XCTAssertFalse(deliveredEvents().isEmpty)
    }

    func test_1f_string_nan_gamma_from_backend() async {
        var bundle = Bundles.baseObject()
        Self.mutateModel(&bundle) { $0["gamma"] = "NaN" }
        StubServer.onConfig { .init(text: Bundles.text(bundle)) }
        let client = makeClient()
        await client.initialize() // persists the bundle to the disk cache
        _ = client.decide(context: ["userId": .string("u1"), "score": .number(0.3)], defaults: Bundles.defaults)
        XCTAssertTrue(client.bundleLoaded)
    }

    func test_1g_string_infinity_entity_weights() async {
        var bundle = Bundles.baseObject()
        bundle["entityState"] = ["pol_entity": [
            "_global": ["entityId": "_global", "weights": ["Infinity", "NaN"], "computedAt": ""],
            "entities": [:],
        ]]
        StubServer.onConfig { .init(text: Bundles.text(bundle)) }
        let client = makeClient()
        await client.initialize()
        _ = client.decide(
            context: ["userId": .string("u1"), "storeId": .string("s1"), "slotCount": .number(2)],
            defaults: Bundles.defaults
        )
    }

    func test_1h_string_nan_probability_in_resolve_response() async throws {
        StubServer.onResolve {
            .init(text: #"{"decisionId":"d","assignments":{"ui.size":3},"metadata":{"timestamp":"t","unitKeyValue":"u","layers":[{"layerId":"l","bucket":1,"policyId":"p","allocationName":"a","probability":"NaN"}]},"suggestedRefreshMs":"NaN"}"#)
        }
        StubServer.onEvents { .init() }
        let client = makeClient(mode: .server)
        await client.initialize() // writes the server cache
        let decision = client.decide(context: [:], defaults: Bundles.defaults)
        client.trackExposure(decision)
        await client.flushEvents()
    }

    func test_1i_overflowing_literal_parameter_default() async {
        var bundle = Bundles.baseObject()
        Self.mutateParameter(&bundle, key: "ui.size") { $0["default"] = Bundles.raw("-1e400") }
        Self.mutateLayer(&bundle, id: "layer_full") { policy in
            policy["allocations"] = [["name": "everyone", "key": "everyone", "bucketRange": [0, 999], "overrides": [:]]]
        }
        StubServer.onConfig { .init(text: Bundles.text(bundle)) }
        StubServer.onEvents { .init() }
        let client = makeClient()
        await client.initialize()
        XCTAssertEqual(client.int("ui.size", default: 7), 7, "a non-representable value returns the caller default")
        await client.flushEvents()
    }

    // MARK: - #2 huge bucketCount: bucket-fold overflow + persisted crash loop

    func test_2_huge_bucket_count_from_network_is_rejected() async {
        var bundle = Bundles.baseObject()
        bundle["hashing"] = ["unitKey": "userId", "bucketCount": Bundles.raw("1e20")]
        StubServer.onConfig { .init(text: Bundles.text(bundle)) }
        let client = makeClient()
        await client.initialize()
        let decision = client.decide(context: ["userId": .string("u1")], defaults: Bundles.defaults)
        XCTAssertEqual(decision.metadata.reason, .noBundle)
        XCTAssertEqual(decision.assignments, Bundles.defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleCacheURL.path), "never persisted")
    }

    func test_2_bucket_count_above_cap_in_disk_cache_is_deleted() throws {
        var bundle = Bundles.baseObject()
        bundle["hashing"] = ["unitKey": "userId", "bucketCount": 72_057_594_037_927_936] // 2^56
        try Data(Bundles.text(bundle).utf8).write(to: bundleCacheURL)

        let client = makeClient()
        let decision = client.decide(context: ["userId": .string("u1")], defaults: Bundles.defaults)
        XCTAssertEqual(decision.metadata.reason, .noBundle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleCacheURL.path), "a rejected cache is deleted")
        XCTAssertEqual(client.getDiagnostics().rejectedBundles, 1)
        XCTAssertTrue(errors.tags().contains("bundleCache"))
    }

    // MARK: - #3 int() getter

    func test_3_int_getter_out_of_range_returns_default_and_reports() {
        var bundle = Bundles.baseObject()
        Self.mutateLayer(&bundle, id: "layer_full") { policy in
            policy["allocations"] = [["name": "everyone", "key": "everyone", "bucketRange": [0, 999],
                                      "overrides": ["ui.size": Bundles.raw("1e20")]]]
        }
        let client = makeClient(localConfig: Self.decodeOrFail(Bundles.text(bundle)))
        XCTAssertEqual(client.int("ui.size", default: 5, context: ["userId": .string("u1")]), 5)
        XCTAssertEqual(client.int("ui.size", default: 5, context: ["userId": .string("u2")]), 5)
        XCTAssertEqual(client.getDiagnostics().resolutionErrors, 2)
        XCTAssertEqual(errors.tags().filter { $0 == "int(ui.size)" }.count, 1, "reported once (deduplicated)")
    }

    func test_3_int_getter_override_infinity() {
        let client = makeClient(localConfig: Self.decodeOrFail(Bundles.baseText))
        client.applyOverrides(["ui.size": .number(-.infinity)])
        XCTAssertEqual(client.int("ui.size", default: 9, context: ["userId": .string("u1")]), 9)
    }

    // MARK: - #4/#5 refresh hints: overflow and hot loop

    func test_4_huge_refresh_header_does_not_overflow() async throws {
        StubServer.onConfig { .init(headers: ["X-Suggested-Refresh-Ms": "1e20"], text: Bundles.baseText) }
        let client = makeClient(refreshIntervalMs: 60_000)
        await client.initialize()
        try await Task.sleep(nanoseconds: 100_000_000) // let the loop compute its sleep
        await client.close()
    }

    func test_4_zero_refresh_header_does_not_hot_loop() async throws {
        StubServer.onConfig { .init(headers: ["X-Suggested-Refresh-Ms": "0"], text: Bundles.baseText) }
        let client = makeClient(refreshIntervalMs: 60_000)
        await client.initialize()
        try await Task.sleep(nanoseconds: 400_000_000)
        await client.close()
        // v0.7.0 issued ~3,000 requests per second here.
        XCTAssertEqual(StubServer.requests(matching: "v1/config").count, 1)
    }

    func test_5_huge_suggested_refresh_in_resolve_body() async throws {
        StubServer.onResolve {
            .init(text: #"{"decisionId":"d","assignments":{},"metadata":{"timestamp":"t","unitKeyValue":"u","layers":[]},"suggestedRefreshMs":1e20}"#)
        }
        let client = makeClient(mode: .server, refreshIntervalMs: 60_000)
        await client.initialize()
        try await Task.sleep(nanoseconds: 100_000_000)
        await client.close()
    }

    // MARK: - #6 dynamic allocation count

    func test_6_dynamic_count_hostile_values_skip_the_policy() {
        let client = makeClient(localConfig: Self.decodeOrFail(Bundles.baseText))
        let hostile: [TrafficalContextValue] = [
            .number(1e19), .number(.infinity), .number(.nan), .number(-1), .number(0),
            .string("inf"), .string("3"), .number(1e7), .number(10_001),
        ]
        for value in hostile {
            let started = Date()
            let decision = client.decide(
                context: ["userId": .string("u1"), "storeId": .string("s1"), "slotCount": value],
                defaults: Bundles.defaults
            )
            let entityLayer = decision.metadata.layers.first { $0.layerId == "layer_entity" }
            XCTAssertNil(entityLayer?.policyId, "\(value) must skip the per-entity policy")
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "\(value) must not allocate per index")
        }
    }

    func test_6_dynamic_count_valid_value_still_resolves() {
        let client = makeClient(localConfig: Self.decodeOrFail(Bundles.baseText))
        let decision = client.decide(
            context: ["userId": .string("u1"), "storeId": .string("s1"), "slotCount": .number(2)],
            defaults: Bundles.defaults
        )
        XCTAssertEqual(decision.metadata.layers.first { $0.layerId == "layer_entity" }?.policyId, "pol_entity")
    }

    // MARK: - #7 bucketCount 0 via localConfig / cache

    func test_7_zero_bucket_count_local_config_is_rejected() {
        var bundle = Bundles.baseObject()
        bundle["hashing"] = ["unitKey": "userId", "bucketCount": 0]
        let local = Self.decodeOrFail(Bundles.text(bundle))
        let client = makeClient(localConfig: local)
        let decision = client.decide(context: ["userId": .string("u1")], defaults: Bundles.defaults)
        XCTAssertEqual(decision.metadata.reason, .noBundle)
        XCTAssertEqual(client.getDiagnostics().rejectedBundles, 1)
        XCTAssertTrue(errors.tags().contains("localConfig"))
    }

    func test_7_zero_bucket_count_in_cache_is_deleted() throws {
        var bundle = Bundles.baseObject()
        bundle["hashing"] = ["unitKey": "userId", "bucketCount": 0]
        try Data(Bundles.text(bundle).utf8).write(to: bundleCacheURL)
        let client = makeClient()
        _ = client.decide(context: ["userId": .string("u1")], defaults: Bundles.defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundleCacheURL.path))
    }

    func test_7_core_bucket_is_total_for_any_modulus() {
        // The engine stays total even if a caller bypasses validation.
        for modulus in [0, -1, Int.min, 1, Int.max] {
            let bucket = computeBucket(unitKeyValue: "u", layerId: "l", bucketCount: modulus)
            XCTAssertGreaterThanOrEqual(bucket, 0)
        }
    }

    // MARK: - #8 bucket-range width overflow

    func test_8_range_end_int_max_is_rejected() {
        var bundle = Bundles.baseObject()
        Self.mutateLayer(&bundle, id: "layer_model") { policy in
            var allocations = policy["allocations"] as? [[String: Any]] ?? []
            allocations[1]["bucketRange"] = [500, Int.max]
            policy["allocations"] = allocations
        }
        let decoded = Self.decodeOrFail(Bundles.text(bundle))
        XCTAssertNotNil(TrafficalBundleValidator.validate(decoded))
        // Core resolution of the unvalidated bundle must still not trap.
        _ = TrafficalCore.decide(bundle: decoded, context: ["userId": .string("u1")], defaults: Bundles.defaults)
    }

    func test_8_range_end_max_safe_integer_resolves() {
        var bundle = Bundles.baseObject()
        Self.mutateLayer(&bundle, id: "layer_model") { policy in
            var allocations = policy["allocations"] as? [[String: Any]] ?? []
            allocations[1]["bucketRange"] = [500, 9_007_199_254_740_991]
            policy["allocations"] = allocations
            policy.removeValue(forKey: "contextualModel") // bucket-share propensity path
        }
        let client = makeClient(localConfig: Self.decodeOrFail(Bundles.text(bundle)))
        for i in 0..<50 {
            _ = client.decide(context: ["userId": .string("u\(i)")], defaults: Bundles.defaults)
        }
        XCTAssertEqual(client.getDiagnostics().rejectedBundles, 0)
    }

    // MARK: - #9 re-entrant assignment logger

    func test_9_reentrant_logger_without_dedup_does_not_recurse() {
        final class Box: @unchecked Sendable { weak var client: TrafficalClient?; var calls = 0 }
        let box = Box()
        let client = makeClient(
            localConfig: Self.decodeOrFail(Bundles.baseText),
            deduplicateAssignmentLogger: false,
            assignmentLogger: { _ in
                box.calls += 1
                _ = box.client?.getParams(context: ["userId": .string("u1")], defaults: Bundles.defaults)
            }
        )
        box.client = client
        _ = client.decide(context: ["userId": .string("u1")], defaults: Bundles.defaults)
        XCTAssertGreaterThan(box.calls, 0)
        XCTAssertLessThan(box.calls, 100, "nested emission is suppressed")
    }

    // MARK: - #10 lifecycle races

    func test_10_concurrent_initialize_and_close() async {
        StubServer.onConfig { .init(text: Bundles.baseText) }
        let client = makeClient(refreshIntervalMs: 60_000)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask {
                    if i % 3 == 0 { await client.close() } else { await client.initialize() }
                }
            }
        }
        await client.close()
        XCTAssertTrue(client.isInitialized)
    }

    func test_10_failed_first_fetch_still_initializes_and_reports() async {
        // No config stub: the transport fails.
        let client = makeClient()
        await client.initialize()
        XCTAssertTrue(client.isInitialized, "fail-open: initialized even when offline")
        XCTAssertTrue(errors.tags().contains("initialize"))
        XCTAssertGreaterThanOrEqual(client.getDiagnostics().sideEffectErrors, 1)
    }

    // MARK: - Helpers

    static func decodeOrFail(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> TrafficalConfigBundle {
        guard let bundle = decode(json) else {
            XCTFail("fixture bundle did not decode", file: file, line: line)
            return TrafficalConfigBundle(
                version: "", orgId: "", projectId: "", env: "",
                hashing: BundleHashingConfig(unitKey: "userId", bucketCount: 1000),
                parameters: [], layers: []
            )
        }
        return bundle
    }

    static func mutateLayer(_ bundle: inout [String: Any], id: String, _ body: (inout [String: Any]) -> Void) {
        guard var layers = bundle["layers"] as? [[String: Any]],
              let index = layers.firstIndex(where: { $0["id"] as? String == id }),
              var policies = layers[index]["policies"] as? [[String: Any]], !policies.isEmpty else { return }
        body(&policies[0])
        layers[index]["policies"] = policies
        bundle["layers"] = layers
    }

    static func mutateModel(_ bundle: inout [String: Any], _ body: @escaping (inout [String: Any]) -> Void) {
        mutateLayer(&bundle, id: "layer_model") { policy in
            var model = policy["contextualModel"] as? [String: Any] ?? [:]
            body(&model)
            policy["contextualModel"] = model
        }
    }

    static func mutateParameter(_ bundle: inout [String: Any], key: String, _ body: (inout [String: Any]) -> Void) {
        guard var params = bundle["parameters"] as? [[String: Any]],
              let index = params.firstIndex(where: { $0["key"] as? String == key }) else { return }
        body(&params[index])
        bundle["parameters"] = params
    }
}
