import XCTest
@testable import Traffical

final class DefaultsStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        // Use an isolated suite so we don't pollute the test runner's
        // standardUserDefaults.
        let suite = "DefaultsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        defaults.dictionaryRepresentation().keys.forEach { defaults.removeObject(forKey: $0) }
    }

    func test_round_trip_string() {
        let store = DefaultsStore(defaults: defaults)
        XCTAssertNil(store.string(forKey: "etag"))
        store.setString("\"v1\"", forKey: "etag")
        XCTAssertEqual(store.string(forKey: "etag"), "\"v1\"")
    }

    func test_remove_clears_value() {
        let store = DefaultsStore(defaults: defaults)
        store.setString("x", forKey: "k")
        store.remove(forKey: "k")
        XCTAssertNil(store.string(forKey: "k"))
    }

    func test_round_trip_double() {
        let store = DefaultsStore(defaults: defaults)
        XCTAssertNil(store.double(forKey: "lastFetch"))
        store.setDouble(123.45, forKey: "lastFetch")
        XCTAssertEqual(store.double(forKey: "lastFetch"), 123.45)
    }
}
