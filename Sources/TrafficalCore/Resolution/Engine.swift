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
            filteredContext: filteredContext,
            configVersion: bundle?.version
        )
    )
}

/// Reads the unit key value from context using the bundle's configured key.
public func getUnitKeyValue(bundle: TrafficalConfigBundle, context: TrafficalContext) -> String? {
    guard let raw = context[bundle.hashing.unitKey] else { return nil }
    return stringifyUnitKeyValue(raw)
}

/// Canonically stringifies a context value for use as a unit key (spec S2).
///
/// Numbers route through `canonicalNumberString` (ECMAScript `Number::toString`)
/// so a numeric key produces the same bucket on every SDK, and — critically —
/// this never traps (the old `String(Int64(n))` crashed on magnitudes ≥ 2^63).
/// Returns `nil` for a missing/null value or a value with no scalar projection.
func stringifyUnitKeyValue(_ raw: TrafficalContextValue) -> String? {
    if raw.isMissing { return nil }
    if let s = raw.stringValue { return s }
    if let n = raw.numberValue { return canonicalNumberString(n) }
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

    // Project-level unit key. Layers that don't override `unitKey` use this.
    // We no longer bail out when this is missing — some layers in multi-entity
    // projects may still resolve via their own unit key.
    let projectUnitKeyValue = getUnitKeyValue(bundle: bundle, context: context) ?? ""

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

        // Per-layer unit key resolution. Layers may override `unitKey` to
        // read a different context field (e.g. merchantId in a userId project).
        let layerUnitKey = layer.unitKey
        let layerUnitValue: String
        if let override = layerUnitKey {
            // S1: an empty or whitespace-only override string is INVALID
            // configuration. Skip the layer (bucket -1, no unitKey metadata);
            // do NOT fall back to the project unit key, do NOT crash, do NOT
            // reject the bundle, and do NOT treat the whitespace string as a
            // context-field name to look up.
            if override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                layers.append(TrafficalLayerResolution(
                    layerId: layer.id,
                    bucket: -1,
                    attributionOnly: !hasParams
                ))
                continue
            }
            if let raw = context[override], let value = stringifyUnitKeyValue(raw) {
                layerUnitValue = value
            } else {
                layerUnitValue = ""
            }
        } else {
            layerUnitValue = projectUnitKeyValue
        }

        // A *valid* override that names a field absent from the context (or a
        // missing project unit key) also skips the layer with bucket -1, but
        // for the missing-value reason — the override name is recorded.
        if layerUnitValue.isEmpty {
            layers.append(TrafficalLayerResolution(
                layerId: layer.id,
                bucket: -1,
                unitKey: layerUnitKey,
                unitKeyValue: layerUnitKey != nil ? "" : nil,
                attributionOnly: !hasParams
            ))
            continue
        }

        let bucket = computeBucket(
            unitKeyValue: layerUnitValue,
            layerId: layer.id,
            bucketCount: bundle.hashing.bucketCount
        )

        var matchedPolicy: BundlePolicy?
        var matchedAllocation: BundleAllocation?
        // Propensity of the chosen allocation at decision time. Populated for
        // adaptive policies only (contextual softmax probability, per-entity
        // weight, or bucket-range share); stays nil for static policies so the
        // field is omitted on the wire.
        var matchedProbability: Double?
        // Only for linear_contextual: the timestamp of the model coefficients
        // that produced this decision.
        var matchedModelVersion: String?

        for policy in layer.policies {
            if policy.state != .running { continue }
            if let range = policy.eligibleBucketRange, !range.contains(bucket) { continue }
            if !evaluateConditions(policy.conditions, context: context) { continue }

            // Contextual model takes precedence over standard bucket assignment.
            if let model = policy.contextualModel {
                if let ctx = resolveContextualPolicy(
                    policy: policy,
                    context: context,
                    unitKeyValue: layerUnitValue
                ) {
                    matchedPolicy = policy
                    matchedAllocation = ctx.allocation
                    matchedProbability = ctx.probability
                    // S7: source strictly from the model — `generatedAt` first,
                    // then the `modelVersion` alias. There is NO further
                    // fallback to `policy.stateVersion`; if both are absent we
                    // emit no modelVersion rather than a wrong label.
                    matchedModelVersion = model.generatedAt ?? model.modelVersion
                    matchedPolicies.append(policy)
                    if hasParams { applyOverrides(ctx.allocation.overrides, to: &assignments) }
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
                        unitKeyValue: layerUnitValue
                    ) {
                        matchedPolicy = policy
                        matchedAllocation = result.allocation
                        // The weight the SDK actually used for selection.
                        matchedProbability = result.probability
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
                // Bucket-based adaptive policies (thompson_bernoulli /
                // epsilon_greedy / ucb1): the propensity is the chosen
                // allocation's bucket-range share. Static policies omit it.
                if policy.kind == .adaptive, bundle.hashing.bucketCount > 0 {
                    matchedProbability = Double(alloc.bucketRange.end - alloc.bucketRange.start + 1)
                        / Double(bundle.hashing.bucketCount)
                }
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
            unitKey: layerUnitKey,
            unitKeyValue: layerUnitKey != nil ? layerUnitValue : nil,
            probability: validProbability(matchedProbability),
            modelVersion: matchedModelVersion,
            attributionOnly: !hasParams
        ))
    }

    return ResolutionResult(
        assignments: assignments,
        unitKeyValue: projectUnitKeyValue,
        layers: layers,
        matchedPolicies: matchedPolicies
    )
}

/// The events schema constrains `probability` to (0, 1] (exclusiveMinimum 0,
/// maximum 1). Anything outside that range — the degenerate zero-weight
/// fallback of `weightedSelection`, a corrupt entity weight, or a bucket
/// range wider than `bucketCount` — is omitted rather than clamped.
private func validProbability(_ probability: Double?) -> Double? {
    guard let p = probability, p > 0, p <= 1 else { return nil }
    return p
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
