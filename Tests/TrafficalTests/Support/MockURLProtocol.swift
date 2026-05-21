import Foundation

/// Test-only `URLProtocol` that intercepts every request and replies with a
/// pre-programmed response. Replaces third-party HTTP stubbing libraries —
/// keeps the SDK dependency-free.
final class MockURLProtocol: URLProtocol {
    struct StubResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    /// Set by a test before exercising a code path that issues a request.
    /// The closure receives the request and returns the response to send back.
    static var handler: ((URLRequest) throws -> StubResponse)?

    /// Captured requests, in order. Tests inspect this to assert request
    /// shape (method, headers, body).
    static var requests: [URLRequest] = []

    static func reset() {
        handler = nil
        requests = []
    }

    static func session(configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        let config = configuration
        config.protocolClasses = [MockURLProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.requests.append(request)
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let response = try handler(request)
            let url = request.url ?? URL(string: "https://example.invalid")!
            let urlResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            )!
            client?.urlProtocol(self, didReceive: urlResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
