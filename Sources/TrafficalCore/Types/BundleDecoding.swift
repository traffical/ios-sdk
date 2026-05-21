import Foundation

/// Decoding errors surfaced when parsing a bundle JSON payload.
public enum TrafficalBundleDecodingError: Error, CustomStringConvertible {
    case missingField(String)
    case invalidType(String, expected: String)
    case invalid(String)

    public var description: String {
        switch self {
        case .missingField(let f): return "missing required field: \(f)"
        case .invalidType(let f, let exp): return "field \(f) has wrong type, expected \(exp)"
        case .invalid(let m): return m
        }
    }
}

public enum TrafficalBundleDecoder {
    /// Parses a config bundle from raw JSON data.
    public static func decode(_ data: Data) throws -> TrafficalConfigBundle {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = raw as? [String: Any] else {
            throw TrafficalBundleDecodingError.invalid("top-level must be an object")
        }
        return try decode(dict)
    }

    public static func decode(_ dict: [String: Any]) throws -> TrafficalConfigBundle {
        return TrafficalConfigBundle(
            version: try string(dict, "version", default: ""),
            orgId: try string(dict, "orgId", default: ""),
            projectId: try string(dict, "projectId", default: ""),
            env: try string(dict, "env", default: ""),
            hashing: try decodeHashing(try object(dict, "hashing")),
            parameters: try arrayOfObjects(dict, "parameters").map(decodeParameter),
            layers: try arrayOfObjects(dict, "layers").map(decodeLayer),
            entityState: decodeEntityState(dict["entityState"])
        )
    }

    // MARK: - Hashing

    static func decodeHashing(_ dict: [String: Any]) throws -> BundleHashingConfig {
        return BundleHashingConfig(
            unitKey: try string(dict, "unitKey"),
            bucketCount: try int(dict, "bucketCount")
        )
    }

    // MARK: - Parameters

    static func decodeParameter(_ dict: [String: Any]) throws -> BundleParameter {
        let type = try string(dict, "type")
        guard let rawDefault = dict["default"] else {
            throw TrafficalBundleDecodingError.missingField("parameters[].default")
        }
        return BundleParameter(
            key: try string(dict, "key"),
            type: type,
            default: TrafficalParameterValue.from(any: rawDefault, type: type),
            layerId: try string(dict, "layerId"),
            namespace: (dict["namespace"] as? String) ?? ""
        )
    }

    // MARK: - Layers + policies

    static func decodeLayer(_ dict: [String: Any]) throws -> BundleLayer {
        return BundleLayer(
            id: try string(dict, "id"),
            policies: try arrayOfObjects(dict, "policies").map(decodePolicy)
        )
    }

    static func decodePolicy(_ dict: [String: Any]) throws -> BundlePolicy {
        let state = BundlePolicyState(rawValue: try string(dict, "state")) ?? .running
        let kind = BundlePolicyKind(rawValue: (dict["kind"] as? String) ?? "static") ?? .static
        return BundlePolicy(
            id: try string(dict, "id"),
            key: dict["key"] as? String,
            state: state,
            kind: kind,
            allocations: try arrayOfObjects(dict, "allocations").map(decodeAllocation),
            conditions: try (try? arrayOfObjects(dict, "conditions"))?.map(decodeCondition) ?? [],
            stateVersion: dict["stateVersion"] as? String,
            contextLogging: decodeContextLogging(dict["contextLogging"]),
            contextualModel: decodeContextualModel(dict["contextualModel"]),
            entityConfig: decodeEntityConfig(dict["entityConfig"]),
            eligibleBucketRange: decodeBucketRange(dict["eligibleBucketRange"])
        )
    }

    static func decodeAllocation(_ dict: [String: Any]) throws -> BundleAllocation {
        let range = try decodeBucketRange(dict["bucketRange"]) ?? {
            throw TrafficalBundleDecodingError.missingField("allocations[].bucketRange")
        }()
        var overrides: [String: TrafficalParameterValue] = [:]
        if let rawOverrides = dict["overrides"] as? [String: Any] {
            for (key, value) in rawOverrides {
                overrides[key] = TrafficalParameterValue.from(any: value, type: inferType(of: value))
            }
        }
        let name = try string(dict, "name")
        // Allocations in the spec fixtures do not always carry an `id`; fall back
        // to the allocation name so resolution still has a stable identifier.
        let id = (dict["id"] as? String) ?? name
        return BundleAllocation(
            id: id,
            key: dict["key"] as? String,
            name: name,
            bucketRange: range,
            overrides: overrides
        )
    }

    static func decodeBucketRange(_ raw: Any?) -> BundleBucketRange? {
        if let arr = raw as? [Any], arr.count == 2,
           let start = numericInt(arr[0]),
           let end = numericInt(arr[1]) {
            return BundleBucketRange(start: start, end: end)
        }
        if let dict = raw as? [String: Any],
           let start = numericInt(dict["start"]),
           let end = numericInt(dict["end"]) {
            return BundleBucketRange(start: start, end: end)
        }
        return nil
    }

    static func decodeCondition(_ dict: [String: Any]) throws -> BundleCondition {
        return BundleCondition(
            field: try string(dict, "field"),
            op: try string(dict, "op"),
            value: dict["value"].map { TrafficalContextValue.from(any: $0) },
            values: (dict["values"] as? [Any]).map { $0.map { TrafficalContextValue.from(any: $0) } }
        )
    }

    static func decodeContextLogging(_ raw: Any?) -> BundleContextLogging? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard let fields = dict["allowedFields"] as? [String] else { return nil }
        return BundleContextLogging(allowedFields: fields)
    }

    static func decodeContextualModel(_ raw: Any?) -> BundleContextualModel? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard
            let gamma = numericDouble(dict["gamma"]),
            let floor = numericDouble(dict["actionProbabilityFloor"]),
            let defaultScore = numericDouble(dict["defaultAllocationScore"]),
            let coefRaw = dict["coefficients"] as? [String: Any]
        else { return nil }

        var coefficients: [String: BundleAllocationCoefficients] = [:]
        for (allocName, allocRaw) in coefRaw {
            guard let allocDict = allocRaw as? [String: Any] else { continue }
            coefficients[allocName] = decodeCoefficients(allocDict)
        }

        return BundleContextualModel(
            gamma: gamma,
            actionProbabilityFloor: floor,
            defaultAllocationScore: defaultScore,
            coefficients: coefficients
        )
    }

    static func decodeCoefficients(_ dict: [String: Any]) -> BundleAllocationCoefficients {
        let intercept = numericDouble(dict["intercept"]) ?? 0
        let numericRaw = dict["numeric"] as? [[String: Any]] ?? []
        let categoricalRaw = dict["categorical"] as? [[String: Any]] ?? []
        let numeric: [BundleNumericCoefficient] = numericRaw.compactMap { item in
            guard
                let key = item["key"] as? String,
                let coef = numericDouble(item["coef"]),
                let missing = numericDouble(item["missing"])
            else { return nil }
            return BundleNumericCoefficient(key: key, coef: coef, missing: missing)
        }
        let categorical: [BundleCategoricalCoefficient] = categoricalRaw.compactMap { item in
            guard
                let key = item["key"] as? String,
                let valuesRaw = item["values"] as? [String: Any],
                let missing = numericDouble(item["missing"])
            else { return nil }
            var values: [String: Double] = [:]
            for (k, v) in valuesRaw {
                if let d = numericDouble(v) { values[k] = d }
            }
            return BundleCategoricalCoefficient(key: key, values: values, missing: missing)
        }
        return BundleAllocationCoefficients(intercept: intercept, numeric: numeric, categorical: categorical)
    }

    static func decodeEntityConfig(_ raw: Any?) -> BundleEntityConfig? {
        guard let dict = raw as? [String: Any] else { return nil }
        guard
            let keys = dict["entityKeys"] as? [String],
            let modeRaw = dict["resolutionMode"] as? String,
            let mode = BundleEntityConfig.ResolutionMode(rawValue: modeRaw)
        else { return nil }
        var dynamic: BundleEntityConfig.DynamicAllocations?
        if let dyn = dict["dynamicAllocations"] as? [String: Any], let countKey = dyn["countKey"] as? String {
            dynamic = BundleEntityConfig.DynamicAllocations(countKey: countKey)
        }
        return BundleEntityConfig(
            entityKeys: keys,
            resolutionMode: mode,
            edgeTimeoutMs: numericInt(dict["edgeTimeoutMs"]),
            dynamicAllocations: dynamic
        )
    }

    static func decodeEntityState(_ raw: Any?) -> [String: BundleEntityPolicyState]? {
        guard let dict = raw as? [String: Any] else { return nil }
        var out: [String: BundleEntityPolicyState] = [:]
        for (policyId, stateRaw) in dict {
            guard let stateDict = stateRaw as? [String: Any] else { continue }
            guard let globalRaw = stateDict["_global"] as? [String: Any] else { continue }
            let global = decodeEntityWeights(globalRaw) ?? EntityWeights(entityId: "_global", weights: [], computedAt: "")
            var entities: [String: EntityWeights] = [:]
            if let entRaw = stateDict["entities"] as? [String: Any] {
                for (entId, weightsRaw) in entRaw {
                    if let weightsDict = weightsRaw as? [String: Any],
                       let weights = decodeEntityWeights(weightsDict) {
                        entities[entId] = weights
                    }
                }
            }
            out[policyId] = BundleEntityPolicyState(global: global, entities: entities)
        }
        return out
    }

    static func decodeEntityWeights(_ dict: [String: Any]) -> EntityWeights? {
        guard let weightsRaw = dict["weights"] as? [Any] else { return nil }
        let weights = weightsRaw.compactMap { numericDouble($0) }
        return EntityWeights(
            entityId: (dict["entityId"] as? String) ?? "",
            weights: weights,
            computedAt: (dict["computedAt"] as? String) ?? ""
        )
    }

    // MARK: - Helpers

    private static func string(_ dict: [String: Any], _ key: String, default fallback: String? = nil) throws -> String {
        if let v = dict[key] as? String { return v }
        if let fb = fallback { return fb }
        throw TrafficalBundleDecodingError.missingField(key)
    }

    private static func int(_ dict: [String: Any], _ key: String) throws -> Int {
        if let v = numericInt(dict[key]) { return v }
        throw TrafficalBundleDecodingError.invalidType(key, expected: "int")
    }

    private static func object(_ dict: [String: Any], _ key: String) throws -> [String: Any] {
        guard let v = dict[key] as? [String: Any] else {
            throw TrafficalBundleDecodingError.invalidType(key, expected: "object")
        }
        return v
    }

    private static func arrayOfObjects(_ dict: [String: Any], _ key: String) throws -> [[String: Any]] {
        guard let arr = dict[key] as? [[String: Any]] else {
            throw TrafficalBundleDecodingError.invalidType(key, expected: "array of objects")
        }
        return arr
    }
}

// MARK: - Numeric coercion

func numericInt(_ value: Any?) -> Int? {
    if let n = value as? Int { return n }
    if let n = value as? NSNumber { return n.intValue }
    if let s = value as? String { return Int(s) }
    return nil
}

func numericDouble(_ value: Any?) -> Double? {
    if let n = value as? Double { return n }
    if let n = value as? NSNumber { return n.doubleValue }
    if let s = value as? String { return Double(s) }
    return nil
}

func inferType(of value: Any) -> String {
    if let n = value as? NSNumber {
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return "boolean" }
        return "number"
    }
    if value is String { return "string" }
    if value is Bool { return "boolean" }
    if value is [Any] || value is [String: Any] { return "json" }
    return "json"
}
