import Foundation
import TrafficalCore

/// Wire types for server-evaluated mode and edge-policy resolution.
public struct ServerResolveResponse: Sendable {
    public var decisionId: String
    public var assignments: [String: TrafficalParameterValue]
    public var metadata: TrafficalDecisionMetadata
    public var stateVersion: String?
    public var suggestedRefreshMs: Double?

    public init(
        decisionId: String,
        assignments: [String: TrafficalParameterValue],
        metadata: TrafficalDecisionMetadata,
        stateVersion: String? = nil,
        suggestedRefreshMs: Double? = nil
    ) {
        self.decisionId = decisionId
        self.assignments = assignments
        self.metadata = metadata
        self.stateVersion = stateVersion
        self.suggestedRefreshMs = suggestedRefreshMs
    }
}

public struct EdgeDecideRequest: Sendable {
    public var policyId: String
    public var entityId: String
    public var entityKeys: [String]
    public var context: TrafficalContext
    public var unitKeyValue: String
    public var allocationCount: Int?

    public init(
        policyId: String,
        entityId: String,
        entityKeys: [String],
        context: TrafficalContext,
        unitKeyValue: String,
        allocationCount: Int? = nil
    ) {
        self.policyId = policyId
        self.entityId = entityId
        self.entityKeys = entityKeys
        self.context = context
        self.unitKeyValue = unitKeyValue
        self.allocationCount = allocationCount
    }
}

public struct EdgeDecideResponse: Sendable {
    public var policyId: String
    public var allocationIndex: Int
    public var entityId: String

    public init(policyId: String, allocationIndex: Int, entityId: String) {
        self.policyId = policyId
        self.allocationIndex = allocationIndex
        self.entityId = entityId
    }
}

/// Client for server-evaluated endpoints.
///
/// - `POST /v1/resolve` — full server-side decision for the current context
///   (used in `.server` evaluation mode).
/// - `POST /v1/decide/entity/batch` — batch resolution of edge-mode per-entity
///   policies (used in bundle mode when the bundle contains edge policies).
public final class DecisionClient: @unchecked Sendable {
    private let http: TrafficalHTTPClient
    private let orgId: String
    private let projectId: String
    private let env: String
    /// Server-resolve request timeout (spec default: 5s).
    private let resolveTimeoutMs: Int

    public init(http: TrafficalHTTPClient, orgId: String, projectId: String, env: String, resolveTimeoutMs: Int = 5_000) {
        self.http = http
        self.orgId = orgId
        self.projectId = projectId
        self.env = env
        self.resolveTimeoutMs = resolveTimeoutMs
    }

    public func resolve(context: TrafficalContext) async throws -> ServerResolveResponse {
        let body: [String: Any] = [
            "orgId": orgId,
            "projectId": projectId,
            "env": env,
            "context": contextToAny(context),
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.post(path: "v1/resolve", body: data, timeoutMs: resolveTimeoutMs)
        guard (200..<300).contains(response.statusCode) else {
            throw TrafficalHTTPClient.Failure.invalidResponse
        }
        return try decodeServerResolveResponse(response.data)
    }

    public func decideEntityBatch(_ requests: [EdgeDecideRequest]) async throws -> [EdgeDecideResponse] {
        let body: [String: Any] = [
            "orgId": orgId,
            "projectId": projectId,
            "env": env,
            "requests": requests.map(serializeEdgeRequest),
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let response = try await http.post(path: "v1/decide/entity/batch", body: data)
        guard (200..<300).contains(response.statusCode) else {
            throw TrafficalHTTPClient.Failure.invalidResponse
        }
        return try decodeEdgeBatchResponse(response.data)
    }

    // MARK: - Serialization helpers

    private func serializeEdgeRequest(_ request: EdgeDecideRequest) -> [String: Any] {
        var dict: [String: Any] = [
            "policyId": request.policyId,
            "entityId": request.entityId,
            "entityKeys": request.entityKeys,
            "context": contextToAny(request.context),
            "unitKeyValue": request.unitKeyValue,
        ]
        if let count = request.allocationCount { dict["allocationCount"] = count }
        return dict
    }
}

// MARK: - Decoding

func decodeServerResolveResponse(_ data: Data) throws -> ServerResolveResponse {
    guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw TrafficalBundleDecodingError.invalid("server resolve response is not an object")
    }
    let decisionId = (dict["decisionId"] as? String) ?? TrafficalIDGenerator.decisionId()

    var assignments: [String: TrafficalParameterValue] = [:]
    if let raw = dict["assignments"] as? [String: Any] {
        for (key, value) in raw {
            assignments[key] = TrafficalParameterValue.from(any: value, type: inferType(of: value))
        }
    }

    let metadataDict = dict["metadata"] as? [String: Any] ?? [:]
    let metadata = TrafficalDecisionMetadata(
        timestamp: (metadataDict["timestamp"] as? String) ?? TrafficalTime.now(),
        unitKeyValue: (metadataDict["unitKeyValue"] as? String) ?? "",
        layers: ((metadataDict["layers"] as? [[String: Any]]) ?? []).map(decodeLayerResolution),
        filteredContext: (metadataDict["filteredContext"] as? [String: Any]).map { raw in
            var ctx: TrafficalContext = [:]
            for (k, v) in raw { ctx[k] = TrafficalContextValue.from(any: v) }
            return ctx
        }
    )

    return ServerResolveResponse(
        decisionId: decisionId,
        assignments: assignments,
        metadata: metadata,
        stateVersion: dict["stateVersion"] as? String,
        suggestedRefreshMs: numericDouble(dict["suggestedRefreshMs"])
    )
}

func decodeEdgeBatchResponse(_ data: Data) throws -> [EdgeDecideResponse] {
    let raw = try JSONSerialization.jsonObject(with: data)
    let responses: [[String: Any]]
    if let arr = raw as? [[String: Any]] {
        responses = arr
    } else if let dict = raw as? [String: Any], let arr = dict["responses"] as? [[String: Any]] {
        responses = arr
    } else {
        throw TrafficalBundleDecodingError.invalid("edge batch response shape unexpected")
    }
    return responses.compactMap { dict in
        guard
            let policyId = dict["policyId"] as? String,
            let entityId = dict["entityId"] as? String,
            let index = numericInt(dict["allocationIndex"])
        else { return nil }
        return EdgeDecideResponse(policyId: policyId, allocationIndex: index, entityId: entityId)
    }
}

func decodeLayerResolution(_ dict: [String: Any]) -> TrafficalLayerResolution {
    return TrafficalLayerResolution(
        layerId: (dict["layerId"] as? String) ?? "",
        bucket: numericInt(dict["bucket"]) ?? 0,
        policyId: dict["policyId"] as? String,
        policyKey: dict["policyKey"] as? String,
        allocationId: dict["allocationId"] as? String,
        allocationName: dict["allocationName"] as? String,
        allocationKey: dict["allocationKey"] as? String,
        unitKey: dict["unitKey"] as? String,
        unitKeyValue: dict["unitKeyValue"] as? String,
        probability: numericDouble(dict["probability"]),
        modelVersion: dict["modelVersion"] as? String,
        attributionOnly: (dict["attributionOnly"] as? Bool) ?? false
    )
}

func contextToAny(_ context: TrafficalContext) -> [String: Any] {
    var out: [String: Any] = [:]
    for (key, value) in context { out[key] = value.asAny }
    return out
}
