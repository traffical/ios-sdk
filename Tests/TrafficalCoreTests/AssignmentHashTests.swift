import XCTest
@testable import TrafficalCore

final class AssignmentHashTests: XCTestCase {
    func test_canonical_input_framing() {
        XCTAssertEqual(
            AssignmentHash.input(unitKeyValue: "user-abc", layerId: "layer_ui"),
            "traffical:assignment:v2|u:8:user-abc|l:8:layer_ui"
        )
    }

    func test_frames_length_in_utf8_bytes() {
        // The rocket emoji is 4 UTF-8 bytes; "user-🚀-42" is 12 bytes.
        XCTAssertEqual(
            AssignmentHash.input(unitKeyValue: "user-🚀-42", layerId: "layer_ui"),
            "traffical:assignment:v2|u:12:user-🚀-42|l:8:layer_ui"
        )
    }

    func test_digest_matches_canonical_sha256() {
        let hex = AssignmentHash.digest("abc").map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func test_known_ascii_buckets() {
        // SHA-256 v2 vectors, shared with the JS reference SDK and sdk-spec.
        XCTAssertEqual(computeBucket(unitKeyValue: "user-abc", layerId: "layer_ui", bucketCount: 1000), 177)
        XCTAssertEqual(computeBucket(unitKeyValue: "user-abc", layerId: "layer_pricing", bucketCount: 1000), 902)
        XCTAssertEqual(computeBucket(unitKeyValue: "user-xyz", layerId: "layer_ui", bucketCount: 1000), 443)
        XCTAssertEqual(computeBucket(unitKeyValue: "user-xyz", layerId: "layer_pricing", bucketCount: 1000), 141)
        XCTAssertEqual(computeBucket(unitKeyValue: "user-123", layerId: "layer_ui", bucketCount: 1000), 480)
        XCTAssertEqual(computeBucket(unitKeyValue: "user-123", layerId: "layer_pricing", bucketCount: 1000), 738)
    }

    func test_known_non_ascii_buckets() {
        // Non-ASCII hashes by UTF-8 bytes, matching the JS reference SDK.
        XCTAssertEqual(computeBucket(unitKeyValue: "ユーザー", layerId: "layer_ui", bucketCount: 1000), 693)
        XCTAssertEqual(computeBucket(unitKeyValue: "user-🚀-42", layerId: "layer_ui", bucketCount: 1000), 771)
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
        XCTAssertNotEqual(a, b)
    }

    func test_uniform_is_deterministic_and_in_range() {
        let digest = AssignmentHash.digest("ctx:user-abc:policy_contextual")
        let a = AssignmentHash.uniform(digest)
        let b = AssignmentHash.uniform(digest)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a >= 0.0 && a < 1.0)
    }
}
