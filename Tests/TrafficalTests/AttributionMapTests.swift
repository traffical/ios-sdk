import XCTest
@testable import Traffical
@testable import TrafficalCore

final class AttributionMapTests: XCTestCase {
    func test_records_layers_from_a_decision() {
        let map = AttributionMap()
        map.record(decision: decision(unit: "u1", policies: [("l1", "p1", "control"), ("l2", "p2", "treatment")]))
        let attrs = map.attribution(for: "u1").sorted { $0.policyId < $1.policyId }
        XCTAssertEqual(attrs.count, 2)
        XCTAssertEqual(attrs[0].policyId, "p1")
        XCTAssertEqual(attrs[1].allocationName, "treatment")
    }

    func test_last_write_wins_per_layer_policy() {
        let map = AttributionMap()
        map.record(decision: decision(unit: "u1", policies: [("l1", "p1", "control")]))
        map.record(decision: decision(unit: "u1", policies: [("l1", "p1", "treatment")]))
        let attrs = map.attribution(for: "u1")
        XCTAssertEqual(attrs.count, 1)
        XCTAssertEqual(attrs.first?.allocationName, "treatment")
    }

    func test_clear_removes_user_attribution() {
        let map = AttributionMap()
        map.record(decision: decision(unit: "u1", policies: [("l1", "p1", "control")]))
        map.clear(unitKey: "u1")
        XCTAssertTrue(map.attribution(for: "u1").isEmpty)
    }

    private func decision(unit: String, policies: [(String, String, String)]) -> TrafficalDecisionResult {
        return TrafficalDecisionResult(
            decisionId: "dec",
            assignments: [:],
            metadata: TrafficalDecisionMetadata(
                timestamp: TrafficalTime.now(),
                unitKeyValue: unit,
                layers: policies.map { (layerId, policyId, allocationName) in
                    TrafficalLayerResolution(
                        layerId: layerId, bucket: 0,
                        policyId: policyId, allocationName: allocationName
                    )
                }
            )
        )
    }
}
