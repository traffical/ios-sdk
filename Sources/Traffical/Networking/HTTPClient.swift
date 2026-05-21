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

    public init(baseURL: URL, apiKey: String, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session ?? URLSession(configuration: .ephemeral)
    }

    public func get(path: String, headers: [String: String] = [:]) async throws -> Response {
        return try await send(method: "GET", path: path, headers: headers, body: nil)
    }

    public func post(path: String, headers: [String: String] = [:], body: Data) async throws -> Response {
        return try await send(method: "POST", path: path, headers: headers, body: body)
    }

    private func send(method: String, path: String, headers: [String: String], body: Data?) async throws -> Response {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(SDK_NAME, forHTTPHeaderField: "X-SDK-Name")
        request.setValue(SDK_VERSION, forHTTPHeaderField: "X-SDK-Version")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body = body { request.httpBody = body }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.transport(error)
        }

        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        var headerMap: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headerMap[k] = v }
        }
        return Response(statusCode: http.statusCode, data: data, headers: headerMap)
    }
}
