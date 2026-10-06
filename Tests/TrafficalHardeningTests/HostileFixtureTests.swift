import XCTest
import Traffical
import TrafficalCore

/// Runs sdk-spec `hostile_bundles.json` (S11). The overriding assertion is
/// that the process survives; on top of that, accept/reject and the clamping
/// tables must match the spec exactly.
final class HostileFixtureTests: HardeningTestCase {
    private struct Fixture {
        let context: TrafficalContext
        let defaults: [String: TrafficalParameterValue]
        let bundleCases: [[String: Any]]
        let refreshHintCases: [[String: Any]]
        let dynamicCountCases: [[String: Any]]
    }

    private func loadFixture() throws -> Fixture {
        let root = try XCTUnwrap(try Fixtures.load("hostile_bundles.json") as? [String: Any])
        let context = (root["context"] as? [String: Any] ?? [:]).mapValues { TrafficalContextValue.from(any: $0) }
        let defaults = (root["defaults"] as? [String: Any] ?? [:]).mapValues {
            TrafficalParameterValue.from(any: $0, type: inferType(of: $0))
        }
        return Fixture(
            context: context,
            defaults: defaults,
            bundleCases: root["bundleCases"] as? [[String: Any]] ?? [],
            refreshHintCases: root["refreshHintCases"] as? [[String: Any]] ?? [],
            dynamicCountCases: root["dynamicCountCases"] as? [[String: Any]] ?? []
        )
    }

    /// Decode + validate: the ingestion decision every path shares.
    private func accepts(_ json: String) -> TrafficalConfigBundle? {
        guard let bundle = Self.decode(json), TrafficalBundleValidator.validate(bundle) == nil else { return nil }
        return bundle
    }

    func test_bundle_cases_accept_or_reject_as_specified() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.bundleCases.count, 30)
        for c in fixture.bundleCases {
            let name = c["name"] as? String ?? "?"
            let json = c["bundleJson"] as? String ?? ""
            let expectAccept = (c["expect"] as? String) == "accept"
            XCTAssertEqual(accepts(json) != nil, expectAccept, "\(name): expected \(expectAccept ? "accept" : "reject")")
        }
    }

    /// Every case through the real fetch path: initialize, decide, every typed
    /// getter, exposure, a hostile track, flush, close.
    func test_bundle_cases_through_the_network_path() async throws {
        let fixture = try loadFixture()
        for c in fixture.bundleCases {
            let name = c["name"] as? String ?? "?"
            let json = c["bundleJson"] as? String ?? ""
            let expectAccept = (c["expect"] as? String) == "accept"

            StubServer.reset()
            StubServer.onConfig { .init(text: json) }
            StubServer.onEvents { .init() }
            try? FileManager.default.removeItem(at: bundleCacheURL)

            let client = makeClient()
            await client.initialize()
            let decision = client.decide(context: fixture.context, defaults: fixture.defaults)

            if expectAccept {
                XCTAssertNotEqual(decision.metadata.reason, .noBundle, "\(name): accepted bundle must be used")
                if let expected = c["expectedAssignments"] as? [String: Any] {
                    for (key, raw) in expected {
                        let want = TrafficalParameterValue.from(any: raw, type: inferType(of: raw))
                        XCTAssertEqual(decision.assignments[key], want, "\(name): \(key)")
                    }
                }
            } else {
                XCTAssertEqual(decision.metadata.reason, .noBundle, "\(name): rejected bundle must not be used")
                XCTAssertEqual(decision.assignments, fixture.defaults, "\(name): caller defaults")
                XCTAssertEqual(client.getDiagnostics().rejectedBundles + client.getDiagnostics().sideEffectErrors > 0, true,
                               "\(name): the rejection is reported")
            }

            for key in fixture.defaults.keys {
                _ = client.string(key, default: "d", context: fixture.context)
                _ = client.int(key, default: 1, context: fixture.context)
                _ = client.double(key, default: 1, context: fixture.context)
                _ = client.bool(key, default: true, context: fixture.context)
                _ = client.json(key, default: .null, context: fixture.context)
            }
            client.trackExposure(decision)
            client.track("hostile", properties: ["nan": Double.nan], options: .init(value: .infinity))
            await client.flushEvents()
            await client.close()
        }
    }

    /// Accepted cases also through `localConfig` and the disk cache.
    func test_accepted_cases_through_local_config_and_cache() throws {
        let fixture = try loadFixture()
        for c in fixture.bundleCases where (c["expect"] as? String) == "accept" {
            let name = c["name"] as? String ?? "?"
            let json = c["bundleJson"] as? String ?? ""
            let local = try XCTUnwrap(Self.decode(json), name)
            let fromLocal = makeClient(localConfig: local)
            XCTAssertNotEqual(fromLocal.decide(context: fixture.context, defaults: fixture.defaults).metadata.reason, .noBundle, name)

            try Data(json.utf8).write(to: bundleCacheURL)
            let fromCache = makeClient()
            XCTAssertNotEqual(fromCache.decide(context: fixture.context, defaults: fixture.defaults).metadata.reason, .noBundle, name)
        }
    }

    func test_rejected_cases_in_the_disk_cache_are_deleted() throws {
        let fixture = try loadFixture()
        for c in fixture.bundleCases where (c["expect"] as? String) == "reject" {
            let name = c["name"] as? String ?? "?"
            try Data((c["bundleJson"] as? String ?? "").utf8).write(to: bundleCacheURL)
            let client = makeClient()
            XCTAssertEqual(client.decide(context: fixture.context, defaults: fixture.defaults).metadata.reason, .noBundle, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: bundleCacheURL.path), "\(name): cache deleted")
        }
    }

    func test_refresh_hint_cases() async throws {
        let fixture = try loadFixture()
        let http = TrafficalHTTPClient(baseURL: Self.baseURL, apiKey: "pk", session: StubServer.session())
        let fetcher = ConfigFetcher(http: http, projectId: "proj_test", env: "production")
        for c in fixture.refreshHintCases {
            let name = c["name"] as? String ?? "?"
            let input = c["input"] as? String ?? ""
            let expected = c["expectMs"] as? Int
            StubServer.onConfig { .init(headers: ["X-Suggested-Refresh-Ms": input], text: Bundles.baseText) }
            let result = try await fetcher.fetch(etag: nil)
            XCTAssertEqual(result.suggestedRefreshMs, expected, "header \(name)")
            // The resolve-body path uses the same clamp.
            XCTAssertEqual(TrafficalNumeric.refreshHintMs(Double(input)), expected, "body \(name)")
        }
    }

    func test_dynamic_count_cases() throws {
        let fixture = try loadFixture()
        for c in fixture.dynamicCountCases {
            let name = c["name"] as? String ?? "?"
            let value = TrafficalContextValue.from(any: c["value"] is NSNull ? nil : c["value"])
            let expected = c["expectCount"] as? Int
            XCTAssertEqual(dynamicAllocationCount(context: ["n": value], countKey: "n"), expected, name)
        }
    }

    /// Every existing conformance bundle must still pass validation — the new
    /// bounds reject only bundles no control plane emits.
    func test_every_spec_bundle_fixture_is_accepted() throws {
        let names = try Fixtures.bundleFixtureNames()
        XCTAssertGreaterThanOrEqual(names.count, 14)
        for name in names {
            let data = try Data(contentsOf: Fixtures.directory.appendingPathComponent(name))
            let bundle = try TrafficalBundleDecoder.decode(data)
            XCTAssertNil(TrafficalBundleValidator.validate(bundle), name)
        }
    }
}
