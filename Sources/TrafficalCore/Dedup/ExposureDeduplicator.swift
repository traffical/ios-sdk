import Foundation

/// Per-process exposure deduplication.
///
/// Mirrors `@traffical/js-client`'s `ExposureDeduplicator`: keyed on
/// `unitKey:policyId:allocationName`, with a TTL so identity changes or long
/// sessions don't silently swallow exposures.
public final class ExposureDeduplicator: @unchecked Sendable {
    private struct Entry {
        let expiresAt: Date
    }

    private let ttl: TimeInterval
    private var store: [String: Entry] = [:]
    private let lock = NSLock()

    public init(ttl: TimeInterval = 24 * 60 * 60) {
        self.ttl = ttl
    }

    /// Returns `true` if this exposure is new (and marks it). Returns `false`
    /// if we've already seen the same unit + policy + allocation within TTL.
    public func checkAndMark(unitKey: String, policyId: String, allocationName: String) -> Bool {
        let key = "\(unitKey):\(policyId):\(allocationName)"
        let now = Date()

        lock.lock()
        defer { lock.unlock() }

        if let existing = store[key], existing.expiresAt > now {
            return false
        }
        store[key] = Entry(expiresAt: now.addingTimeInterval(ttl))
        return true
    }

    /// Clear all dedup state. Called on identity change.
    public func clear() {
        lock.lock()
        store.removeAll()
        lock.unlock()
    }
}
