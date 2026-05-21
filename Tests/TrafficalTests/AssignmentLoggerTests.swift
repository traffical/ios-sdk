import XCTest
@testable import Traffical
@testable import TrafficalCore

/// Box used to capture closure side-effects from `@Sendable` callbacks in
/// tests. Marked `@unchecked Sendable` because the test serializes access.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

final class AssignmentLoggerTests: XCTestCase {
    func test_emits_one_entry_per_layer_in_a_decision() {
        let captured = Box([TrafficalAssignmentLogEntry]())
        let emitter = AssignmentLogEmitter(orgId: "org", projectId: "proj", env: "prod") {
            captured.value.append($0)
        }
        emitter.emit(decision: makeDecision())
        XCTAssertEqual(captured.value.count, 2)
        XCTAssertEqual(Set(captured.value.map(\.policyId)), ["p1", "p2"])
    }

    func test_dedup_suppresses_repeat_emits_for_same_unit_policy_allocation() {
        let captured = Box([TrafficalAssignmentLogEntry]())
        let emitter = AssignmentLogEmitter(orgId: "org", projectId: "proj", env: "prod") {
            captured.value.append($0)
        }
        let decision = makeDecision()
        emitter.emit(decision: decision)
        emitter.emit(decision: decision)
        XCTAssertEqual(captured.value.count, 2)
    }

    func test_dedup_disabled_emits_every_time() {
        let captured = Box([TrafficalAssignmentLogEntry]())
        let emitter = AssignmentLogEmitter(
            orgId: "org", projectId: "proj", env: "prod", deduplicate: false
        ) { captured.value.append($0) }
        let decision = makeDecision()
        emitter.emit(decision: decision)
        emitter.emit(decision: decision)
        XCTAssertEqual(captured.value.count, 4)
    }

    private func makeDecision() -> TrafficalDecisionResult {
        return TrafficalDecisionResult(
            decisionId: "dec_1",
            assignments: [:],
            metadata: TrafficalDecisionMetadata(
                timestamp: TrafficalTime.now(),
                unitKeyValue: "user_42",
                layers: [
                    TrafficalLayerResolution(
                        layerId: "l1", bucket: 100,
                        policyId: "p1", allocationId: "a1", allocationName: "control"
                    ),
                    TrafficalLayerResolution(
                        layerId: "l2", bucket: 200,
                        policyId: "p2", allocationId: "a2", allocationName: "treatment"
                    ),
                ]
            )
        )
    }
}
