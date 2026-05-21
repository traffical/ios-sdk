import SwiftUI
import Traffical

struct DemoView: View {
    @EnvironmentObject var model: DemoModel

    var body: some View {
        NavigationStack {
            List {
                Section("Identity") {
                    HStack {
                        Text("Stable ID")
                        Spacer()
                        Text(model.stableID)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                    }
                    Button("Re-roll user", systemImage: "shuffle") { model.reroll() }
                    Button("Identify as marcel", systemImage: "person.crop.circle.badge.checkmark") {
                        model.identifyAsMarcel()
                    }
                }

                Section("Resolved parameters") {
                    parameterRow("ui.color", value: model.color)
                    parameterRow("checkout.ctaText", value: model.ctaText)
                    parameterRow("mobile.onboarding_steps", value: "\(model.onboardingSteps)")
                }

                Section("Actions") {
                    Button("Track purchase", systemImage: "creditcard") { model.trackPurchase() }
                }

                if !model.initialized {
                    Section { ProgressView("Fetching config…") }
                }
            }
            .navigationTitle("Traffical")
        }
    }

    private func parameterRow(_ key: String, value: String) -> some View {
        HStack {
            Text(key).font(.system(.body, design: .monospaced))
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}
