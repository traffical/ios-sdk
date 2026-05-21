import SwiftUI
import Traffical

/// Replace these with values from your Traffical dashboard. The defaults work
/// against the public `sdk.traffical.io` endpoint with a no-op project; for
/// meaningful values you'll want your real keys.
private let demoOrgId = "org_demo"
private let demoProjectId = "proj_demo"
private let demoEnv = "production"
private let demoAPIKey = "pk_live_REPLACE_ME"

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

@MainActor
final class DemoModel: ObservableObject {
    @Published var stableID: String = ""
    @Published var color: String = "—"
    @Published var ctaText: String = "—"
    @Published var onboardingSteps: Int = 0
    @Published var initialized = false

    let client: TrafficalClient

    init() {
        let options = TrafficalClientOptions(
            orgId: demoOrgId,
            projectId: demoProjectId,
            env: demoEnv,
            apiKey: demoAPIKey,
            evaluationMode: .bundle,
            deviceInfoProvider: DefaultDeviceInfoProvider()
        )
        self.client = TrafficalClient(options: options)
        self.stableID = client.getStableID()
        readParameters()
    }

    func start() async {
        await client.initialize()
        initialized = true
        readParameters()
    }

    func reroll() {
        client.identify(UUID().uuidString)
        stableID = client.getStableID()
        readParameters()
    }

    func identifyAsMarcel() {
        client.identify("demo_user_marcel")
        stableID = client.getStableID()
        readParameters()
    }

    func trackPurchase() {
        client.track("purchase", properties: ["orderId": "ord_\(Int.random(in: 1...9999))"], value: 99.99)
    }

    private func readParameters() {
        color = client.string("ui.color", default: "#1E6EFB")
        ctaText = client.string("checkout.ctaText", default: "Subscribe")
        onboardingSteps = client.int("mobile.onboarding_steps", default: 3)
    }
}
