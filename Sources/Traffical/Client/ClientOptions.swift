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
        self.deviceInfoProvider = deviceInfoProvider
        self.assignmentLogger = assignmentLogger
        self.debugLogger = debugLogger
    }
}
