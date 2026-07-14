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
    /// Session exposure dedup. `internal` (not `private`) only so conformance
    /// tests can pre-seed the `alreadyExposed` state from the shared vectors.
    let exposureDedup: ExposureDeduplicator
    private let attributionMap = AttributionMap()
    private let assignmentEmitter: AssignmentLogEmitter?

    private let stateLock = NSLock()
    private var currentBundle: TrafficalConfigBundle?
    /// Last-good server resolve. Backs the debug accessors and serves as the
    /// cold-start / cache-miss fallback for `decideFromServerCache`.
    private var serverResponse: ServerResolveResponse?
    /// Server-mode per-call context cache, keyed by a canonical hash of the
    /// enriched context (mirrors php-sdk `Client::$serverCache`). Each
    /// `decide()` / `getParams()` resolves against the context actually passed,
    /// not a single init-time snapshot resolved with an empty context.
    private var serverResponsesByContext: [String: ServerResolveResponse] = [:]
    /// Context keys with a background `/v1/resolve` already in flight, so
    /// repeated identical contexts don't stampede the edge.
    private var inFlightResolveKeys: Set<String> = []
    private var cachedEdgeOptions: ResolveOptions?
    private var etag: String?
    private var overrides: [String: TrafficalParameterValue] = [:]
    private var refreshTask: Task<Void, Never>?
    private var lastSuccessfulRefresh: Date?
    /// Server-suggested refresh cadence (ms); honored over the default when set.
    private var suggestedRefreshMs: Int?
    private(set) public var isInitialized: Bool = false

    // MARK: - Debug accessors
    //
    // Read-only snapshots intended for debug overlays / dev tools / sample
    // apps. They reflect the same internal state used by the resolver.

    /// The version string of the currently-active bundle, or `nil` if no
    /// bundle is cached. In server mode this returns the `stateVersion`
    /// reported by the most recent `/v1/resolve` response.
    public var configVersion: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return serverResponse?.stateVersion ?? currentBundle?.version
    }

    /// `true` when the SDK has a usable bundle (local, disk-cached, or
    /// network-fetched). In server mode, `true` once a cached resolve
    /// response is available.
    public var bundleLoaded: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return currentBundle != nil || serverResponse != nil
    }

    /// Timestamp of the last successful network refresh, or `nil` if the SDK
    /// has not yet talked to the backend in this session.
    public var lastRefreshAt: Date? {
        stateLock.lock(); defer { stateLock.unlock() }
        return lastSuccessfulRefresh
    }

    public init(
        options: TrafficalClientOptions,
        urlSession: URLSession? = nil,
        keychain: KeychainStoreProtocol? = nil,
        directory: URL? = nil,
        lifecycleProvider: LifecycleProvider? = nil
    ) {
        self.options = options

        self.http = TrafficalHTTPClient(
            baseURL: options.baseURL,
            apiKey: options.apiKey,
            session: urlSession,
            debugLogger: options.debugLogger
        )
        self.configFetcher = ConfigFetcher(http: http, projectId: options.projectId, env: options.env)
        self.decisionClient = DecisionClient(http: http, orgId: options.orgId, projectId: options.projectId, env: options.env, resolveTimeoutMs: options.resolveTimeoutMs)
        self.bundleCache = BundleCache(projectId: options.projectId, env: options.env, directory: directory)
        self.serverCache = ServerResponseCache(projectId: options.projectId, env: options.env, directory: directory)
        self.defaultsStore = DefaultsStore()
        self.stableIDProvider = StableIDProvider(keychain: keychain ?? KeychainStore())
        self.lifecycleProvider = lifecycleProvider ?? UIKitLifecycleProvider()
        self.errorBoundary = ErrorBoundary()
        self.exposureDedup = ExposureDeduplicator(
            ttl: TimeInterval(options.exposureSessionTtlMs) / 1000.0
        )
        self.eventLogger = EventLogger(
            http: http,
            projectId: options.projectId,
            env: options.env,
            lifecycleProvider: self.lifecycleProvider,
            configuration: EventLogger.Configuration(
                batchSize: options.batchSize,
                flushIntervalMs: options.flushIntervalMs,
                timeoutMs: options.eventsTimeoutMs
            ),
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
        self.etag = defaultsStore.string(forKey: etagDefaultsKey)

        // Foreground -> refresh in the background.
        self.lifecycleProvider.onVisibilityChange { [weak self] state in
            guard let self = self, state == .foreground else { return }
            Task { try? await self.refresh() }
        }
    }

    deinit { refreshTask?.cancel() }

    /// ETag persistence key, namespaced per (projectId, env) so a process
    /// running multiple clients can't cross-contaminate conditional-GET state.
    private var etagDefaultsKey: String { "etag-\(options.projectId)-\(options.env)" }

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

    /// Resolves once the first usable config is loaded, or the fail-open
    /// window elapses — it MUST NOT hang when the SDK fails open on an
    /// unavailable/malformed bundle.
    public func waitForReady(timeoutMs: Int = 5_000) async {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMs) / 1000.0)
        while !bundleLoaded && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Force an immediate out-of-band config refresh.
    public func refreshConfig() async throws { try await refresh() }

    /// Flush the event queue and await delivery of what is currently buffered.
    public func flushEvents() async { try? await eventLogger.flush() }

    /// The single teardown verb (spec A1). Cancels background refresh and
    /// AWAITS a final event flush before returning (replaces the old
    /// fire-and-forget `shutdown()`).
    public func close() async {
        refreshTask?.cancel()
        refreshTask = nil
        try? await eventLogger.flush()
    }

    // MARK: - Identity

    /// Stable-ID accessor. Canonical casing is `getStableId` (lowercase `d`).
    public func getStableId() -> String { stableIDProvider.getID() }

    public func identify(_ unitKey: String) {
        stableIDProvider.setID(unitKey)
        exposureDedup.clear()
        attributionMap.clearAll()
        switch options.evaluationMode {
        case .server:
            // The stable id (part of the unit key) changed, so every cached
            // per-context resolve is now stale — drop them and re-resolve.
            stateLock.lock()
            serverResponsesByContext.removeAll()
            inFlightResolveKeys.removeAll()
            stateLock.unlock()
            Task { try? await self.refreshServer() }
        case .bundle:
            // The stable id changed, so any prefetched edge results are stale —
            // re-prefetch against the new identity.
            if let bundle = currentBundleSnapshot() {
                Task { await self.prefetchEdgeResults(bundle: bundle) }
            }
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

    /// Full decision with metadata. Context-first argument order (spec A1).
    public func decide(
        context: TrafficalContext = [:],
        defaults: [String: TrafficalParameterValue]
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

    /// Resolved parameter assignments only (no decision metadata). Context-first
    /// argument order (spec A1). Does NOT auto-track exposure.
    public func getParams(
        context: TrafficalContext = [:],
        defaults: [String: TrafficalParameterValue]
    ) -> [String: TrafficalParameterValue] {
        return decide(context: context, defaults: defaults).assignments
    }

    /// Track an exposure event for a previously-computed decision. Caller
    /// uses this when they want to delay exposure until after the variant
    /// is actually shown (matches `@traffical/js-client`).
    public func trackExposure(_ decision: TrafficalDecisionResult) {
        let anonymousId = stableIDProvider.getID()
        guard !options.disableCloudEvents else {
            assignmentEmitter?.emit(decision: decision, type: .exposure, anonymousId: anonymousId)
            return
        }
        let unitKey = decision.metadata.unitKeyValue
        guard !unitKey.isEmpty else { return }

        assignmentEmitter?.emit(decision: decision, type: .exposure, anonymousId: anonymousId)

        // S4: emit exactly ONE exposure event per call, carrying ONLY
        // newly-exposed, non-attributionOnly layers. Session dedup is on by
        // default. If nothing survives filtering, emit NO event.
        var exposedLayers: [TrafficalLayerResolution] = []
        for layer in decision.metadata.layers {
            if layer.attributionOnly { continue }
            guard let policyId = layer.policyId, let allocationName = layer.allocationName else { continue }
            if options.deduplicateExposures,
               !exposureDedup.checkAndMark(unitKey: unitKey, policyId: policyId, allocationName: allocationName) {
                continue
            }
            exposedLayers.append(layer)
        }
        guard !exposedLayers.isEmpty else { return }

        let event = TrafficalExposureEvent(
            base: makeBase(unitKey: unitKey, context: decision.metadata.filteredContext),
            decisionId: decision.decisionId,
            assignments: decision.assignments,
            layers: exposedLayers,
            configVersion: decision.metadata.configVersion
        )
        eventLogger.log(.exposure(event))
    }

    // MARK: - Track

    /// Optional arguments for `track`, delivered as an options bag (spec A1) so
    /// `values` and `eventTimestamp` land fleet-wide.
    public struct TrackOptions: Sendable {
        /// Link this event to a prior `decide()`.
        public var decisionId: String?
        /// Override the unit for this event (else the stable id).
        public var unitKey: String?
        /// Single numeric value (e.g. revenue).
        public var value: Double?
        /// Multiple named numeric values.
        public var values: [String: Double]?
        /// Explicit event time (ISO 8601); else "now".
        public var eventTimestamp: String?

        public init(
            decisionId: String? = nil,
            unitKey: String? = nil,
            value: Double? = nil,
            values: [String: Double]? = nil,
            eventTimestamp: String? = nil
        ) {
            self.decisionId = decisionId
            self.unitKey = unitKey
            self.value = value
            self.values = values
            self.eventTimestamp = eventTimestamp
        }
    }

    public func track(
        _ event: String,
        properties: [String: Any]? = nil,
        options trackOptions: TrackOptions = TrackOptions()
    ) {
        guard !options.disableCloudEvents else { return }
        let unitKey = trackOptions.unitKey ?? getStableId()
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
            base: makeBase(unitKey: unitKey, context: nil, timestamp: trackOptions.eventTimestamp),
            event: event,
            decisionId: trackOptions.decisionId,
            value: trackOptions.value,
            values: trackOptions.values,
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
        logConfig(.info, "config refresh: fetching", details: current.map { ["if-none-match": $0] } ?? [:])
        do {
            let result = try await configFetcher.fetch(etag: current)
            if let bundle = result.bundle {
                // S8: validate a freshly-fetched bundle before it can replace a
                // known-good one. A bundle with a zero/negative bucketCount or an
                // empty unit key would make every hash degenerate — discard it
                // and keep the last-good cached bundle rather than crash or serve
                // garbage. (A structurally-undecodable bundle already fails open
                // via the ConfigFetcher decode error path.)
                guard bundle.hashing.bucketCount >= 1, !bundle.hashing.unitKey.isEmpty else {
                    logConfig(.error, "config bundle malformed; keeping last-good", details: [
                        "bucketCount": String(bundle.hashing.bucketCount),
                        "unitKey": bundle.hashing.unitKey.isEmpty ? "<empty>" : bundle.hashing.unitKey,
                    ])
                    return
                }
                // Persist + swap in.
                if let raw = try? JSONSerialization.data(withJSONObject: serialize(bundle: bundle)) {
                    bundleCache.write(raw)
                }
                stateLock.lock()
                currentBundle = bundle
                etag = result.etag
                lastSuccessfulRefresh = Date()
                if let s = result.suggestedRefreshMs { suggestedRefreshMs = s }
                stateLock.unlock()
                defaultsStore.setString(result.etag, forKey: etagDefaultsKey)
                logConfig(.info, "config bundle loaded", details: [
                    "version": bundle.version,
                    "parameters": String(bundle.parameters.count),
                    "layers": String(bundle.layers.count),
                    "etag": result.etag ?? "—",
                ])
                // Prefetch edge-mode per-entity results for the fresh bundle so
                // bundle-mode decide() can interleave them synchronously.
                await prefetchEdgeResults(bundle: bundle)
            } else if result.notModified {
                // ETag matched — bundle stays as-is but the refresh did succeed.
                stateLock.lock()
                lastSuccessfulRefresh = Date()
                if let s = result.suggestedRefreshMs { suggestedRefreshMs = s }
                stateLock.unlock()
                logConfig(.info, "config not modified (304)", details: ["etag": current ?? "—"])
            }
        } catch {
            logConfig(.error, "config refresh failed: \(error)", details: ["error": "\(error)"])
            throw error
        }
    }

    private func refreshServer() async throws {
        logConfig(.info, "server resolve: fetching")
        let context = enrichContext([:])
        do {
            _ = try await resolveAndCache(context: context, key: contextCacheKey(context))
        } catch {
            logConfig(.error, "server resolve failed: \(error)", details: ["error": "\(error)"])
            throw error
        }
    }

    /// Resolves an (already-enriched) context on the edge and stores the
    /// response both in the per-context cache and as the last-good snapshot.
    @discardableResult
    private func resolveAndCache(context: TrafficalContext, key: String) async throws -> ServerResolveResponse {
        let response = try await decisionClient.resolve(context: context)
        stateLock.lock()
        serverResponsesByContext[key] = response
        serverResponse = response
        lastSuccessfulRefresh = Date()
        if let s = response.suggestedRefreshMs { suggestedRefreshMs = Int(s) }
        stateLock.unlock()
        if let data = try? JSONSerialization.data(withJSONObject: serialize(serverResponse: response)) {
            serverCache.write(data)
        }
        logConfig(.info, "server resolve succeeded", details: [
            "decisionId": response.decisionId,
            "assignments": String(response.assignments.count),
        ])
        return response
    }

    /// Kicks off a background `/v1/resolve` for `context` if one is not already
    /// in flight for the same key. `decide()` / `getParams()` are synchronous
    /// and cannot await the network, so the cache converges to the contexts
    /// actually being evaluated while the current call degrades to the last-good
    /// snapshot (mirrors js-client `_maybeResolveForContext`).
    private func scheduleServerResolve(context: TrafficalContext, key: String) {
        stateLock.lock()
        if inFlightResolveKeys.contains(key) {
            stateLock.unlock()
            return
        }
        inFlightResolveKeys.insert(key)
        stateLock.unlock()
        Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.inFlightResolveKeys.remove(key)
                self.stateLock.unlock()
            }
            do {
                _ = try await self.resolveAndCache(context: context, key: key)
            } catch {
                self.logConfig(.error, "server resolve (per-context) failed: \(error)", details: ["error": "\(error)"])
            }
        }
    }

    private func logConfig(_ level: TrafficalDebugEvent.Level, _ message: String, details: [String: String] = [:]) {
        options.debugLogger?(TrafficalDebugEvent(category: .config, level: level, message: message, details: details))
    }

    private func startBackgroundRefresh() {
        guard options.refreshIntervalMs > 0 else { return }
        refreshTask = Task { [weak self] in
            while let self = self, !Task.isCancelled {
                // Honor a server `suggestedRefreshMs` over the default, and apply
                // ±10% jitter so clients don't stampede the config endpoint.
                self.stateLock.lock()
                let base = self.suggestedRefreshMs ?? self.options.refreshIntervalMs
                self.stateLock.unlock()
                let jittered = Double(base) * Double.random(in: 0.9...1.1)
                try? await Task.sleep(nanoseconds: UInt64(max(0, jittered)) * 1_000_000)
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

        assignmentEmitter?.emit(decision: final, type: .decision, anonymousId: stableIDProvider.getID())

        if options.trackDecisions && !options.disableCloudEvents {
            let event = TrafficalDecisionEvent(
                base: makeBase(unitKey: final.metadata.unitKeyValue, context: final.metadata.filteredContext),
                requestedParameters: Array(defaults.keys),
                assignments: final.assignments,
                layers: final.metadata.layers,
                configVersion: final.metadata.configVersion
            )
            eventLogger.log(.decision(event))
        }

        return final
    }

    private func decideFromServerCache(
        defaults: [String: TrafficalParameterValue],
        context: TrafficalContext
    ) -> TrafficalDecisionResult {
        // `context` is already enriched by `computeDecision`. Look up the
        // resolve response for THIS context, not a single init-time snapshot.
        let key = contextCacheKey(context)
        stateLock.lock()
        let perContext = serverResponsesByContext[key]
        let fallback = serverResponse
        stateLock.unlock()

        // On a per-context miss, converge the cache in the background so the
        // next decide() with this context resolves against the edge.
        if perContext == nil {
            scheduleServerResolve(context: context, key: key)
        }

        guard let response = perContext ?? fallback else {
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
        // Server mode: the version "evaluated against" is the resolve
        // response's stateVersion (mirrors `getConfigVersion()` in the JS SDK).
        var metadata = response.metadata
        if metadata.configVersion == nil { metadata.configVersion = response.stateVersion }
        return TrafficalDecisionResult(
            // Fresh decisionId per call — never reuse the resolve response's
            // decisionId across decisions (spec 0.7.0 S8).
            decisionId: TrafficalIDGenerator.decisionId(),
            assignments: assignments,
            metadata: metadata
        )
    }

    /// Canonical, order-independent cache key for a resolved context. Mirrors
    /// php-sdk's `md5(json_encode($context))` — sorted keys so equivalent
    /// contexts collapse to one edge round-trip and one cache slot.
    private func contextCacheKey(_ context: TrafficalContext) -> String {
        let any = contextToAny(context)
        if JSONSerialization.isValidJSONObject(any),
           let data = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        // Fall back to a stable textual form if the context isn't JSON-encodable.
        return context.keys.sorted().map { "\($0)=\(context[$0]!.asAny)" }.joined(separator: "&")
    }

    /// Prefetches edge-mode per-entity results so bundle-mode `decide()` can
    /// interleave them synchronously (mirrors js-client `_prefetchEdgeResults`).
    /// Collects every running `resolutionMode == .edge` policy, batch-resolves
    /// via `DecisionClient.decideEntityBatch`, and populates `cachedEdgeOptions`.
    /// Failures are swallowed (fail-open): the engine simply skips an edge
    /// policy whose result is absent.
    private func prefetchEdgeResults(bundle: TrafficalConfigBundle) async {
        let edgePolicies = bundle.layers.flatMap { $0.policies }.filter {
            $0.entityConfig?.resolutionMode == .edge && $0.state == .running
        }
        guard !edgePolicies.isEmpty else {
            stateLock.lock(); cachedEdgeOptions = nil; stateLock.unlock()
            return
        }

        let context = enrichContext([:])
        let unitKeyValue = getUnitKeyValue(bundle: bundle, context: context) ?? ""

        var requests: [EdgeDecideRequest] = []
        for policy in edgePolicies {
            guard let cfg = policy.entityConfig,
                  let entityId = buildEntityId(entityKeys: cfg.entityKeys, context: context) else { continue }
            var allocationCount: Int?
            if let dynamic = cfg.dynamicAllocations,
               let n = context[dynamic.countKey]?.numberProjection, n > 0 {
                allocationCount = Int(n.rounded(.down))
            }
            requests.append(EdgeDecideRequest(
                policyId: policy.id,
                entityId: entityId,
                entityKeys: cfg.entityKeys,
                context: context,
                unitKeyValue: unitKeyValue,
                allocationCount: allocationCount
            ))
        }
        guard !requests.isEmpty, let responses = try? await decisionClient.decideEntityBatch(requests) else { return }

        var results: [String: EdgeResult] = [:]
        for r in responses {
            results[r.policyId] = EdgeResult(allocationIndex: r.allocationIndex, entityId: r.entityId)
        }
        stateLock.lock(); cachedEdgeOptions = ResolveOptions(edgeResults: results); stateLock.unlock()
        logConfig(.info, "edge prefetch complete", details: ["policies": String(results.count)])
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

    private func makeBase(unitKey: String, context: TrafficalContext?, timestamp: String? = nil) -> TrafficalBaseEvent {
        return TrafficalBaseEvent(
            id: TrafficalIDGenerator.exposureId(),
            orgId: options.orgId,
            projectId: options.projectId,
            env: options.env,
            unitKey: unitKey,
            timestamp: timestamp ?? TrafficalTime.now(),
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
            var l: [String: Any] = [
                "id": layer.id,
                "policies": layer.policies.map(serialize(policy:)),
            ]
            if let unitKey = layer.unitKey { l["unitKey"] = unitKey }
            return l
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
    if let stateVersion = policy.stateVersion { dict["stateVersion"] = stateVersion }
    if let logging = policy.contextLogging {
        dict["contextLogging"] = ["allowedFields": logging.allowedFields]
    }
    if let model = policy.contextualModel {
        dict["contextualModel"] = serialize(contextualModel: model)
    }
    if let entityConfig = policy.entityConfig {
        var e: [String: Any] = [
            "entityKeys": entityConfig.entityKeys,
            "resolutionMode": entityConfig.resolutionMode.rawValue,
        ]
        if let timeout = entityConfig.edgeTimeoutMs { e["edgeTimeoutMs"] = timeout }
        if let dynamic = entityConfig.dynamicAllocations {
            e["dynamicAllocations"] = ["countKey": dynamic.countKey]
        }
        dict["entityConfig"] = e
    }
    return dict
}

private func serialize(contextualModel model: BundleContextualModel) -> [String: Any] {
    var dict: [String: Any] = [
        "gamma": model.gamma,
        "actionProbabilityFloor": model.actionProbabilityFloor,
        "defaultAllocationScore": model.defaultAllocationScore,
        "coefficients": model.coefficients.reduce(into: [String: Any]()) { acc, kv in
            acc[kv.key] = [
                "intercept": kv.value.intercept,
                "numeric": kv.value.numeric.map { ["key": $0.key, "coef": $0.coef, "missing": $0.missing] },
                "categorical": kv.value.categorical.map {
                    ["key": $0.key, "values": $0.values, "missing": $0.missing]
                },
            ]
        },
    ]
    if let generatedAt = model.generatedAt { dict["generatedAt"] = generatedAt }
    if let modelVersion = model.modelVersion { dict["modelVersion"] = modelVersion }
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
    var metadata: [String: Any] = [
        "timestamp": response.metadata.timestamp,
        "unitKeyValue": response.metadata.unitKeyValue,
        // Serialize the FULL per-layer resolution so a cold-start read resolves
        // (and attributes) identically to the live response.
        "layers": response.metadata.layers.map { layer -> [String: Any] in
            var dict: [String: Any] = [
                "layerId": layer.layerId,
                "bucket": layer.bucket,
                "attributionOnly": layer.attributionOnly,
            ]
            if let p = layer.policyId { dict["policyId"] = p }
            if let pk = layer.policyKey { dict["policyKey"] = pk }
            if let aid = layer.allocationId { dict["allocationId"] = aid }
            if let n = layer.allocationName { dict["allocationName"] = n }
            if let ak = layer.allocationKey { dict["allocationKey"] = ak }
            if let uk = layer.unitKey { dict["unitKey"] = uk }
            if let ukv = layer.unitKeyValue { dict["unitKeyValue"] = ukv }
            if let prob = layer.probability { dict["probability"] = prob }
            if let mv = layer.modelVersion { dict["modelVersion"] = mv }
            return dict
        },
    ]
    if let filtered = response.metadata.filteredContext {
        metadata["filteredContext"] = contextToAny(filtered)
    }
    if let cv = response.metadata.configVersion { metadata["configVersion"] = cv }

    var out: [String: Any] = [
        "decisionId": response.decisionId,
        "assignments": response.assignments.mapValues(\.asAny),
        "metadata": metadata,
    ]
    if let v = response.stateVersion { out["stateVersion"] = v }
    if let ms = response.suggestedRefreshMs { out["suggestedRefreshMs"] = ms }
    return out
}
