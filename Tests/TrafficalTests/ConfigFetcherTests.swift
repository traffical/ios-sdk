import XCTest
@testable import Traffical
@testable import TrafficalCore

final class ConfigFetcherTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }

    private let bundleJSON = """
    {
      "version": "2026-05-21T00:00:00Z",
      "orgId": "org_test",
      "projectId": "proj_test",
      "env": "production",
      "hashing": { "unitKey": "userId", "bucketCount": 1000 },
      "parameters": [],
      "layers": []
    }
    """

    func test_200_response_decodes_bundle_and_captures_etag() async throws {
        MockURLProtocol.handler = { _ in
            .init(
                statusCode: 200,
                headers: ["ETag": "\"v1\""],
                body: Data(self.bundleJSON.utf8)
            )
        }
        let fetcher = makeFetcher()
        let result = try await fetcher.fetch(etag: nil)
        XCTAssertNotNil(result.bundle)
        XCTAssertEqual(result.bundle?.projectId, "proj_test")
        XCTAssertEqual(result.etag, "\"v1\"")
        XCTAssertFalse(result.notModified)
    }

    func test_304_response_returns_not_modified() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "If-None-Match"), "\"v1\"")
            return .init(statusCode: 304, headers: [:], body: Data())
        }
        let fetcher = makeFetcher()
        let result = try await fetcher.fetch(etag: "\"v1\"")
        XCTAssertNil(result.bundle)
        XCTAssertTrue(result.notModified)
        XCTAssertEqual(result.etag, "\"v1\"")
    }

    func test_500_response_throws_http_failure() async {
        MockURLProtocol.handler = { _ in
            .init(statusCode: 500, headers: [:], body: Data())
        }
        let fetcher = makeFetcher()
        do {
            _ = try await fetcher.fetch(etag: nil)
            XCTFail("expected failure")
        } catch let ConfigFetcher.Failure.http(code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_invalid_json_throws_decode_failure() async {
        MockURLProtocol.handler = { _ in
            .init(statusCode: 200, headers: [:], body: Data("not json".utf8))
        }
        let fetcher = makeFetcher()
        do {
            _ = try await fetcher.fetch(etag: nil)
            XCTFail("expected failure")
        } catch ConfigFetcher.Failure.decode {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_config_timeout_is_applied_to_request() async throws {
        MockURLProtocol.handler = { _ in
            .init(statusCode: 200, headers: [:], body: Data(self.bundleJSON.utf8))
        }
        let fetcher = makeFetcher(configTimeoutMs: 3_000)
        _ = try await fetcher.fetch(etag: nil)
        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.timeoutInterval, 3.0, accuracy: 0.001)
    }

    private func makeFetcher(configTimeoutMs: Int = 10_000) -> ConfigFetcher {
        let http = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk",
            session: MockURLProtocol.session()
        )
        return ConfigFetcher(http: http, projectId: "proj_test", env: "production", configTimeoutMs: configTimeoutMs)
    }
}
