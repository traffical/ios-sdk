import XCTest
@testable import Traffical

/// Placeholder test target for Stage 3+. Replaced with networking + persistence
/// tests once those land. Keeps `swift test` happy in the meantime.
final class TrafficalPlaceholderTests: XCTestCase {
    func test_sdk_version_is_set() {
        XCTAssertFalse(SDK_VERSION.isEmpty)
        XCTAssertEqual(SDK_NAME, "ios")
    }
}
