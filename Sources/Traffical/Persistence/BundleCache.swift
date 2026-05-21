import Foundation
import TrafficalCore

/// Persists the most-recently-fetched config bundle to disk in Application
/// Support. Atomic writes via `Data.write(to:options: .atomic)` so a crash
/// mid-write doesn't corrupt the cached file.
public final class BundleCache: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(projectId: String, env: String, directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = directory ?? BundleCache.defaultDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        self.fileURL = base.appendingPathComponent("bundle-\(projectId)-\(env).json")
    }

    public var cacheFileURL: URL { fileURL }

    public func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? data.write(to: fileURL, options: .atomic)
    }

    public func read() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: fileURL)
    }

    public func readBundle() -> TrafficalConfigBundle? {
        guard let data = read() else { return nil }
        return try? TrafficalBundleDecoder.decode(data)
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? fileManager.removeItem(at: fileURL)
    }

    static func defaultDirectory(fileManager: FileManager) -> URL {
        // `applicationSupportDirectory` is the right place for cached state
        // that should persist across launches but is not user-visible.
        if let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return base.appendingPathComponent("Traffical", isDirectory: true)
        }
        return fileManager.temporaryDirectory.appendingPathComponent("Traffical", isDirectory: true)
    }
}
