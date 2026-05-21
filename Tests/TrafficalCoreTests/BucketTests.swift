import XCTest
@testable import TrafficalCore

final class BucketTests: XCTestCase {
    func test_inclusive_range_endpoints() {
        let range = BundleBucketRange(start: 100, end: 200)
        XCTAssertTrue(range.contains(100))
        XCTAssertTrue(range.contains(150))
        XCTAssertTrue(range.contains(200))
        XCTAssertFalse(range.contains(99))
        XCTAssertFalse(range.contains(201))
    }

    func test_find_matching_allocation_returns_first_match() {
        let allocations = [
            BundleAllocation(id: "a", name: "a", bucketRange: BundleBucketRange(start: 0, end: 499), overrides: [:]),
            BundleAllocation(id: "b", name: "b", bucketRange: BundleBucketRange(start: 500, end: 999), overrides: [:]),
        ]
        XCTAssertEqual(findMatchingAllocation(bucket: 250, in: allocations)?.id, "a")
        XCTAssertEqual(findMatchingAllocation(bucket: 750, in: allocations)?.id, "b")
        XCTAssertNil(findMatchingAllocation(bucket: 1000, in: allocations))
    }
}
