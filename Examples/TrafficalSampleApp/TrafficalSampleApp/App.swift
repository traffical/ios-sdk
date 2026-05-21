import SwiftUI
import Traffical

private let demoOrgId = "org_0uM5pDR6"
private let demoProjectId = "proj_FYy8hd5j"
private let demoEnv = "production"
private let demoAPIKey = "traffical_sk_YHPH6OjwgRNGl81RwYIvLPGeVsrXLovp"

/// The three demo parameters mirror the YAML at
/// `.traffical/config.yaml`. Add policies to any of them in the dashboard
/// and re-rolling the user in the app will visibly flip the resolved values.
private let demoDefaults: [(key: String, defaultValue: TrafficalParameterValue)] = [
    ("ui.color",                .string("#1E6EFB")),
    ("checkout.ctaText",        .string("Subscribe")),
    ("mobile.onboarding_steps", .number(3)),
]

@main
struct TrafficalSampleApp: App {
    @StateObject private var model = DemoModel()

    var body: some Scene {
        WindowGroup {
            DemoView()
                .environmentObject(model)
                .task { await model.start() }
        }
    }
}

// MARK: - Demo model

@MainActor
final class DemoModel: ObservableObject {
    @Published var stableID: String = ""
    @Published var resolved: [ResolvedParameter] = []
    @Published var events: [DemoEvent] = []
    @Published var initialized = false
    @Published var refreshing = false
    @Published var bundleVersion: String? = nil
    @Published var bundleLoaded: Bool = false
    @Published var lastRefresh: Date? = nil

    let orgId = demoOrgId
    let projectId = demoProjectId
    let env = demoEnv
    let apiKey = demoAPIKey

    let client: TrafficalClient

    init() {
        let bridge = EventBridge()
        let options = TrafficalClientOptions(
            orgId: demoOrgId,
            projectId: demoProjectId,
            env: demoEnv,
            apiKey: demoAPIKey,
            evaluationMode: .bundle,
            deduplicateAssignmentLogger: false,
            deviceInfoProvider: DefaultDeviceInfoProvider(),
            assignmentLogger: { [bridge] entry in bridge.forwardExposure(entry) }
        )
        self.client = TrafficalClient(options: options)
        self.stableID = client.getStableID()
        bridge.attach(self)
        readSnapshot()
    }

    func start() async {
        await client.initialize()
        initialized = true
        readSnapshot()
        recordEvent(DemoEvent.systemEvent("config bundle initialized"))
    }

    func refresh() async {
        refreshing = true
        defer { refreshing = false }
        try? await client.refresh()
        readSnapshot()
        recordEvent(DemoEvent.systemEvent("config bundle refreshed"))
    }

    func reroll() {
        let newID = UUID().uuidString
        client.identify(newID)
        stableID = client.getStableID()
        recordEvent(DemoEvent.systemEvent("re-rolled user → \(shortID(newID))"))
        readSnapshot()
    }

    func identifyAsMarcel() {
        client.identify("demo_user_marcel")
        stableID = client.getStableID()
        recordEvent(DemoEvent.systemEvent("identified as demo_user_marcel"))
        readSnapshot()
    }

    func trackPurchase() {
        let orderId = "ord_\(Int.random(in: 1000...9999))"
        let value = 99.99
        client.track("purchase", properties: ["orderId": orderId], value: value)
        recordEvent(DemoEvent.trackEvent(name: "purchase", summary: "\(orderId) · $\(String(format: "%.2f", value))"))
    }

    // MARK: - Internals

    fileprivate func recordEvent(_ event: DemoEvent) {
        events.insert(event, at: 0)
        if events.count > 20 { events = Array(events.prefix(20)) }
    }

    /// Reads every demo parameter via `decide()` so we have both the
    /// pre-applied default and the resolved value, plus the matched
    /// allocation. Records an exposure for each call so the SDK's
    /// assignment-logger callback fires.
    fileprivate func readSnapshot() {
        bundleVersion = client.configVersion
        bundleLoaded = client.bundleLoaded
        lastRefresh = client.lastRefreshAt

        var out: [ResolvedParameter] = []
        for (key, fallback) in demoDefaults {
            let decision = client.decide(defaults: [key: fallback])
            client.trackExposure(decision)
            let resolvedValue = decision.assignments[key] ?? fallback
            let layer = decision.metadata.layers.first { $0.allocationName != nil }
            out.append(ResolvedParameter(
                key: key,
                defaultValue: stringify(fallback),
                resolvedValue: stringify(resolvedValue),
                differs: resolvedValue != fallback,
                allocation: layer?.allocationName,
                bucket: layer?.bucket
            ))
        }
        resolved = out
    }

    private func stringify(_ value: TrafficalParameterValue) -> String {
        switch value {
        case .string(let s): return s
        case .number(let n):
            return n.rounded() == n ? String(Int64(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .json: return "{json}"
        }
    }

    private func shortID(_ id: String) -> String {
        if id.count <= 8 { return id }
        return String(id.prefix(8)) + "…"
    }
}

// MARK: - DemoEvent

enum DemoEvent: Identifiable {
    case exposure(policyId: String, allocation: String, layerId: String, at: Date)
    case track(name: String, summary: String, at: Date)
    case system(message: String, at: Date)

    // Convenience constructors so callers can omit `at:`. Named to avoid
    // ambiguity with the enum cases.
    static func systemEvent(_ message: String) -> DemoEvent {
        .system(message: message, at: Date())
    }
    static func trackEvent(name: String, summary: String) -> DemoEvent {
        .track(name: name, summary: summary, at: Date())
    }
    static func exposureEvent(policyId: String, allocation: String, layerId: String) -> DemoEvent {
        .exposure(policyId: policyId, allocation: allocation, layerId: layerId, at: Date())
    }

    var id: String { "\(timestamp.timeIntervalSinceReferenceDate)-\(label)-\(summary)" }

    var timestamp: Date {
        switch self {
        case .exposure(_, _, _, let at), .track(_, _, let at), .system(_, let at):
            return at
        }
    }

    var label: String {
        switch self {
        case .exposure: return "exposure"
        case .track:    return "track"
        case .system:   return "system"
        }
    }

    var summary: String {
        switch self {
        case .exposure(let policyId, let allocation, _, _):
            return "\(policyId) → \(allocation)"
        case .track(let name, let summary, _):
            return "\(name) · \(summary)"
        case .system(let message, _):
            return message
        }
    }

    var color: Color {
        switch self {
        case .exposure: return .blue
        case .track:    return .green
        case .system:   return .secondary
        }
    }
}

// MARK: - Resolved parameter row

struct ResolvedParameter: Identifiable {
    let id: String
    let key: String
    let defaultValue: String
    let resolvedValue: String
    let differs: Bool
    let allocation: String?
    let bucket: Int?

    init(key: String, defaultValue: String, resolvedValue: String, differs: Bool, allocation: String?, bucket: Int?) {
        self.id = key
        self.key = key
        self.defaultValue = defaultValue
        self.resolvedValue = resolvedValue
        self.differs = differs
        self.allocation = allocation
        self.bucket = bucket
    }
}

// MARK: - Event bridge
//
// Created before the model is fully initialized, then attached, so the
// assignment-logger closure on `TrafficalClientOptions` (set during
// construction) can still reach the model once it exists.

final class EventBridge: @unchecked Sendable {
    private let lock = NSLock()
    private weak var model: DemoModel?

    func attach(_ model: DemoModel) {
        lock.lock(); defer { lock.unlock() }
        self.model = model
    }

    func forwardExposure(_ entry: TrafficalAssignmentLogEntry) {
        Task { @MainActor in
            self.model?.recordEvent(
                DemoEvent.exposureEvent(
                    policyId: entry.policyId,
                    allocation: entry.allocationName,
                    layerId: entry.layerId
                )
            )
        }
    }
}
