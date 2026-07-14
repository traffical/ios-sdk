import Foundation
import TrafficalCore

/// Configuration for `TrafficalClient`.
public struct TrafficalClientOptions: Sendable {
    public var orgId: String
    public var projectId: String
    public var env: String
    public var apiKey: String
    public var baseURL: URL
    public var localConfig: TrafficalConfigBundle?
    public var evaluationMode: EvaluationMode
    public var refreshIntervalMs: Int
    public var attributionMode: AttributionMode
    public var trackDecisions: Bool
    public var disableCloudEvents: Bool
    public var deduplicateAssignmentLogger: Bool
    /// Exposure session-dedup on/off (spec S4, default on).
    public var deduplicateExposures: Bool
    /// Exposure session-dedup TTL (spec S4, default 30-minute client session).
    public var exposureSessionTtlMs: Int
    /// Events per delivery batch (spec default parity: 10).
    public var batchSize: Int
    /// Event flush cadence (spec default: 30s).
    public var flushIntervalMs: Int
    /// Config-fetch request timeout (spec default: 10s).
    public var configTimeoutMs: Int
    /// Event-delivery request timeout (spec default: 10s).
    public var eventsTimeoutMs: Int
    /// Server-resolve request timeout (spec default: 5s).
    public var resolveTimeoutMs: Int
    public var deviceInfoProvider: DeviceInfoProvider?
    public var assignmentLogger: TrafficalAssignmentLogger?
    public var debugLogger: TrafficalDebugLogger?

    public enum EvaluationMode: String, Sendable {
        case bundle
        case server
    }

    public enum AttributionMode: String, Sendable {
        case cumulative
        case decision
    }

    public init(
        orgId: String,
        projectId: String,
        env: String,
        apiKey: String,
        baseURL: URL = URL(string: "https://sdk.traffical.io")!,
        localConfig: TrafficalConfigBundle? = nil,
        evaluationMode: EvaluationMode = .bundle,
        refreshIntervalMs: Int = 60_000,
        attributionMode: AttributionMode = .cumulative,
        trackDecisions: Bool = true,
        disableCloudEvents: Bool = false,
        deduplicateAssignmentLogger: Bool = true,
        deduplicateExposures: Bool = true,
        exposureSessionTtlMs: Int = 1_800_000,
        batchSize: Int = 10,
        flushIntervalMs: Int = 30_000,
        configTimeoutMs: Int = 10_000,
        eventsTimeoutMs: Int = 10_000,
        resolveTimeoutMs: Int = 5_000,
        deviceInfoProvider: DeviceInfoProvider? = nil,
        assignmentLogger: TrafficalAssignmentLogger? = nil,
        debugLogger: TrafficalDebugLogger? = nil
    ) {
        self.orgId = orgId
        self.projectId = projectId
        self.env = env
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.localConfig = localConfig
        self.evaluationMode = evaluationMode
        self.refreshIntervalMs = refreshIntervalMs
        self.attributionMode = attributionMode
        self.trackDecisions = trackDecisions
        self.disableCloudEvents = disableCloudEvents
        self.deduplicateAssignmentLogger = deduplicateAssignmentLogger
        self.deduplicateExposures = deduplicateExposures
        self.exposureSessionTtlMs = exposureSessionTtlMs
        self.batchSize = batchSize
        self.flushIntervalMs = flushIntervalMs
        self.configTimeoutMs = configTimeoutMs
        self.eventsTimeoutMs = eventsTimeoutMs
        self.resolveTimeoutMs = resolveTimeoutMs
        self.deviceInfoProvider = deviceInfoProvider
        self.assignmentLogger = assignmentLogger
        self.debugLogger = debugLogger
    }
}
