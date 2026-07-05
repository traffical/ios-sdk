import Foundation

/// The complete configuration bundle the SDK fetches and caches.
///
/// This is the single source of truth for parameter resolution. Shape matches
/// `config-bundle.schema.json` in `sdk-spec`.
public struct TrafficalConfigBundle: Sendable, Equatable {
    public var version: String
    public var orgId: String
    public var projectId: String
    public var env: String
    public var hashing: BundleHashingConfig
    public var parameters: [BundleParameter]
    public var layers: [BundleLayer]
    public var entityState: [String: BundleEntityPolicyState]?

    public init(
        version: String,
        orgId: String,
        projectId: String,
        env: String,
        hashing: BundleHashingConfig,
        parameters: [BundleParameter],
        layers: [BundleLayer],
        entityState: [String: BundleEntityPolicyState]? = nil
    ) {
        self.version = version
        self.orgId = orgId
        self.projectId = projectId
        self.env = env
        self.hashing = hashing
        self.parameters = parameters
        self.layers = layers
        self.entityState = entityState
    }
}

public struct BundleHashingConfig: Sendable, Equatable {
    public var unitKey: String
    public var bucketCount: Int

    public init(unitKey: String, bucketCount: Int) {
        self.unitKey = unitKey
        self.bucketCount = bucketCount
    }
}

public struct BundleParameter: Sendable, Equatable {
    public var key: String
    public var type: String          // "string" | "number" | "boolean" | "json"
    public var `default`: TrafficalParameterValue
    public var layerId: String
    public var namespace: String

    public init(
        key: String,
        type: String,
        default: TrafficalParameterValue,
        layerId: String,
        namespace: String
    ) {
        self.key = key
        self.type = type
        self.default = `default`
        self.layerId = layerId
        self.namespace = namespace
    }
}

public struct BundleLayer: Sendable, Equatable {
    public var id: String
    /// Optional per-layer unit key override for multi-entity randomization.
    /// When set, the SDK hashes on this context field instead of
    /// `hashing.unitKey` for this layer only.
    public var unitKey: String?
    public var policies: [BundlePolicy]

    public init(id: String, unitKey: String? = nil, policies: [BundlePolicy]) {
        self.id = id
        self.unitKey = unitKey
        self.policies = policies
    }
}

public enum BundlePolicyState: String, Sendable {
    case draft
    case running
    case paused
    case completed
}

public enum BundlePolicyKind: String, Sendable {
    case `static`
    case adaptive
}

public struct BundlePolicy: Sendable, Equatable {
    public var id: String
    public var key: String?
    public var state: BundlePolicyState
    public var kind: BundlePolicyKind
    public var allocations: [BundleAllocation]
    public var conditions: [BundleCondition]
    public var stateVersion: String?
    public var contextLogging: BundleContextLogging?
    public var contextualModel: BundleContextualModel?
    public var entityConfig: BundleEntityConfig?
    public var eligibleBucketRange: BundleBucketRange?

    public init(
        id: String,
        key: String? = nil,
        state: BundlePolicyState,
        kind: BundlePolicyKind,
        allocations: [BundleAllocation],
        conditions: [BundleCondition],
        stateVersion: String? = nil,
        contextLogging: BundleContextLogging? = nil,
        contextualModel: BundleContextualModel? = nil,
        entityConfig: BundleEntityConfig? = nil,
        eligibleBucketRange: BundleBucketRange? = nil
    ) {
        self.id = id
        self.key = key
        self.state = state
        self.kind = kind
        self.allocations = allocations
        self.conditions = conditions
        self.stateVersion = stateVersion
        self.contextLogging = contextLogging
        self.contextualModel = contextualModel
        self.entityConfig = entityConfig
        self.eligibleBucketRange = eligibleBucketRange
    }
}

public struct BundleAllocation: Sendable, Equatable {
    public var id: String
    public var key: String?
    public var name: String
    public var bucketRange: BundleBucketRange
    public var overrides: [String: TrafficalParameterValue]

    public init(
        id: String,
        key: String? = nil,
        name: String,
        bucketRange: BundleBucketRange,
        overrides: [String: TrafficalParameterValue]
    ) {
        self.id = id
        self.key = key
        self.name = name
        self.bucketRange = bucketRange
        self.overrides = overrides
    }
}

public struct BundleBucketRange: Sendable, Equatable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    /// Bucket `b` is in range when start <= b <= end (inclusive on both ends),
    /// matching the spec.
    public func contains(_ bucket: Int) -> Bool {
        return bucket >= start && bucket <= end
    }
}

public struct BundleCondition: Sendable, Equatable {
    public var field: String
    public var op: String         // see Conditions.swift for the full operator set
    public var value: TrafficalContextValue?
    public var values: [TrafficalContextValue]?

    public init(
        field: String,
        op: String,
        value: TrafficalContextValue? = nil,
        values: [TrafficalContextValue]? = nil
    ) {
        self.field = field
        self.op = op
        self.value = value
        self.values = values
    }
}

public struct BundleContextLogging: Sendable, Equatable {
    public var allowedFields: [String]

    public init(allowedFields: [String]) {
        self.allowedFields = allowedFields
    }
}

// MARK: - Contextual bandit model

public struct BundleContextualModel: Sendable, Equatable {
    public var gamma: Double
    public var actionProbabilityFloor: Double
    public var defaultAllocationScore: Double
    public var coefficients: [String: BundleAllocationCoefficients]
    /// Timestamp of the training run that produced these coefficients
    /// (`trainingSummary.generatedAt`). Optional — older bundles omit it; the
    /// engine falls back to `modelVersion`, then the policy's `stateVersion`.
    public var generatedAt: String?
    /// Alias some bundles emit instead of `generatedAt`. Same semantics: the
    /// timestamp of the model coefficients. `generatedAt` wins when both are
    /// present.
    public var modelVersion: String?

    public init(
        gamma: Double,
        actionProbabilityFloor: Double,
        defaultAllocationScore: Double,
        coefficients: [String: BundleAllocationCoefficients],
        generatedAt: String? = nil,
        modelVersion: String? = nil
    ) {
        self.gamma = gamma
        self.actionProbabilityFloor = actionProbabilityFloor
        self.defaultAllocationScore = defaultAllocationScore
        self.coefficients = coefficients
        self.generatedAt = generatedAt
        self.modelVersion = modelVersion
    }
}

public struct BundleAllocationCoefficients: Sendable, Equatable {
    public var intercept: Double
    public var numeric: [BundleNumericCoefficient]
    public var categorical: [BundleCategoricalCoefficient]

    public init(
        intercept: Double,
        numeric: [BundleNumericCoefficient],
        categorical: [BundleCategoricalCoefficient]
    ) {
        self.intercept = intercept
        self.numeric = numeric
        self.categorical = categorical
    }
}

public struct BundleNumericCoefficient: Sendable, Equatable {
    public var key: String
    public var coef: Double
    public var missing: Double

    public init(key: String, coef: Double, missing: Double) {
        self.key = key
        self.coef = coef
        self.missing = missing
    }
}

public struct BundleCategoricalCoefficient: Sendable, Equatable {
    public var key: String
    public var values: [String: Double]
    public var missing: Double

    public init(key: String, values: [String: Double], missing: Double) {
        self.key = key
        self.values = values
        self.missing = missing
    }
}

// MARK: - Per-entity adaptive

public struct BundleEntityConfig: Sendable, Equatable {
    public var entityKeys: [String]
    public var resolutionMode: ResolutionMode
    public var edgeTimeoutMs: Int?
    public var dynamicAllocations: DynamicAllocations?

    public enum ResolutionMode: String, Sendable {
        case bundle
        case edge
    }

    public struct DynamicAllocations: Sendable, Equatable {
        public var countKey: String
        public init(countKey: String) { self.countKey = countKey }
    }

    public init(
        entityKeys: [String],
        resolutionMode: ResolutionMode,
        edgeTimeoutMs: Int? = nil,
        dynamicAllocations: DynamicAllocations? = nil
    ) {
        self.entityKeys = entityKeys
        self.resolutionMode = resolutionMode
        self.edgeTimeoutMs = edgeTimeoutMs
        self.dynamicAllocations = dynamicAllocations
    }
}

public struct BundleEntityPolicyState: Sendable, Equatable {
    public var global: EntityWeights
    public var entities: [String: EntityWeights]

    public init(global: EntityWeights, entities: [String: EntityWeights]) {
        self.global = global
        self.entities = entities
    }
}

public struct EntityWeights: Sendable, Equatable {
    public var entityId: String
    public var weights: [Double]
    public var computedAt: String

    public init(entityId: String, weights: [Double], computedAt: String) {
        self.entityId = entityId
        self.weights = weights
        self.computedAt = computedAt
    }
}
