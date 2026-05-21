import Foundation
import TrafficalCore

/// Persists the latest `/v1/resolve` response to disk so the SDK can render
/// previous-session assignments synchronously while a fresh fetch is in
/// flight.
public final class ServerResponseCache: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(projectId: String, env: String, directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = directory ?? BundleCache.defaultDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("server-resolve-\(projectId)-\(env).json")
    }

    public var cacheFileURL: URL { fileURL }

    public func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func read() -> ServerResolveResponse? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decodeServerResolveResponse(data)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL)
    }
}
