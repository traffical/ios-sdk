import Foundation
import TrafficalCore

/// Session-scoped attribution map keyed by `unitKey -> "layerId:policyId" ->
/// TrackAttribution`. Last-write-wins per layer/policy combo so per-entity
/// dynamic-allocation policies don't accumulate stale attributions across
/// every product the user views.
///
/// Mirrors the `_cumulativeAttribution` map in `@traffical/js-client`.
public final class AttributionMap: @unchecked Sendable {
    private var byUser: [String: [String: TrafficalTrackAttribution]] = [:]
    private let lock = NSLock()

    public init() {}

    public func record(decision: TrafficalDecisionResult) {
        let unitKey = decision.metadata.unitKeyValue
        guard !unitKey.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        var userMap = byUser[unitKey] ?? [:]
        for layer in decision.metadata.layers {
            guard let policyId = layer.policyId, let allocationName = layer.allocationName else { continue }
            let key = "\(layer.layerId):\(policyId)"
            userMap[key] = TrafficalTrackAttribution(
                layerId: layer.layerId,
                policyId: policyId,
                allocationName: allocationName
            )
        }
        byUser[unitKey] = userMap
    }

    public func attribution(for unitKey: String) -> [TrafficalTrackAttribution] {
        lock.lock(); defer { lock.unlock() }
        return Array(byUser[unitKey]?.values ?? [:].values)
    }

    public func clear(unitKey: String) {
        lock.lock(); defer { lock.unlock() }
        byUser.removeValue(forKey: unitKey)
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        byUser.removeAll()
    }
}
