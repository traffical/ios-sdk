import Foundation
import TrafficalCore

/// Fetches and caches the config bundle from `/v1/config/:projectId?env=`.
///
/// Honors ETag for conditional requests — when the server returns `304 Not
/// Modified` we keep the previously-cached bundle and just update timing.
public final class ConfigFetcher: @unchecked Sendable {
    public struct Result {
        public let bundle: TrafficalConfigBundle?
        public let etag: String?
        public let notModified: Bool
    }

    public enum Failure: Error, CustomStringConvertible {
        case http(Int)
        case decode(Error)
        case transport(Error)

        public var description: String {
            switch self {
            case .http(let code): return "config fetch returned HTTP \(code)"
            case .decode(let err): return "config decode failed: \(err)"
            case .transport(let err): return "config transport failed: \(err)"
            }
        }
    }

    private let http: TrafficalHTTPClient
    private let projectId: String
    private let env: String

    public init(http: TrafficalHTTPClient, projectId: String, env: String) {
        self.http = http
        self.projectId = projectId
        self.env = env
    }

    public func fetch(etag: String?) async throws -> Result {
        var headers: [String: String] = [:]
        if let etag = etag { headers["If-None-Match"] = etag }

        let path = "v1/config/\(projectId)?env=\(env)"
        let response: TrafficalHTTPClient.Response
        do {
            response = try await http.get(path: path, headers: headers)
        } catch let failure as TrafficalHTTPClient.Failure {
            switch failure {
            case .transport(let err): throw Failure.transport(err)
            case .invalidResponse: throw Failure.http(0)
            }
        }

        if response.statusCode == 304 {
            return Result(bundle: nil, etag: etag, notModified: true)
        }

        guard (200..<300).contains(response.statusCode) else {
            throw Failure.http(response.statusCode)
        }

        let bundle: TrafficalConfigBundle
        do {
            bundle = try TrafficalBundleDecoder.decode(response.data)
        } catch {
            throw Failure.decode(error)
        }

        let newEtag = headerValue(response.headers, "ETag") ?? headerValue(response.headers, "Etag")
        return Result(bundle: bundle, etag: newEtag, notModified: false)
    }
}

private func headerValue(_ headers: [String: String], _ key: String) -> String? {
    if let v = headers[key] { return v }
    // Case-insensitive fallback.
    for (k, v) in headers where k.caseInsensitiveCompare(key) == .orderedSame {
        return v
    }
    return nil
}
