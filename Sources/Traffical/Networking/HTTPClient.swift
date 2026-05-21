import Foundation

/// Thin async/await wrapper around `URLSession`.
///
/// Exists so we can route every SDK network call through a single seam that
/// tests can stub via a custom `URLProtocol`.
public final class TrafficalHTTPClient: @unchecked Sendable {
    public struct Response {
        public let statusCode: Int
        public let data: Data
        public let headers: [String: String]
    }

    public enum Failure: Error, CustomStringConvertible {
        case transport(Error)
        case invalidResponse

        public var description: String {
            switch self {
            case .transport(let err): return "transport error: \(err.localizedDescription)"
            case .invalidResponse: return "invalid response"
            }
        }
    }

    public let session: URLSession
    public let baseURL: URL
    public let apiKey: String
    public let debugLogger: TrafficalDebugLogger?

    public init(baseURL: URL, apiKey: String, session: URLSession? = nil, debugLogger: TrafficalDebugLogger? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.debugLogger = debugLogger
    }

    public func get(path: String, headers: [String: String] = [:]) async throws -> Response {
        return try await send(method: "GET", path: path, headers: headers, body: nil)
    }

    public func post(path: String, headers: [String: String] = [:], body: Data) async throws -> Response {
        return try await send(method: "POST", path: path, headers: headers, body: body)
    }

    private func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> Response {
        let url = composeURL(base: baseURL, path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(trafficalSDKName, forHTTPHeaderField: "X-SDK-Name")
        request.setValue(trafficalSDKVersion, forHTTPHeaderField: "X-SDK-Version")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body = body { request.httpBody = body }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            log(method: method, urlString: url.absoluteString, status: nil, error: error.localizedDescription)
            throw Failure.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            log(method: method, urlString: url.absoluteString, status: nil, error: "invalid response")
            throw Failure.invalidResponse
        }
        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headerMap[k] = v }
        }
        log(method: method, urlString: url.absoluteString, status: http.statusCode, error: nil)
        return Response(statusCode: http.statusCode, data: data, headers: headerMap)
    }

    /// Joins `baseURL` with a path that may include a `?query`. `URL.appending
    /// PathComponent` percent-encodes the entire string so a `?` becomes `%3F`
    /// and the query is treated as a path segment. We split on the first `?`
    /// instead, append the path part properly, then set the query on the
    /// resulting `URLComponents`.
    func composeURL(base: URL, path: String) -> URL {
        let pathPart: String
        let queryPart: String?
        if let q = path.firstIndex(of: "?") {
            pathPart = String(path[..<q])
            queryPart = String(path[path.index(after: q)...])
        } else {
            pathPart = path
            queryPart = nil
        }
        let withPath = base.appendingPathComponent(pathPart)
        guard let queryPart = queryPart,
              var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false) else {
            return withPath
        }
        components.query = queryPart
        return components.url ?? withPath
    }

    private func log(method: String, urlString: String, status: Int?, error: String?) {
        guard let debugLogger = debugLogger else { return }
        let level: TrafficalDebugEvent.Level
        let message: String
        if let error = error {
            level = .error
            message = "\(method) \(urlString) — \(error)"
        } else if let status = status {
            level = (200..<400).contains(status) ? .info : .warn
            message = "\(method) \(urlString) → \(status)"
        } else {
            level = .warn
            message = "\(method) \(urlString) — no response"
        }
        var details: [String: String] = ["method": method, "url": urlString]
        if let status = status { details["status"] = String(status) }
        if let error = error { details["error"] = error }
        debugLogger(TrafficalDebugEvent(category: .http, level: level, message: message, details: details))
    }
}
