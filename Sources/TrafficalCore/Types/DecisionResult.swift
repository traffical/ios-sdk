import Foundation

/// The result of `decide`. Carries assignments plus the metadata callers need
/// to track exposures, attribute events, and debug resolution.
public struct TrafficalDecisionResult: Sendable, Equatable {
    public var decisionId: String
    public var assignments: [String: TrafficalParameterValue]
    public var metadata: TrafficalDecisionMetadata

    public init(
        decisionId: String,
        assignments: [String: TrafficalParameterValue],
        metadata: TrafficalDecisionMetadata
    ) {
        self.decisionId = decisionId
        self.assignments = assignments
        self.metadata = metadata
    }
}

public struct TrafficalDecisionMetadata: Sendable, Equatable {
    public var timestamp: String
    public var unitKeyValue: String
    public var layers: [TrafficalLayerResolution]
    public var filteredContext: TrafficalContext?
    /// The config bundle `version` the SDK evaluated against (server mode: the
    /// `stateVersion` of the resolve response). `nil` when no bundle was
    /// available and caller defaults were returned.
    public var configVersion: String?

    public init(
        timestamp: String,
        unitKeyValue: String,
        layers: [TrafficalLayerResolution],
        filteredContext: TrafficalContext? = nil,
        configVersion: String? = nil
    ) {
        self.timestamp = timestamp
        self.unitKeyValue = unitKeyValue
        self.layers = layers
        self.filteredContext = filteredContext
        self.configVersion = configVersion
    }
}

public struct TrafficalLayerResolution: Sendable, Equatable {
    public var layerId: String
    public var bucket: Int
    public var policyId: String?
    public var policyKey: String?
    public var allocationId: String?
    public var allocationName: String?
    public var allocationKey: String?
    /// Present only when the layer overrides the project-level `hashing.unitKey`.
    public var unitKey: String?
    /// Present only when `unitKey` is set. The resolved context value for the
    /// layer-level unit key.
    public var unitKeyValue: String?
    /// Propensity of the CHOSEN allocation at decision time, in (0, 1].
    /// - linear_contextual policies: the floored-softmax probability of the
    ///   chosen allocation.
    /// - other adaptive policies: the chosen allocation's bucket-range share
    ///   `(end - start + 1) / bucketCount`.
    /// - per-entity policies resolved in bundle mode: the weight the SDK
    ///   actually used for weighted selection.
    /// - static policies (and unmatched layers): `nil` — omitted on the wire.
    public var probability: Double?
    /// Only for linear_contextual policies: the model timestamp of the
    /// coefficients used at decision time. `nil` otherwise.
    public var modelVersion: String?
    /// `true` when this layer was resolved only for attribution (no parameter
    /// from this layer was requested by the caller). `trackExposure` skips
    /// these to avoid inflating exposure counts.
    public var attributionOnly: Bool

    public init(
        layerId: String,
        bucket: Int,
        policyId: String? = nil,
        policyKey: String? = nil,
        allocationId: String? = nil,
        allocationName: String? = nil,
        allocationKey: String? = nil,
        unitKey: String? = nil,
        unitKeyValue: String? = nil,
        probability: Double? = nil,
        modelVersion: String? = nil,
        attributionOnly: Bool = false
    ) {
        self.layerId = layerId
        self.bucket = bucket
        self.policyId = policyId
        self.policyKey = policyKey
        self.allocationId = allocationId
        self.allocationName = allocationName
        self.allocationKey = allocationKey
        self.unitKey = unitKey
        self.unitKeyValue = unitKeyValue
        self.probability = probability
        self.modelVersion = modelVersion
        self.attributionOnly = attributionOnly
    }
}
