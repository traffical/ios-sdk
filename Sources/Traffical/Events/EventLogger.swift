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
///
/// Everything is bounded (spec S11 / event delivery): the in-memory queue and
/// the persisted backlog share `maxQueueSize` (oldest dropped first), delivery
/// is chunked, a flush is single-flight, and a payload the endpoint rejects
/// permanently is dropped instead of being retried forever.
public final class EventLogger: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var batchSize: Int
        public var flushIntervalMs: Int
        public var maxQueueSize: Int
        /// Event-delivery request timeout (spec default: 10s).
        public var timeoutMs: Int

        public init(batchSize: Int = 10, flushIntervalMs: Int = 30_000, maxQueueSize: Int = 500, timeoutMs: Int = 10_000) {
            self.batchSize = batchSize
            self.flushIntervalMs = flushIntervalMs
            self.maxQueueSize = maxQueueSize
            self.timeoutMs = timeoutMs
        }
    }

    /// Hooks the client uses to count and report contained failures.
    public struct Reporter: Sendable {
        public var onError: @Sendable (String, Error) -> Void
        public var onDrop: @Sendable (Int) -> Void

        public init(
            onError: @escaping @Sendable (String, Error) -> Void,
            onDrop: @escaping @Sendable (Int) -> Void
        ) {
            self.onError = onError
            self.onDrop = onDrop
        }
    }

    /// A persisted backlog larger than this is discarded unread: it can only
    /// come from an older SDK build or corruption, and reading it would cost
    /// more memory than the events are worth.
    static let maxBacklogFileBytes = 5 * 1024 * 1024

    private let http: TrafficalHTTPClient
    private let configuration: Configuration
    private let failedBatchURL: URL
    private let lifecycleProvider: LifecycleProvider
    private let reporter: Reporter?

    private var queue: [TrafficalQueuedEvent] = []
    private let queueLock = NSLock()
    private var timer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "io.traffical.event-logger")
    /// The flush currently in flight. Concurrent callers join it instead of
    /// racing it for the backlog file.
    private var inFlightFlush: Task<Void, Error>?

    /// Auth kill-switch (spec: on HTTP 401 the SDK permanently disables event
    /// delivery for the process lifetime rather than spinning on a credential
    /// that will never succeed).
    private var permanentlyDisabled = false
    /// Bounded exponential backoff: consecutive transient failures push the
    /// next allowed flush further out, capped so retries never stampede.
    private var consecutiveFailures = 0
    private var nextRetryAt: Date?
    private let maxBackoffMs = 60_000

    public init(
        http: TrafficalHTTPClient,
        projectId: String,
        env: String,
        lifecycleProvider: LifecycleProvider,
        configuration: Configuration = Configuration(),
        directory: URL? = nil,
        fileManager: FileManager = .default,
        reporter: Reporter? = nil
    ) {
        self.http = http
        self.configuration = configuration
        self.lifecycleProvider = lifecycleProvider
        self.reporter = reporter
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

    private var maxQueueSize: Int { Swift.max(1, configuration.maxQueueSize) }
    /// Upper bound on events per delivery request, independent of
    /// `batchSize` (which only decides when an automatic flush triggers).
    static let maxEventsPerRequest = 100

    public func log(_ event: TrafficalQueuedEvent) {
        var dropped = 0
        let shouldFlush: Bool = queueLock.locked {
            // Auth kill-switch: once permanently disabled we neither buffer nor
            // deliver — dropping is intentional.
            if permanentlyDisabled { return false }
            queue.append(event)
            if queue.count > maxQueueSize {
                // Drop oldest events to bound memory.
                dropped = queue.count - maxQueueSize
                queue.removeFirst(dropped)
            }
            return queue.count >= configuration.batchSize
        }
        if dropped > 0 { reporter?.onDrop(dropped) }
        if shouldFlush { Task { await self.flushIfDue() } }
    }

    /// Automatic (timer / batch-trigger) flush that respects the auth
    /// kill-switch and exponential backoff so failing endpoints aren't
    /// hammered. Explicit `flush()` calls (lifecycle, `close()`, tests) bypass
    /// the backoff gate — they represent user intent.
    func flushIfDue() async {
        let due: Bool = queueLock.locked {
            !permanentlyDisabled && (nextRetryAt.map { $0 <= Date() } ?? true)
        }
        guard due else { return }
        try? await flush()
    }

    /// Posts everything in the queue + any disk-resident failed batches.
    ///
    /// Single-flight: a call made while a flush is in flight joins it, then
    /// flushes once more if events were queued after the joined flush drained
    /// the queue — so `close()` still delivers everything logged before it.
    public func flush() async throws {
        while true {
            let (task, owner) = acquireFlush()
            try await task.value
            if owner { return }
            let empty: Bool = queueLock.locked { queue.isEmpty }
            if empty { return }
        }
    }

    private func acquireFlush() -> (Task<Void, Error>, Bool) {
        queueLock.locked {
            if let existing = inFlightFlush { return (existing, false) }
            let task = Task<Void, Error> { [weak self] in
                guard let self = self else { return }
                defer { self.queueLock.locked { self.inFlightFlush = nil } }
                try await self.performFlush()
            }
            inFlightFlush = task
            return (task, true)
        }
    }

    private func performFlush() async throws {
        if queueLock.locked({ permanentlyDisabled }) { return }

        let pending = drainQueue().map(\.payload)
        let combined = bounded(loadFailedPayloads() + pending)
        if combined.isEmpty { return }

        var index = 0
        while index < combined.count {
            let end = Swift.min(index + Self.maxEventsPerRequest, combined.count)
            let chunk = Array(combined[index..<end])
            do {
                try await postPayloads(chunk)
                index = end
            } catch is AuthFailure {
                // HTTP 401 — permanently disable delivery and discard buffered
                // events (they will never be accepted with this credential).
                queueLock.locked {
                    permanentlyDisabled = true
                    queue.removeAll()
                }
                clearFailedBatches()
                reporter?.onError("events.flush", TrafficalSDKError("event delivery disabled: HTTP 401"))
                return
            } catch let rejection as PermanentRejection {
                // The endpoint will never accept this payload (e.g. 400/413):
                // drop it rather than resending a poison batch forever.
                reporter?.onDrop(chunk.count)
                reporter?.onError("events.flush", rejection)
                index = end
            } catch {
                // Transient failure: persist what is left for retry and advance
                // the backoff.
                persistPayloads(Array(combined[index...]))
                queueLock.locked {
                    consecutiveFailures += 1
                    let backoff = Swift.min(maxBackoffMs, 1_000 * (1 << Swift.min(consecutiveFailures, 6)))
                    nextRetryAt = Date().addingTimeInterval(TimeInterval(backoff) / 1000.0)
                }
                reporter?.onError("events.flush", error)
                throw error
            }
        }

        clearFailedBatches()
        queueLock.locked {
            consecutiveFailures = 0
            nextRetryAt = nil
        }
    }

    /// Thrown by `postPayloads` on an HTTP 401 to trip the auth kill-switch.
    private struct AuthFailure: Error {}

    /// Thrown for a response the endpoint will never accept on retry.
    private struct PermanentRejection: Error, CustomStringConvertible {
        let statusCode: Int
        var description: String { "event batch rejected with HTTP \(statusCode); dropped" }
    }

    // MARK: - Internal

    private func startFlushTimer() {
        let interval = configuration.flushIntervalMs
        guard interval > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + .milliseconds(interval), repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            Task { await self.flushIfDue() }
        }
        timer.resume()
        self.timer = timer
    }

    private func drainQueue() -> [TrafficalQueuedEvent] {
        queueLock.locked {
            let snapshot = queue
            queue = []
            return snapshot
        }
    }

    /// Keeps the newest `maxQueueSize` payloads, counting the rest as dropped.
    private func bounded(_ payloads: [[String: Any]]) -> [[String: Any]] {
        guard payloads.count > maxQueueSize else { return payloads }
        let overflow = payloads.count - maxQueueSize
        reporter?.onDrop(overflow)
        return Array(payloads.suffix(maxQueueSize))
    }

    private func postPayloads(_ payloads: [[String: Any]]) async throws {
        let body: [String: Any] = ["events": payloads]
        let data: Data
        do {
            data = try TrafficalJSONWriter.data(body)
        } catch {
            // Unserializable even after sanitizing: retrying cannot help.
            throw PermanentRejection(statusCode: 0)
        }
        let response = try await http.post(path: "v1/events/batch", body: data, timeoutMs: configuration.timeoutMs)
        let status = response.statusCode
        if (200..<300).contains(status) { return }
        if status == 401 { throw AuthFailure() }
        // 408 Request Timeout and 429 Too Many Requests are worth retrying, as
        // is any 5xx. Every other 4xx is a permanent rejection of the payload.
        if (400..<500).contains(status), status != 408, status != 429 {
            throw PermanentRejection(statusCode: status)
        }
        throw TrafficalHTTPClient.Failure.invalidResponse
    }

    /// Test/introspection hook: whether the auth kill-switch has tripped.
    public var isPermanentlyDisabled: Bool {
        queueLock.locked { permanentlyDisabled }
    }

    private func persistPayloads(_ payloads: [[String: Any]]) {
        // `payloads` already includes the previously-failed ones (built by
        // `performFlush`), so the file is replaced, not appended to.
        do {
            let data = try TrafficalJSONWriter.data(bounded(payloads))
            try data.write(to: failedBatchURL, options: .atomic)
        } catch {
            reporter?.onError("events.persist", error)
        }
    }

    private func persistQueueOnDisk() {
        let pending = drainQueue().map(\.payload)
        if pending.isEmpty { return }
        persistPayloads(loadFailedPayloads() + pending)
    }

    private func loadFailedPayloads() -> [[String: Any]] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: failedBatchURL.path) else { return [] }
        if let size = (try? fileManager.attributesOfItem(atPath: failedBatchURL.path))?[.size] as? Int,
           size > Self.maxBacklogFileBytes {
            clearFailedBatches()
            reporter?.onError("events.backlog", TrafficalSDKError("persisted event backlog of \(size) bytes discarded"))
            return []
        }
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
