import XCTest
@testable import TrafficalCore

final class WeightedSelectionTests: XCTestCase {
    func test_single_weight_returns_zero() {
        XCTAssertEqual(weightedSelection(weights: [1.0], seed: "anything"), 0)
    }

    func test_empty_weights_returns_zero() {
        XCTAssertEqual(weightedSelection(weights: [], seed: "anything"), 0)
    }

    func test_deterministic_for_same_seed() {
        let weights = [0.25, 0.25, 0.25, 0.25]
        let a = weightedSelection(weights: weights, seed: "seed_1")
        let b = weightedSelection(weights: weights, seed: "seed_1")
        XCTAssertEqual(a, b)
    }

    func test_distribution_approximates_weights() {
        let weights = [0.7, 0.2, 0.1]
        var counts = Array(repeating: 0, count: weights.count)
        for i in 0..<10_000 {
            let idx = weightedSelection(weights: weights, seed: "seed_\(i)")
            counts[idx] += 1
        }
        // Allow a generous tolerance — this is a smoke test, not a stats test.
        XCTAssertEqual(Double(counts[0]) / 10_000.0, 0.7, accuracy: 0.05)
        XCTAssertEqual(Double(counts[1]) / 10_000.0, 0.2, accuracy: 0.05)
        XCTAssertEqual(Double(counts[2]) / 10_000.0, 0.1, accuracy: 0.05)
    }
}
