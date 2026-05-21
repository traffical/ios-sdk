import XCTest
@testable import Traffical

final class StableIDProviderTests: XCTestCase {
    func test_generates_id_on_first_access_and_persists() {
        let keychain = InMemoryKeychainStore()
        let provider = StableIDProvider(keychain: keychain, generator: { "uuid-1" })
        XCTAssertEqual(provider.getID(), "uuid-1")
        XCTAssertEqual(keychain.string(forKey: "stableID"), "uuid-1")
    }

    func test_returns_existing_id_on_subsequent_access() {
        let keychain = InMemoryKeychainStore()
        keychain.setString("existing-uuid", forKey: "stableID")
        let provider = StableIDProvider(keychain: keychain, generator: { "new-uuid" })
        XCTAssertEqual(provider.getID(), "existing-uuid")
    }

    func test_setID_overwrites_keychain() {
        let keychain = InMemoryKeychainStore()
        let provider = StableIDProvider(keychain: keychain, generator: { "uuid-1" })
        _ = provider.getID()
        provider.setID("user_logged_in_42")
        XCTAssertEqual(provider.getID(), "user_logged_in_42")
        XCTAssertEqual(keychain.string(forKey: "stableID"), "user_logged_in_42")
    }

    func test_clear_resets_provider_and_keychain() {
        let keychain = InMemoryKeychainStore()
        var nextId = 0
        let provider = StableIDProvider(keychain: keychain, generator: {
            nextId += 1
            return "uuid-\(nextId)"
        })
        XCTAssertEqual(provider.getID(), "uuid-1")
        provider.clear()
        XCTAssertEqual(provider.getID(), "uuid-2")
    }
}
