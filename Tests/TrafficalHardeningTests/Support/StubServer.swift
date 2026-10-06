import Foundation

/// A thread-safe `URLProtocol` stub that answers by endpoint. The hardening
/// suite drives hostile backend behavior through it: malformed bundles,
/// hostile headers, resolve bodies, and event-delivery status codes.
final class StubServer: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data

        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data("{}".utf8)) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        init(status: Int = 200, headers: [String: String] = [:], text: String) {
            self.init(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    struct Request {
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()
    private static var _config: (() -> Reply)?
    private static var _resolve: (() -> Reply)?
    private static var _events: (() -> Reply)?
    private static var _requests: [Request] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _config = nil
        _resolve = nil
        _events = nil
        _requests = []
    }

    static func onConfig(_ reply: @escaping () -> Reply) { lock.lock(); _config = reply; lock.unlock() }
    static func onResolve(_ reply: @escaping () -> Reply) { lock.lock(); _resolve = reply; lock.unlock() }
    static func onEvents(_ reply: @escaping () -> Reply) { lock.lock(); _events = reply; lock.unlock() }

    static var requests: [Request] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    static func requests(matching fragment: String) -> [Request] {
        requests.filter { $0.path.contains(fragment) }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.readBody(request)
        let reply: Reply?
        Self.lock.lock()
        Self._requests.append(Request(path: path, headers: request.allHTTPHeaderFields ?? [:], body: body))
        if path.contains("v1/config") {
            reply = Self._config?()
        } else if path.contains("v1/resolve") || path.contains("v1/decide") {
            reply = Self._resolve?()
        } else if path.contains("v1/events") {
            reply = Self._events?()
        } else {
            reply = nil
        }
        Self.lock.unlock()

        guard let reply = reply,
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
