import Foundation

/// Light wrapper around `UserDefaults` for SDK metadata (etag, last-fetch time,
/// dedup snapshots). Uses a namespaced suite name so tests can pass in an
/// ephemeral store without bleeding into the host app.
public final class DefaultsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    public init(suiteName: String = "io.traffical.sdk", prefix: String = "traffical.") {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.prefix = prefix
    }

    /// Injection seam used by tests.
    public init(defaults: UserDefaults, prefix: String = "traffical.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func string(forKey key: String) -> String? {
        return defaults.string(forKey: prefix + key)
    }

    public func setString(_ value: String?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: prefix + key)
        } else {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    public func double(forKey key: String) -> Double? {
        let key = prefix + key
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.double(forKey: key)
    }

    public func setDouble(_ value: Double?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: prefix + key)
        } else {
            defaults.removeObject(forKey: prefix + key)
        }
    }

    public func remove(forKey key: String) {
        defaults.removeObject(forKey: prefix + key)
    }
}
