import XCTest
@testable import Traffical
@testable import TrafficalCore

/// Regression coverage for URL composition. `URL.appendingPathComponent`
/// percent-encodes the entire string, so naive concatenation of a path with
/// a `?query` produces `path%3Fquery` and the server receives the query as
/// part of the path. We split on the first `?` instead.
final class HTTPClientURLTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }

    func test_path_with_query_string_preserves_question_mark() async throws {
        var capturedURL: URL?
        MockURLProtocol.handler = { request in
            capturedURL = request.url
            return .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let client = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk",
            session: MockURLProtocol.session()
        )
        _ = try await client.get(path: "v1/config/proj_abc?env=production")
        XCTAssertEqual(capturedURL?.absoluteString, "https://sdk.test/v1/config/proj_abc?env=production")
        XCTAssertEqual(capturedURL?.path, "/v1/config/proj_abc")
        XCTAssertEqual(capturedURL?.query, "env=production")
    }

    func test_path_without_query_keeps_full_path() async throws {
        var capturedURL: URL?
        MockURLProtocol.handler = { request in
            capturedURL = request.url
            return .init(statusCode: 200, headers: [:], body: Data())
        }
        let client = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk",
            session: MockURLProtocol.session()
        )
        _ = try await client.post(path: "v1/events/batch", body: Data())
        XCTAssertEqual(capturedURL?.absoluteString, "https://sdk.test/v1/events/batch")
    }

    func test_path_with_multiple_query_pairs() async throws {
        var capturedURL: URL?
        MockURLProtocol.handler = { request in
            capturedURL = request.url
            return .init(statusCode: 200, headers: [:], body: Data())
        }
        let client = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk",
            session: MockURLProtocol.session()
        )
        _ = try await client.get(path: "v1/config/proj_abc?env=production&v=2")
        XCTAssertEqual(capturedURL?.query, "env=production&v=2")
    }
}
