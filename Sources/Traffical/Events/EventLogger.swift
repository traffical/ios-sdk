import Foundation
import TrafficalCore

/// Wire-shape event the SDK ships to `/v1/events/batch`. A union over our
/// three event kinds, kept as plain JSON-encodable dictionaries so the queue
/// can be persisted to disk on failure without dragging in Codable.
public enum TrafficalQueuedEvent: Sendable {
    case exposure(TrafficalExposureEvent)
    case track(TrafficalTrackEvent)
    case decision(TrafficalDecisionEvent)

    /// JSON-encodable representation.
    public var payload: [String: Any] {
        switch self {
        case .exposure(let event):
            var payload = baseFields(event.base)
            payload["type"] = "exposure"
            payload["decisionId"] = event.decisionId
            payload["assignments"] = assignmentsToAny(event.assignments)
            payload["layers"] = event.layers.map(layerToAny)
            if let configVersion = event.configVersion { payload["configVersion"] = configVersion }
            return payload
        case .track(let event):
            var payload = baseFields(event.base)
            payload["type"] = "track"
            payload["event"] = event.event
            if let did = event.decisionId { payload["decisionId"] = did }
            if let value = event.value { payload["value"] = value }
            if let values = event.values { payload["values"] = values }
            if let properties = event.properties { payload["properties"] = properties.asAny }
            if let attribution = event.attribution {
                payload["attribution"] = attribution.map { attr -> [String: Any] in
                    var out: [String: Any] = [
                        "layerId": attr.layerId,
                        "policyId": attr.policyId,
                        "allocationName": attr.allocationName,
                    ]
                    if let weight = attr.weight { out["weight"] = weight }
                    return out
                }
            }
            return payload
        case .decision(let event):
            var payload = baseFields(event.base)
            payload["type"] = "decision"
            if let req = event.requestedParameters { payload["requestedParameters"] = req }
            payload["assignments"] = assignmentsToAny(event.assignments)
            payload["layers"] = event.layers.map(layerToAny)
            if let ms = event.latencyMs { payload["latencyMs"] = ms }
            if let configVersion = event.configVersion { payload["configVersion"] = configVersion }
            return payload
        }
    }
}

private func baseFields(_ base: TrafficalBaseEvent) -> [String: Any] {
    var out: [String: Any] = [
        "orgId": base.orgId,
        "projectId": base.projectId,
        "env": base.env,
        "unitKey": base.unitKey,
        "timestamp": base.timestamp,
    ]
    if let id = base.id { out["id"] = id }
    if let context = base.context { out["context"] = contextToAny(context) }
    if let name = base.sdkName { out["sdkName"] = name }
    if let version = base.sdkVersion { out["sdkVersion"] = version }
    return out
}

private func assignmentsToAny(_ assignments: [String: TrafficalParameterValue]) -> [String: Any] {
    var out: [String: Any] = [:]
    for (k, v) in assignments { out[k] = v.asAny }
    return out
}

private func layerToAny(_ layer: TrafficalLayerResolution) -> [String: Any] {
    var out: [String: Any] = [
        "layerId": layer.layerId,
        "bucket": layer.bucket,
        "attributionOnly": layer.attributionOnly,
    ]
    if let policyId = layer.policyId { out["policyId"] = policyId }
    if let policyKey = layer.policyKey { out["policyKey"] = policyKey }
    if let allocationId = layer.allocationId { out["allocationId"] = allocationId }
    if let allocationName = layer.allocationName { out["allocationName"] = allocationName }
    if let allocationKey = layer.allocationKey { out["allocationKey"] = allocationKey }
    if let unitKey = layer.unitKey { out["unitKey"] = unitKey }
    if let unitKeyValue = layer.unitKeyValue { out["unitKeyValue"] = unitKeyValue }
    if let probability = layer.probability { out["probability"] = probability }
    if let modelVersion = layer.modelVersion { out["modelVersion"] = modelVersion }
    return out
}

/// In-memory event queue with size + interval + lifecycle-triggered flushes,
/// plus on-disk persistence of failed batches for retry on next launch.
public final class EventLogger: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var batchSize: Int
        public var flushIntervalMs: Int
        public var maxQueueSize: Int

        public init(batchSize: Int = 50, flushIntervalMs: Int = 30_000, maxQueueSize: Int = 500) {
            self.batchSize = batchSize
            self.flushIntervalMs = flushIntervalMs
            self.maxQueueSize = maxQueueSize
        }
    }

    private let http: TrafficalHTTPClient
    private let configuration: Configuration
    private let failedBatchURL: URL
    private let lifecycleProvider: LifecycleProvider

    private var queue: [TrafficalQueuedEvent] = []
    private let queueLock = NSLock()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "io.traffical.event-logger")

    public init(
        http: TrafficalHTTPClient,
        projectId: String,
        env: String,
        lifecycleProvider: LifecycleProvider,
        configuration: Configuration = Configuration(),
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.http = http
        self.configuration = configuration
        self.lifecycleProvider = lifecycleProvider
        let base = directory ?? BundleCache.defaultDirectory(fileManager: fileManager)
        try? fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        self.failedBatchURL = base.appendingPathComponent("failed-events-\(projectId)-\(env).json")

        lifecycleProvider.onVisibilityChange { [weak self] state in
            guard let self = self, state == .background else { return }
            Task { try? await self.flush() }
        }
        lifecycleProvider.onWillTerminate { [weak self] in
            // Synchronous best-effort flush — we may be interrupted at any
            // moment, so we just persist the queue to disk for next launch.
            self?.persistQueueOnDisk()
        }

        startFlushTimer()
    }

    deinit { timer?.cancel() }

    public func log(_ event: TrafficalQueuedEvent) {
        queueLock.lock()
        queue.append(event)
        if queue.count > configuration.maxQueueSize {
            // Drop oldest events to bound memory.
            queue.removeFirst(queue.count - configuration.maxQueueSize)
        }
        let shouldFlush = queue.count >= configuration.batchSize
        queueLock.unlock()
        if shouldFlush { Task { try? await self.flush() } }
    }

    /// Posts everything in the queue + any disk-resident failed batches.
    public func flush() async throws {
        let pending = drainQueue().map(\.payload)
        let failed = loadFailedPayloads()
        let combined = failed + pending
        if combined.isEmpty { return }

        do {
            try await postPayloads(combined)
            clearFailedBatches()
        } catch {
            // Persist combined batch to disk for retry on next launch / flush.
            persistPayloads(combined)
            throw error
        }
    }

    // MARK: - Internal

    private func startFlushTimer() {
        let interval = configuration.flushIntervalMs
        guard interval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { try? await self.flush() }
        }
        timer.resume()
        self.timer = timer
    }

    private func drainQueue() -> [TrafficalQueuedEvent] {
        queueLock.lock(); defer { queueLock.unlock() }
        let snapshot = queue
        queue = []
        return snapshot
    }

    private func postPayloads(_ payloads: [[String: Any]]) async throws {
        let body: [String: Any] = ["events": payloads]
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        let response = try await http.post(path: "v1/events/batch", body: data)
        guard (200..<300).contains(response.statusCode) else {
            throw TrafficalHTTPClient.Failure.invalidResponse
        }
    }

    private func persistPayloads(_ payloads: [[String: Any]]) {
        // We persist the unioned list — `payloads` already includes the
        // previously-failed ones (built by `flush`).
        let data = (try? JSONSerialization.data(withJSONObject: payloads, options: [])) ?? Data("[]".utf8)
        try? data.write(to: failedBatchURL, options: .atomic)
    }

    private func persistQueueOnDisk() {
        let pending = drainQueue().map(\.payload)
        if pending.isEmpty { return }
        let combined = loadFailedPayloads() + pending
        persistPayloads(combined)
    }

    private func loadFailedPayloads() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: failedBatchURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }

    private func clearFailedBatches() {
        try? FileManager.default.removeItem(at: failedBatchURL)
    }
}
