import Foundation

/// Pre-computed edge results, used by server-evaluated mode and by bundle
/// mode that needs to interleave per-entity-edge policies with bundle ones.
public struct ResolveOptions: Sendable {
    public var edgeResults: [String: EdgeResult]

    public init(edgeResults: [String: EdgeResult] = [:]) {
        self.edgeResults = edgeResults
    }
}

public struct EdgeResult: Sendable, Equatable {
    public var allocationIndex: Int
    public var entityId: String

    public init(allocationIndex: Int, entityId: String) {
        self.allocationIndex = allocationIndex
        self.entityId = entityId
    }
}

/// Internal result threaded through the engine: assignments plus the metadata
/// the SDK needs for tracking and context filtering.
struct ResolutionResult {
    var assignments: [String: TrafficalParameterValue]
    var unitKeyValue: String
    var layers: [TrafficalLayerResolution]
    var matchedPolicies: [BundlePolicy]
}

/// Resolves parameters from a bundle with caller defaults as the floor.
///
/// Priority (highest wins):
/// 1. Policy override for the matched allocation
/// 2. Parameter default from the bundle
/// 3. Caller default
public func resolveParameters(
    bundle: TrafficalConfigBundle?,
    context: TrafficalContext,
    defaults: [String: TrafficalParameterValue],
    options: ResolveOptions = ResolveOptions()
) -> [String: TrafficalParameterValue] {
    return resolveInternal(bundle: bundle, context: context, defaults: defaults, options: options).assignments
}

/// Makes a decision with full metadata for tracking.
public func decide(
    bundle: TrafficalConfigBundle?,
    context: TrafficalContext,
    defaults: [String: TrafficalParameterValue],
    options: ResolveOptions = ResolveOptions()
) -> TrafficalDecisionResult {
    let result = resolveInternal(bundle: bundle, context: context, defaults: defaults, options: options)
    let filteredContext = filterContext(context: context, matched: result.matchedPolicies)
    return TrafficalDecisionResult(
        decisionId: TrafficalIDGenerator.decisionId(),
        assignments: result.assignments,
        metadata: TrafficalDecisionMetadata(
            timestamp: TrafficalTime.now(),
            unitKeyValue: result.unitKeyValue,
            layers: result.layers,
            filteredContext: filteredContext
        )
    )
}

/// Reads the unit key value from context using the bundle's configured key.
public func getUnitKeyValue(bundle: TrafficalConfigBundle, context: TrafficalContext) -> String? {
    guard let raw = context[bundle.hashing.unitKey] else { return nil }
    if raw.isMissing { return nil }
    if let s = raw.stringValue { return s }
    if let n = raw.numberValue {
        if n.rounded() == n { return String(Int64(n)) }
        return String(n)
    }
    if let b = raw.boolValue { return b ? "true" : "false" }
    return nil
}

// MARK: - Internal

func resolveInternal(
    bundle: TrafficalConfigBundle?,
    context: TrafficalContext,
    defaults: [String: TrafficalParameterValue],
    options: ResolveOptions
) -> ResolutionResult {
    // Start with caller defaults — the guaranteed-safe floor.
    var assignments = defaults
    var layers: [TrafficalLayerResolution] = []
    var matchedPolicies: [BundlePolicy] = []

    guard let bundle = bundle else {
        return ResolutionResult(
            assignments: assignments,
            unitKeyValue: "",
            layers: layers,
            matchedPolicies: matchedPolicies
        )
    }

    guard let unitKeyValue = getUnitKeyValue(bundle: bundle, context: context) else {
        return ResolutionResult(
            assignments: assignments,
            unitKeyValue: "",
            layers: layers,
            matchedPolicies: matchedPolicies
        )
    }

    let requestedKeys = Set(defaults.keys)

    // Apply bundle-level parameter defaults for everything the caller requested.
    var paramsByLayer: [String: [BundleParameter]] = [:]
    for param in bundle.parameters where requestedKeys.contains(param.key) {
        assignments[param.key] = param.default
        paramsByLayer[param.layerId, default: []].append(param)
    }

    // Walk every layer (including those with no requested params, for
    // attribution-only tracking).
    for layer in bundle.layers {
        let layerParams = paramsByLayer[layer.id]
        let hasParams = (layerParams?.isEmpty == false)

        let bucket = computeBucket(
            unitKeyValue: unitKeyValue,
            layerId: layer.id,
            bucketCount: bundle.hashing.bucketCount
        )

        var matchedPolicy: BundlePolicy?
        var matchedAllocation: BundleAllocation?

        for policy in layer.policies {
            if policy.state != .running { continue }
            if let range = policy.eligibleBucketRange, !range.contains(bucket) { continue }
            if !evaluateConditions(policy.conditions, context: context) { continue }

            // Contextual model takes precedence over standard bucket assignment.
            if policy.contextualModel != nil {
                if let ctxAlloc = resolveContextualPolicy(
                    policy: policy,
                    context: context,
                    unitKeyValue: unitKeyValue
                ) {
                    matchedPolicy = policy
                    matchedAllocation = ctxAlloc
                    matchedPolicies.append(policy)
                    if hasParams { applyOverrides(ctxAlloc.overrides, to: &assignments) }
                    break
                }
            }

            // Per-entity adaptive — bundle mode resolves locally, edge mode
            // consumes pre-fetched results threaded through `options`.
            if let entityConfig = policy.entityConfig {
                switch entityConfig.resolutionMode {
                case .bundle:
                    if let result = resolvePerEntityPolicy(
                        bundle: bundle,
                        policy: policy,
                        context: context,
                        unitKeyValue: unitKeyValue
                    ) {
                        matchedPolicy = policy
                        matchedAllocation = result.allocation
                        matchedPolicies.append(policy)
                        if hasParams && entityConfig.dynamicAllocations == nil {
                            applyOverrides(result.allocation.overrides, to: &assignments)
                        }
                        break
                    } else {
                        continue
                    }
                case .edge:
                    if let edge = options.edgeResults[policy.id] {
                        matchedPolicy = policy
                        matchedPolicies.append(policy)
                        if let dynamic = entityConfig.dynamicAllocations {
                            _ = dynamic
                            // Synthesize a dynamic allocation from the index.
                            matchedAllocation = BundleAllocation(
                                id: "\(policy.id)_dynamic_\(edge.allocationIndex)",
                                name: String(edge.allocationIndex),
                                bucketRange: BundleBucketRange(start: 0, end: 0),
                                overrides: [:]
                            )
                        } else if edge.allocationIndex >= 0 && edge.allocationIndex < policy.allocations.count {
                            let alloc = policy.allocations[edge.allocationIndex]
                            matchedAllocation = alloc
                            if hasParams { applyOverrides(alloc.overrides, to: &assignments) }
                        }
                        break
                    } else {
                        continue
                    }
                }
                if matchedPolicy != nil { break }
                continue
            }

            // Standard bucket-based allocation.
            if let alloc = findMatchingAllocation(bucket: bucket, in: policy.allocations) {
                matchedPolicy = policy
                matchedAllocation = alloc
                matchedPolicies.append(policy)
                if hasParams { applyOverrides(alloc.overrides, to: &assignments) }
                break
            }
        }

        layers.append(TrafficalLayerResolution(
            layerId: layer.id,
            bucket: bucket,
            policyId: matchedPolicy?.id,
            policyKey: matchedPolicy?.key,
            allocationId: matchedAllocation?.id,
            allocationName: matchedAllocation?.name,
            allocationKey: matchedAllocation?.key,
            attributionOnly: !hasParams
        ))
    }

    return ResolutionResult(
        assignments: assignments,
        unitKeyValue: unitKeyValue,
        layers: layers,
        matchedPolicies: matchedPolicies
    )
}

private func applyOverrides(
    _ overrides: [String: TrafficalParameterValue],
    to assignments: inout [String: TrafficalParameterValue]
) {
    for (key, value) in overrides where assignments[key] != nil {
        assignments[key] = value
    }
}

private func filterContext(context: TrafficalContext, matched: [BundlePolicy]) -> TrafficalContext? {
    var allowed = Set<String>()
    for policy in matched {
        if let fields = policy.contextLogging?.allowedFields {
            for f in fields { allowed.insert(f) }
        }
    }
    if allowed.isEmpty { return nil }
    var out: TrafficalContext = [:]
    for field in allowed where context[field] != nil {
        out[field] = context[field]
    }
    return out.isEmpty ? nil : out
}
