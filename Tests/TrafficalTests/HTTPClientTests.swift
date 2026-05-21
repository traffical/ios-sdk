import XCTest
@testable import Traffical
@testable import TrafficalCore

final class HTTPClientTests: XCTestCase {
    override func setUp() { MockURLProtocol.reset() }

    func test_get_sends_auth_and_sdk_headers() async throws {
        MockURLProtocol.handler = { _ in
            .init(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }
        let client = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk_test_123",
            session: MockURLProtocol.session()
        )

        let response = try await client.get(path: "v1/ping")
        XCTAssertEqual(response.statusCode, 200)

        let request = try XCTUnwrap(MockURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer pk_test_123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SDK-Name"), "ios")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-SDK-Version"), trafficalSDKVersion)
    }

    func test_post_sends_body() async throws {
        var capturedBody: Data?
        MockURLProtocol.handler = { request in
            // Stream-based bodies need explicit handling.
            capturedBody = request.httpBody ?? Self.bodyFromStream(request)
            return .init(statusCode: 202, headers: [:], body: Data())
        }
        let client = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk",
            session: MockURLProtocol.session()
        )

        _ = try await client.post(path: "v1/events", body: Data("hello".utf8))
        XCTAssertEqual(capturedBody, Data("hello".utf8))
    }

    func test_transport_failure_surfaces_as_failure() async {
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = TrafficalHTTPClient(
            baseURL: URL(string: "https://sdk.test")!,
            apiKey: "pk",
            session: MockURLProtocol.session()
        )

        do {
            _ = try await client.get(path: "v1/anything")
            XCTFail("expected failure")
        } catch let TrafficalHTTPClient.Failure.transport(err) {
            XCTAssertEqual((err as? URLError)?.code, .notConnectedToInternet)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // URLProtocol delivers POST bodies via stream when the underlying client
    // converts large payloads. For our tests the body is small enough to be
    // attached directly, but we provide a fallback for paranoia.
    private static func bodyFromStream(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
