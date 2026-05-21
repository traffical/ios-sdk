import XCTest
@testable import Traffical
@testable import TrafficalCore

final class ServerResponseCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func test_round_trip() {
        let cache = ServerResponseCache(projectId: "p", env: "e", directory: tempDir)
        let payload = """
        {
          "decisionId": "dec_456",
          "assignments": { "ui.color": "#0000FF" },
          "metadata": {
            "timestamp": "2026-05-21T00:00:00Z",
            "unitKeyValue": "user-abc",
            "layers": []
          },
          "stateVersion": "v1"
        }
        """
        cache.write(Data(payload.utf8))
        let read = cache.read()
        XCTAssertEqual(read?.decisionId, "dec_456")
        XCTAssertEqual(read?.assignments["ui.color"], .string("#0000FF"))
        XCTAssertEqual(read?.stateVersion, "v1")
    }
}
