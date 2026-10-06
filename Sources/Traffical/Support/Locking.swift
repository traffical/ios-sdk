import Foundation

extension NSLock {
    /// Runs `body` while holding the lock. A synchronous helper, so it is safe
    /// to call from async contexts (where `lock()`/`unlock()` are discouraged
    /// because a suspension point could separate them).
    @discardableResult
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
