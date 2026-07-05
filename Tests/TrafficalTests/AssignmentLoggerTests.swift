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
        emitter.emit(decision: makeDecision(), type: .decision)
        XCTAssertEqual(captured.value.count, 2)
        XCTAssertEqual(Set(captured.value.map(\.policyId)), ["p1", "p2"])
    }

    func test_dedup_suppresses_repeat_emits_for_same_unit_policy_allocation_type() {
        let captured = Box([TrafficalAssignmentLogEntry]())
        let emitter = AssignmentLogEmitter(orgId: "org", projectId: "proj", env: "prod") {
            captured.value.append($0)
        }
        let decision = makeDecision()
        emitter.emit(decision: decision, type: .decision)
        emitter.emit(decision: decision, type: .decision)
        XCTAssertEqual(captured.value.count, 2)
    }

    func test_decision_and_exposure_produce_two_distinct_rows_per_layer() {
        let captured = Box([TrafficalAssignmentLogEntry]())
        let emitter = AssignmentLogEmitter(orgId: "org", projectId: "proj", env: "prod") {
            captured.value.append($0)
        }
        let decision = makeDecision()
        emitter.emit(decision: decision, type: .decision)
        emitter.emit(decision: decision, type: .exposure)
        // 2 layers x 2 types = 4 rows; dedup only suppresses same type.
        XCTAssertEqual(captured.value.count, 4)
        XCTAssertEqual(captured.value.filter { $0.type == .decision }.count, 2)
        XCTAssertEqual(captured.value.filter { $0.type == .exposure }.count, 2)
    }

    func test_emitted_entries_carry_new_fields() {
        let captured = Box([TrafficalAssignmentLogEntry]())
        let emitter = AssignmentLogEmitter(orgId: "org", projectId: "proj", env: "prod") {
            captured.value.append($0)
        }
        emitter.emit(decision: makeDecision(), type: .exposure, anonymousId: "anon_1")
        XCTAssertFalse(captured.value.isEmpty)
        for entry in captured.value {
            XCTAssertEqual(entry.type, .exposure)
            XCTAssertEqual(entry.decisionId, "dec_1")
            XCTAssertEqual(entry.anonymousId, "anon_1")
            XCTAssertNotNil(entry.id)
            XCTAssertTrue(entry.id?.hasPrefix("asn_") ?? false)
        }
    }

    func test_entries_pass_through_bucket_propensity_model_and_config_version() {
        let captured = Box([TrafficalAssignmentLogEntry]())
        let emitter = AssignmentLogEmitter(orgId: "org", projectId: "proj", env: "prod") {
            captured.value.append($0)
        }
        emitter.emit(decision: makeDecision(), type: .decision)
        XCTAssertEqual(captured.value.count, 2)

        let contextual = captured.value.first(where: { $0.policyId == "p1" })
        XCTAssertEqual(contextual?.bucket, 100)
        XCTAssertEqual(contextual?.probability ?? -1, 0.42, accuracy: 1e-9)
        XCTAssertEqual(contextual?.modelVersion, "2026-07-02T12:00:00Z")
        XCTAssertEqual(contextual?.configVersion, "2026-05-21T00:00:00Z")

        // Static-policy layer: no propensity, no model version — the fields
        // stay nil so warehouse rows omit them.
        let staticLayer = captured.value.first(where: { $0.policyId == "p2" })
        XCTAssertEqual(staticLayer?.bucket, 200)
        XCTAssertNil(staticLayer?.probability)
        XCTAssertNil(staticLayer?.modelVersion)
        XCTAssertEqual(staticLayer?.configVersion, "2026-05-21T00:00:00Z")
    }

    func test_dedup_disabled_emits_every_time() {
        let captured = Box([TrafficalAssignmentLogEntry]())
        let emitter = AssignmentLogEmitter(
            orgId: "org", projectId: "proj", env: "prod", deduplicate: false
        ) { captured.value.append($0) }
        let decision = makeDecision()
        emitter.emit(decision: decision, type: .decision)
        emitter.emit(decision: decision, type: .decision)
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
                        policyId: "p1", allocationId: "a1", allocationName: "control",
                        probability: 0.42, modelVersion: "2026-07-02T12:00:00Z"
                    ),
                    TrafficalLayerResolution(
                        layerId: "l2", bucket: 200,
                        policyId: "p2", allocationId: "a2", allocationName: "treatment"
                    ),
                ],
                configVersion: "2026-05-21T00:00:00Z"
            )
        )
    }
}
