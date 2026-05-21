import XCTest
@testable import Traffical
@testable import TrafficalCore

final class BundleCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BundleCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_round_trip() {
        let cache = BundleCache(projectId: "p", env: "e", directory: tempDir)
        let bundleJSON = sampleBundle()
        cache.write(Data(bundleJSON.utf8))

        let read = cache.readBundle()
        XCTAssertEqual(read?.projectId, "proj_test")
    }

    func test_returns_nil_for_missing_file() {
        let cache = BundleCache(projectId: "missing", env: "e", directory: tempDir)
        XCTAssertNil(cache.readBundle())
    }

    func test_clear_removes_file() {
        let cache = BundleCache(projectId: "p", env: "e", directory: tempDir)
        cache.write(Data(sampleBundle().utf8))
        XCTAssertNotNil(cache.readBundle())
        cache.clear()
        XCTAssertNil(cache.readBundle())
    }

    func test_corrupt_file_yields_nil_bundle() {
        let cache = BundleCache(projectId: "p", env: "e", directory: tempDir)
        cache.write(Data("not json".utf8))
        XCTAssertNil(cache.readBundle())
    }

    private func sampleBundle() -> String {
        return """
        {
          "version": "v",
          "orgId": "org_test",
          "projectId": "proj_test",
          "env": "production",
          "hashing": { "unitKey": "userId", "bucketCount": 1000 },
          "parameters": [],
          "layers": []
        }
        """
    }
}
