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

    public init(
        timestamp: String,
        unitKeyValue: String,
        layers: [TrafficalLayerResolution],
        filteredContext: TrafficalContext? = nil
    ) {
        self.timestamp = timestamp
        self.unitKeyValue = unitKeyValue
        self.layers = layers
        self.filteredContext = filteredContext
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
        attributionOnly: Bool = false
    ) {
        self.layerId = layerId
        self.bucket = bucket
        self.policyId = policyId
        self.policyKey = policyKey
        self.allocationId = allocationId
        self.allocationName = allocationName
        self.allocationKey = allocationKey
        self.attributionOnly = attributionOnly
    }
}
