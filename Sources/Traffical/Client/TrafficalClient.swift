import Foundation
import TrafficalCore

/// Public SDK client.
///
/// One instance per (org, project, env) tuple. Backed by `TrafficalCore` for
/// resolution and `Traffical`'s networking + persistence + lifecycle layers
/// for everything else. The public surface is intentionally instance-based
/// (no static facade) so apps can run multiple clients in parallel for
/// staging/production splits, debug toggles, or per-feature isolation.
public final class TrafficalClient: @unchecked Sendable {
    public let options: TrafficalClientOptions

    private let http: TrafficalHTTPClient
    private let configFetcher: ConfigFetcher
    private let decisionClient: DecisionClient
    private let bundleCache: BundleCache
    private let serverCache: ServerResponseCache
    private let defaultsStore: DefaultsStore
    private let stableIDProvider: StableIDProvider
    private let lifecycleProvider: LifecycleProvider
    private let eventLogger: EventLogger
    private let errorBoundary: ErrorBoundary
    private let exposureDedup = ExposureDeduplicator()
    private let attributionMap = AttributionMap()
    private let assignmentEmitter: AssignmentLogEmitter?

    private let stateLock = NSLock()
    private var currentBundle: TrafficalConfigBundle?
    private var serverResponse: ServerResolveResponse?
    private var cachedEdgeOptions: ResolveOptions?
    private var etag: String?
    private var overrides: [String: TrafficalParameterValue] = [:]
    private var refreshTask: Task<Void, Never>?
    private(set) public var isInitialized: Bool = false

    public init(
        options: TrafficalClientOptions,
        urlSession: URLSession? = nil,
        keychain: KeychainStoreProtocol? = nil,
        directory: URL? = nil,
        lifecycleProvider: LifecycleProvider? = nil
    ) {
        self.options = options

        self.http = TrafficalHTTPClient(baseURL: options.baseURL, apiKey: options.apiKey, session: urlSession)
        self.configFetcher = ConfigFetcher(http: http, projectId: options.projectId, env: options.env)
        self.decisionClient = DecisionClient(http: http, orgId: options.orgId, projectId: options.projectId, env: options.env)
        self.bundleCache = BundleCache(projectId: options.projectId, env: options.env, directory: directory)
        self.serverCache = ServerResponseCache(projectId: options.projectId, env: options.env, directory: directory)
        self.defaultsStore = DefaultsStore()
        self.stableIDProvider = StableIDProvider(keychain: keychain ?? KeychainStore())
        self.lifecycleProvider = lifecycleProvider ?? UIKitLifecycleProvider()
        self.errorBoundary = ErrorBoundary()
        self.eventLogger = EventLogger(
            http: http,
            projectId: options.projectId,
            env: options.env,
            lifecycleProvider: self.lifecycleProvider,
            directory: directory
        )
        if let logger = options.assignmentLogger {
            self.assignmentEmitter = AssignmentLogEmitter(
                orgId: options.orgId,
                projectId: options.projectId,
                env: options.env,
                deduplicate: options.deduplicateAssignmentLogger,
                logger: logger
            )
        } else {
            self.assignmentEmitter = nil
        }

        // Seed from local (compiled-in) and disk-cached bundles before any
        // network call so the first synchronous `getParams` / typed getter
        // already has something to work with.
        if let local = options.localConfig {
            self.currentBundle = local
        } else if let cached = bundleCache.readBundle() {
            self.currentBundle = cached
        }
        if let cachedServer = serverCache.read() {
            self.serverResponse = cachedServer
        }
        self.etag = defaultsStore.string(forKey: "etag")

        // Foreground -> refresh in the background.
        self.lifecycleProvider.onVisibilityChange { [weak self] state in
            guard let self = self, state == .foreground else { return }
            Task { try? await self.refresh() }
        }
    }

    deinit { refreshTask?.cancel() }

    // MARK: - Initialization

    /// Fetches the initial bundle (or server response) from the network. The
    /// SDK is safe to call before this returns — it will use `localConfig`,
    /// the disk cache, or your inline defaults. `initialize` upgrades that to
    /// fresh state.
    public func initialize() async {
        await errorBoundary.captureAsync("initialize") { [weak self] in
            guard let self = self else { return }
            switch self.options.evaluationMode {
            case .bundle: try await self.refreshBundle()
            case .server: try await self.refreshServer()
            }
            self.startBackgroundRefresh()
            self.stateLock.lock()
            self.isInitialized = true
            self.stateLock.unlock()
        }
    }

    public func shutdown() {
        refreshTask?.cancel()
        Task { try? await self.eventLogger.flush() }
    }

    // MARK: - Identity

    public func getStableID() -> String { stableIDProvider.getID() }

    public func identify(_ unitKey: String) {
        stableIDProvider.setID(unitKey)
        exposureDedup.clear()
        attributionMap.clearAll()
        if options.evaluationMode == .server {
            Task { try? await self.refreshServer() }
        }
    }

    // MARK: - Typed getters (auto-track exposure)

    public func string(_ key: String, default defaultValue: String, context: TrafficalContext = [:]) -> String {
        let value = decideAndExpose(key: key, defaults: [key: .string(defaultValue)], context: context)
        return value.stringValue ?? defaultValue
    }

    public func bool(_ key: String, default defaultValue: Bool, context: TrafficalContext = [:]) -> Bool {
        let value = decideAndExpose(key: key, defaults: [key: .bool(defaultValue)], context: context)
        return value.boolValue ?? defaultValue
    }

    public func double(_ key: String, default defaultValue: Double, context: TrafficalContext = [:]) -> Double {
        let value = decideAndExpose(key: key, defaults: [key: .number(defaultValue)], context: context)
        return value.numberValue ?? defaultValue
    }

    public func int(_ key: String, default defaultValue: Int, context: TrafficalContext = [:]) -> Int {
        let value = decideAndExpose(key: key, defaults: [key: .number(Double(defaultValue))], context: context)
        guard let n = value.numberValue else { return defaultValue }
        return Int(n)
    }

    public func json(_ key: String, default defaultValue: TrafficalJSON, context: TrafficalContext = [:]) -> TrafficalJSON {
        let value = decideAndExpose(key: key, defaults: [key: .json(defaultValue)], context: context)
        if case .json(let v) = value { return v }
        return defaultValue
    }

    // MARK: - Batch decide

    public func decide(
        defaults: [String: TrafficalParameterValue],
        context: TrafficalContext = [:]
    ) -> TrafficalDecisionResult {
        return errorBoundary.capture(
            "decide",
            fallback: TrafficalDecisionResult(
                decisionId: TrafficalIDGenerator.decisionId(),
                assignments: defaults,
                metadata: TrafficalDecisionMetadata(
                    timestamp: TrafficalTime.now(),
                    unitKeyValue: "",
                    layers: []
                )
            )
        ) {
            return self.computeDecision(defaults: defaults, context: context)
        }
    }

    /// Track an exposure event for a previously-computed decision. Caller
    /// uses this when they want to delay exposure until after the variant
    /// is actually shown (matches `@traffical/js-client`).
    public func trackExposure(_ decision: TrafficalDecisionResult) {
        guard !options.disableCloudEvents else {
            assignmentEmitter?.emit(decision: decision)
            return
        }
        let unitKey = decision.metadata.unitKeyValue
        guard !unitKey.isEmpty else { return }

        assignmentEmitter?.emit(decision: decision)

        for layer in decision.metadata.layers {
            guard let policyId = layer.policyId, let allocationName = layer.allocationName else { continue }
            if layer.attributionOnly { continue }
            if !exposureDedup.checkAndMark(unitKey: unitKey, policyId: policyId, allocationName: allocationName) {
                continue
            }
            let event = TrafficalExposureEvent(
                base: makeBase(unitKey: unitKey, context: decision.metadata.filteredContext),
                decisionId: decision.decisionId,
                assignments: decision.assignments,
                layers: decision.metadata.layers
            )
            eventLogger.log(.exposure(event))
        }
    }

    // MARK: - Track

    public func track(
        _ event: String,
        properties: [String: Any]? = nil,
        value: Double? = nil,
        decisionId: String? = nil
    ) {
        guard !options.disableCloudEvents else { return }
        let unitKey = getStableID()
        let attributionList: [TrafficalTrackAttribution]?
        switch options.attributionMode {
        case .cumulative:
            attributionList = attributionMap.attribution(for: unitKey).isEmpty
                ? nil
                : attributionMap.attribution(for: unitKey)
        case .decision:
            attributionList = nil
        }
        let trackEvent = TrafficalTrackEvent(
            base: makeBase(unitKey: unitKey, context: nil),
            event: event,
            decisionId: decisionId,
            value: value,
            properties: properties.map { TrafficalJSON.from(any: $0) },
            attribution: attributionList
        )
        eventLogger.log(.track(trackEvent))
    }

    // MARK: - Overrides

    public func applyOverrides(_ next: [String: TrafficalParameterValue]) {
        stateLock.lock()
        for (k, v) in next { overrides[k] = v }
        stateLock.unlock()
    }

    public func clearOverrides() {
        stateLock.lock(); overrides = [:]; stateLock.unlock()
    }

    public func getOverrides() -> [String: TrafficalParameterValue] {
        stateLock.lock(); defer { stateLock.unlock() }
        return overrides
    }

    // MARK: - Refresh

    public func refresh() async throws {
        switch options.evaluationMode {
        case .bundle: try await refreshBundle()
        case .server: try await refreshServer()
        }
    }

    private func refreshBundle() async throws {
        let current = etagSnapshot()
        let result = try await configFetcher.fetch(etag: current)
        if let bundle = result.bundle {
            // Persist + swap in.
            if let raw = try? JSONSerialization.data(withJSONObject: serialize(bundle: bundle)) {
                bundleCache.write(raw)
            }
            stateLock.lock()
            currentBundle = bundle
            etag = result.etag
            stateLock.unlock()
            defaultsStore.setString(result.etag, forKey: "etag")
        } else if result.notModified {
            // ETag matched — nothing to do.
        }
    }

    private func refreshServer() async throws {
        let response = try await decisionClient.resolve(context: enrichContext([:]))
        stateLock.lock()
        serverResponse = response
        stateLock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: serialize(serverResponse: response)) {
            serverCache.write(data)
        }
    }

    private func startBackgroundRefresh() {
        guard options.refreshIntervalMs > 0 else { return }
        let intervalNs = UInt64(options.refreshIntervalMs) * 1_000_000
        refreshTask = Task { [weak self] in
            while let self = self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                try? await self.refresh()
            }
        }
    }

    // MARK: - Internal computation

    private func decideAndExpose(
        key: String,
        defaults: [String: TrafficalParameterValue],
        context: TrafficalContext
    ) -> TrafficalParameterValue {
        let decision = computeDecision(defaults: defaults, context: context)
        trackExposure(decision)
        return decision.assignments[key] ?? defaults[key] ?? .string("")
    }

    private func computeDecision(
        defaults: [String: TrafficalParameterValue],
        context: TrafficalContext
    ) -> TrafficalDecisionResult {
        let enriched = enrichContext(context)

        let decision: TrafficalDecisionResult
        switch options.evaluationMode {
        case .server:
            decision = decideFromServerCache(defaults: defaults, context: enriched)
        case .bundle:
            let bundle = currentBundleSnapshot()
            let edgeOptions = cachedEdgeOptionsSnapshot() ?? ResolveOptions()
            decision = TrafficalCore.decide(
                bundle: bundle,
                context: enriched,
                defaults: defaults,
                options: edgeOptions
            )
        }

        // Apply overrides on top.
        let overridesSnapshot = currentOverrides()
        var assignments = decision.assignments
        for (k, v) in overridesSnapshot where assignments[k] != nil {
            assignments[k] = v
        }
        let final = TrafficalDecisionResult(
            decisionId: decision.decisionId,
            assignments: assignments,
            metadata: decision.metadata
        )

        attributionMap.record(decision: final)

        if options.trackDecisions && !options.disableCloudEvents {
            let event = TrafficalDecisionEvent(
                base: makeBase(unitKey: final.metadata.unitKeyValue, context: final.metadata.filteredContext),
                requestedParameters: Array(defaults.keys),
                assignments: final.assignments,
                layers: final.metadata.layers
            )
            eventLogger.log(.decision(event))
        }

        return final
    }

    private func decideFromServerCache(
        defaults: [String: TrafficalParameterValue],
        context: TrafficalContext
    ) -> TrafficalDecisionResult {
        stateLock.lock()
        let response = serverResponse
        stateLock.unlock()
        guard let response = response else {
            return TrafficalDecisionResult(
                decisionId: TrafficalIDGenerator.decisionId(),
                assignments: defaults,
                metadata: TrafficalDecisionMetadata(
                    timestamp: TrafficalTime.now(),
                    unitKeyValue: "",
                    layers: []
                )
            )
        }
        var assignments = defaults
        for (key, value) in response.assignments where assignments[key] != nil {
            assignments[key] = value
        }
        return TrafficalDecisionResult(
            decisionId: response.decisionId,
            assignments: assignments,
            metadata: response.metadata
        )
    }

    private func enrichContext(_ context: TrafficalContext) -> TrafficalContext {
        var merged = context
        // Stable ID under the configured unit key.
        let bundle = currentBundleSnapshot()
        let unitKey = bundle?.hashing.unitKey ?? "userId"
        if merged[unitKey] == nil {
            merged[unitKey] = .string(stableIDProvider.getID())
        }
        if let provider = options.deviceInfoProvider {
            for (k, v) in provider.deviceInfo() where merged[k] == nil {
                merged[k] = v
            }
        }
        return merged
    }

    private func makeBase(unitKey: String, context: TrafficalContext?) -> TrafficalBaseEvent {
        return TrafficalBaseEvent(
            id: TrafficalIDGenerator.exposureId(),
            orgId: options.orgId,
            projectId: options.projectId,
            env: options.env,
            unitKey: unitKey,
            timestamp: TrafficalTime.now(),
            context: context,
            sdkName: trafficalSDKName,
            sdkVersion: trafficalSDKVersion
        )
    }

    // MARK: - Snapshots

    private func currentBundleSnapshot() -> TrafficalConfigBundle? {
        stateLock.lock(); defer { stateLock.unlock() }
        return currentBundle
    }

    private func cachedEdgeOptionsSnapshot() -> ResolveOptions? {
        stateLock.lock(); defer { stateLock.unlock() }
        return cachedEdgeOptions
    }

    private func currentOverrides() -> [String: TrafficalParameterValue] {
        stateLock.lock(); defer { stateLock.unlock() }
        return overrides
    }

    private func etagSnapshot() -> String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return etag
    }
}

// MARK: - Bundle / response serialization for the disk cache
//
// We round-trip through Foundation JSON so failure to encode never crashes the
// app. The cache file is opaque to the rest of the SDK.

private func serialize(bundle: TrafficalConfigBundle) -> [String: Any] {
    var out: [String: Any] = [
        "version": bundle.version,
        "orgId": bundle.orgId,
        "projectId": bundle.projectId,
        "env": bundle.env,
        "hashing": ["unitKey": bundle.hashing.unitKey, "bucketCount": bundle.hashing.bucketCount],
        "parameters": bundle.parameters.map { param -> [String: Any] in
            [
                "key": param.key,
                "type": param.type,
                "default": param.default.asAny,
                "layerId": param.layerId,
                "namespace": param.namespace,
            ]
        },
        "layers": bundle.layers.map { layer -> [String: Any] in
            [
                "id": layer.id,
                "policies": layer.policies.map(serialize(policy:)),
            ]
        },
    ]
    if let state = bundle.entityState {
        var dict: [String: Any] = [:]
        for (policyId, policyState) in state {
            dict[policyId] = [
                "_global": serialize(weights: policyState.global),
                "entities": policyState.entities.reduce(into: [String: Any]()) { acc, kv in
                    acc[kv.key] = serialize(weights: kv.value)
                },
            ]
        }
        out["entityState"] = dict
    }
    return out
}

private func serialize(policy: BundlePolicy) -> [String: Any] {
    var dict: [String: Any] = [
        "id": policy.id,
        "state": policy.state.rawValue,
        "kind": policy.kind.rawValue,
        "allocations": policy.allocations.map { alloc -> [String: Any] in
            var a: [String: Any] = [
                "id": alloc.id,
                "name": alloc.name,
                "bucketRange": [alloc.bucketRange.start, alloc.bucketRange.end],
                "overrides": alloc.overrides.mapValues(\.asAny),
            ]
            if let key = alloc.key { a["key"] = key }
            return a
        },
        "conditions": policy.conditions.map { cond -> [String: Any] in
            var c: [String: Any] = ["field": cond.field, "op": cond.op]
            if let v = cond.value { c["value"] = v.asAny }
            if let vs = cond.values { c["values"] = vs.map(\.asAny) }
            return c
        },
    ]
    if let key = policy.key { dict["key"] = key }
    if let range = policy.eligibleBucketRange {
        dict["eligibleBucketRange"] = ["start": range.start, "end": range.end]
    }
    return dict
}

private func serialize(weights: EntityWeights) -> [String: Any] {
    return [
        "entityId": weights.entityId,
        "weights": weights.weights,
        "computedAt": weights.computedAt,
    ]
}

private func serialize(serverResponse response: ServerResolveResponse) -> [String: Any] {
    var out: [String: Any] = [
        "decisionId": response.decisionId,
        "assignments": response.assignments.mapValues(\.asAny),
        "metadata": [
            "timestamp": response.metadata.timestamp,
            "unitKeyValue": response.metadata.unitKeyValue,
            "layers": response.metadata.layers.map { layer -> [String: Any] in
                var dict: [String: Any] = [
                    "layerId": layer.layerId,
                    "bucket": layer.bucket,
                    "attributionOnly": layer.attributionOnly,
                ]
                if let p = layer.policyId { dict["policyId"] = p }
                if let n = layer.allocationName { dict["allocationName"] = n }
                return dict
            },
        ],
    ]
    if let v = response.stateVersion { out["stateVersion"] = v }
    if let ms = response.suggestedRefreshMs { out["suggestedRefreshMs"] = ms }
    return out
}
