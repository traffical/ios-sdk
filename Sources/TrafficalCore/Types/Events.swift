import Foundation

/// Base fields shared by every event the SDK ships to `/v1/events/batch`.
public struct TrafficalBaseEvent: Sendable {
    public var id: String?
    public var orgId: String
    public var projectId: String
    public var env: String
    public var unitKey: String
    public var timestamp: String
    public var context: TrafficalContext?
    public var sdkName: String?
    public var sdkVersion: String?

    public init(
        id: String? = nil,
        orgId: String,
        projectId: String,
        env: String,
        unitKey: String,
        timestamp: String,
        context: TrafficalContext? = nil,
        sdkName: String? = nil,
        sdkVersion: String? = nil
    ) {
        self.id = id
        self.orgId = orgId
        self.projectId = projectId
        self.env = env
        self.unitKey = unitKey
        self.timestamp = timestamp
        self.context = context
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
    }
}

public struct TrafficalExposureEvent: Sendable {
    public var base: TrafficalBaseEvent
    public var decisionId: String
    public var assignments: [String: TrafficalParameterValue]
    public var layers: [TrafficalLayerResolution]
    /// The config bundle `version` the SDK evaluated against.
    public var configVersion: String?

    public init(
        base: TrafficalBaseEvent,
        decisionId: String,
        assignments: [String: TrafficalParameterValue],
        layers: [TrafficalLayerResolution],
        configVersion: String? = nil
    ) {
        self.base = base
        self.decisionId = decisionId
        self.assignments = assignments
        self.layers = layers
        self.configVersion = configVersion
    }
}

public struct TrafficalTrackAttribution: Sendable, Equatable {
    public var layerId: String
    public var policyId: String
    public var allocationName: String
    public var weight: Double?

    public init(layerId: String, policyId: String, allocationName: String, weight: Double? = nil) {
        self.layerId = layerId
        self.policyId = policyId
        self.allocationName = allocationName
        self.weight = weight
    }
}

public struct TrafficalTrackEvent: Sendable {
    public var base: TrafficalBaseEvent
    public var event: String
    public var decisionId: String?
    public var value: Double?
    public var values: [String: Double]?
    public var properties: TrafficalJSON?
    public var attribution: [TrafficalTrackAttribution]?

    public init(
        base: TrafficalBaseEvent,
        event: String,
        decisionId: String? = nil,
        value: Double? = nil,
        values: [String: Double]? = nil,
        properties: TrafficalJSON? = nil,
        attribution: [TrafficalTrackAttribution]? = nil
    ) {
        self.base = base
        self.event = event
        self.decisionId = decisionId
        self.value = value
        self.values = values
        self.properties = properties
        self.attribution = attribution
    }
}

public struct TrafficalDecisionEvent: Sendable {
    public var base: TrafficalBaseEvent
    public var requestedParameters: [String]?
    public var assignments: [String: TrafficalParameterValue]
    public var layers: [TrafficalLayerResolution]
    public var latencyMs: Double?
    /// The config bundle `version` the SDK evaluated against.
    public var configVersion: String?

    public init(
        base: TrafficalBaseEvent,
        requestedParameters: [String]? = nil,
        assignments: [String: TrafficalParameterValue],
        layers: [TrafficalLayerResolution],
        latencyMs: Double? = nil,
        configVersion: String? = nil
    ) {
        self.base = base
        self.requestedParameters = requestedParameters
        self.assignments = assignments
        self.layers = layers
        self.latencyMs = latencyMs
        self.configVersion = configVersion
    }
}

/// Discriminator for which call produced an assignment row.
/// A subset of the canonical event `type` discriminator.
public enum TrafficalAssignmentType: String, Sendable {
    case decision
    case exposure
}

/// Warehouse-native assignment log entry.
public struct TrafficalAssignmentLogEntry: Sendable {
    public var unitKey: String
    public var policyId: String
    public var policyKey: String?
    public var allocationName: String
    public var allocationKey: String?
    public var timestamp: String
    public var layerId: String
    public var allocationId: String?
    public var orgId: String
    public var projectId: String
    public var env: String
    public var sdkName: String?
    public var sdkVersion: String?
    public var properties: TrafficalContext?
    /// Event type that produced this row: matches the event `type` discriminator.
    public var type: TrafficalAssignmentType
    /// Decision that produced this assignment (decision.decisionId).
    public var decisionId: String?
    /// Anonymous/stable id when available (client SDKs).
    public var anonymousId: String?
    /// Unique id for this assignment log entry.
    public var id: String?
    /// Hash bucket of the layer's unit at decision time. `nil` when the
    /// layer was skipped (bucket -1). Warehouse row key: `bucket`.
    public var bucket: Int?
    /// Propensity of the chosen allocation at decision time, in (0, 1].
    /// Adaptive policies only; `nil` for static policies. Warehouse row key:
    /// `propensity`.
    public var probability: Double?
    /// linear_contextual only: model timestamp of the coefficients used at
    /// decision time. Warehouse row key: `model_version`.
    public var modelVersion: String?
    /// The config bundle `version` the SDK evaluated against (server mode:
    /// the resolve response's `stateVersion`). Warehouse row key:
    /// `config_version`.
    public var configVersion: String?

    public init(
        unitKey: String,
        policyId: String,
        policyKey: String? = nil,
        allocationName: String,
        allocationKey: String? = nil,
        timestamp: String,
        layerId: String,
        allocationId: String? = nil,
        orgId: String,
        projectId: String,
        env: String,
        sdkName: String? = nil,
        sdkVersion: String? = nil,
        properties: TrafficalContext? = nil,
        type: TrafficalAssignmentType,
        decisionId: String? = nil,
        anonymousId: String? = nil,
        id: String? = nil,
        bucket: Int? = nil,
        probability: Double? = nil,
        modelVersion: String? = nil,
        configVersion: String? = nil
    ) {
        self.unitKey = unitKey
        self.policyId = policyId
        self.policyKey = policyKey
        self.allocationName = allocationName
        self.allocationKey = allocationKey
        self.timestamp = timestamp
        self.layerId = layerId
        self.allocationId = allocationId
        self.orgId = orgId
        self.projectId = projectId
        self.env = env
        self.sdkName = sdkName
        self.sdkVersion = sdkVersion
        self.properties = properties
        self.type = type
        self.decisionId = decisionId
        self.anonymousId = anonymousId
        self.id = id
        self.bucket = bucket
        self.probability = probability
        self.modelVersion = modelVersion
        self.configVersion = configVersion
    }
}
