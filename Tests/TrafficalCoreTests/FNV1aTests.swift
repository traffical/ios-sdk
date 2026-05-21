import XCTest
@testable import TrafficalCore

final class FNV1aTests: XCTestCase {
    func test_empty_string_returns_offset_basis() {
        XCTAssertEqual(fnv1a(""), 2_166_136_261)
    }

    func test_known_vector_from_fixture() {
        // From sdk-spec/test-vectors/fixtures/expected_basic.json:
        //   user-abc -> layer_ui -> bucket 551
        // (The sdk-spec README example shows different numbers; the fixture is
        // the authoritative source.)
        XCTAssertEqual(
            computeBucket(unitKeyValue: "user-abc", layerId: "layer_ui", bucketCount: 1000),
            551
        )
        XCTAssertEqual(
            computeBucket(unitKeyValue: "user-abc", layerId: "layer_pricing", bucketCount: 1000),
            913
        )
        XCTAssertEqual(
            computeBucket(unitKeyValue: "user-xyz", layerId: "layer_ui", bucketCount: 1000),
            214
        )
    }

    func test_bucket_is_within_bounds() {
        for i in 0..<1000 {
            let bucket = computeBucket(unitKeyValue: "user_\(i)", layerId: "layer_x", bucketCount: 10_000)
            XCTAssertTrue(bucket >= 0 && bucket < 10_000, "bucket \(bucket) out of range")
        }
    }

    func test_bucket_is_deterministic() {
        let a = computeBucket(unitKeyValue: "user_42", layerId: "layer_y", bucketCount: 10_000)
        let b = computeBucket(unitKeyValue: "user_42", layerId: "layer_y", bucketCount: 10_000)
        XCTAssertEqual(a, b)
    }

    func test_bucket_differs_across_layers() {
        let a = computeBucket(unitKeyValue: "user_42", layerId: "layer_a", bucketCount: 10_000)
        let b = computeBucket(unitKeyValue: "user_42", layerId: "layer_b", bucketCount: 10_000)
        // It's allowed (rare) for two layers to land on the same bucket for the
        // same user — but the layers in this test are distinct enough that
        // collisions would indicate a bug in the hash.
        XCTAssertNotEqual(a, b)
    }
}
