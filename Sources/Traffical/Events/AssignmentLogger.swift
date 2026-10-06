import Foundation
import TrafficalCore

/// Warehouse-native assignment log entry consumer.
///
/// When the host app wants to route assignments to its own analytics
/// pipeline (Segment, Rudderstack, direct DB write), they pass a closure
/// matching this signature in `TrafficalClient.Options`.
public typealias TrafficalAssignmentLogger = @Sendable (TrafficalAssignmentLogEntry) -> Void

/// Emits assignment log entries from a decision, with per-session
/// deduplication so the same unit/policy/allocation doesn't fire repeatedly.
public final class AssignmentLogEmitter: @unchecked Sendable {
    private let orgId: String
    private let projectId: String
    private let env: String
    private let logger: TrafficalAssignmentLogger
    private let dedup: ExposureDeduplicator?

    public init(
        orgId: String,
        projectId: String,
        env: String,
        deduplicate: Bool = true,
        logger: @escaping TrafficalAssignmentLogger
    ) {
        self.orgId = orgId
        self.projectId = projectId
        self.env = env
        self.logger = logger
        self.dedup = deduplicate ? ExposureDeduplicator() : nil
    }

    /// Thread-dictionary key marking an emission in progress on this thread.
    private static let reentrancyKey = "io.traffical.sdk.assignment-logger.emitting"

    public func emit(
        decision: TrafficalDecisionResult,
        type: TrafficalAssignmentType,
        anonymousId: String? = nil
    ) {
        let unitKey = decision.metadata.unitKeyValue
        guard !unitKey.isEmpty else { return }
        // Re-entrancy guard: a logger that calls back into the client (e.g. to
        // read a parameter for its own payload) gets its decision, but no
        // nested emission. Without this, `deduplicate: false` recursed until
        // the stack overflowed.
        let threadDict = Thread.current.threadDictionary
        if threadDict[Self.reentrancyKey] != nil { return }
        threadDict[Self.reentrancyKey] = true
        defer { threadDict.removeObject(forKey: Self.reentrancyKey) }
        for layer in decision.metadata.layers {
            guard let policyId = layer.policyId, let allocationName = layer.allocationName else { continue }
            if let dedup = dedup, !dedup.checkAndMark(unitKey: unitKey, policyId: policyId, allocationName: "\(allocationName):\(type.rawValue)") {
                continue
            }
            let entry = TrafficalAssignmentLogEntry(
                unitKey: unitKey,
                policyId: policyId,
                policyKey: layer.policyKey,
                allocationName: allocationName,
                allocationKey: layer.allocationKey,
                timestamp: decision.metadata.timestamp,
                layerId: layer.layerId,
                allocationId: layer.allocationId,
                orgId: orgId,
                projectId: projectId,
                env: env,
                sdkName: trafficalSDKName,
                sdkVersion: trafficalSDKVersion,
                properties: decision.metadata.filteredContext,
                type: type,
                decisionId: decision.decisionId,
                anonymousId: anonymousId,
                id: TrafficalIDGenerator.assignmentId(),
                bucket: layer.bucket >= 0 ? layer.bucket : nil,
                probability: layer.probability,
                modelVersion: layer.modelVersion,
                configVersion: decision.metadata.configVersion
            )
            logger(entry)
        }
    }
}
