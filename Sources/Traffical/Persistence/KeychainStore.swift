import Foundation
import Security

/// Protocol so tests can substitute an in-memory keychain. The default
/// implementation reads/writes the real iOS keychain.
public protocol KeychainStoreProtocol: AnyObject, Sendable {
    func string(forKey key: String) -> String?
    func setString(_ value: String, forKey key: String)
    func remove(forKey key: String)
}

/// Real keychain-backed store. The stable user ID lives here so it survives
/// app uninstall/reinstall — matching what most analytics SDKs do.
public final class KeychainStore: KeychainStoreProtocol, @unchecked Sendable {
    public let service: String

    public init(service: String = "io.traffical.sdk") {
        self.service = service
    }

    public func string(forKey key: String) -> String? {
        var query: [String: Any] = baseQuery(account: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setString(_ value: String, forKey key: String) {
        let data = Data(value.utf8)
        let query = baseQuery(account: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    public func remove(forKey key: String) {
        let query = baseQuery(account: key)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Pure in-memory keychain — useful for unit tests and ephemeral sessions
/// (e.g. running on Linux for the core conformance suite).
public final class InMemoryKeychainStore: KeychainStoreProtocol, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func string(forKey key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }
    public func setString(_ value: String, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        store[key] = value
    }
    public func remove(forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
    }
}
