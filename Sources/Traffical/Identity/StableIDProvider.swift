import Foundation

/// Stable anonymous user identifier.
///
/// Generated on first launch, persisted in the Keychain so it survives app
/// reinstall (matches what real analytics SDKs do). Callers can override via
/// `setID(_:)` once the user logs in.
public final class StableIDProvider: @unchecked Sendable {
    private static let keychainKey = "stableID"

    private let keychain: KeychainStoreProtocol
    private let generator: () -> String
    private var cached: String?
    private let lock = NSLock()

    public init(keychain: KeychainStoreProtocol = KeychainStore(), generator: @escaping () -> String = { UUID().uuidString }) {
        self.keychain = keychain
        self.generator = generator
    }

    public func getID() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cached = cached { return cached }
        if let existing = keychain.string(forKey: Self.keychainKey) {
            cached = existing
            return existing
        }
        let fresh = generator()
        keychain.setString(fresh, forKey: Self.keychainKey)
        cached = fresh
        return fresh
    }

    public func setID(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        keychain.setString(id, forKey: Self.keychainKey)
        cached = id
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        keychain.remove(forKey: Self.keychainKey)
        cached = nil
    }
}
