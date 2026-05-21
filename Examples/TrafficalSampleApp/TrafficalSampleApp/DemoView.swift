import SwiftUI
import Traffical

struct DemoView: View {
    @EnvironmentObject var model: DemoModel

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                logsSection
                parametersSection
                identitySection
                eventsSection
                actionsSection
            }
            .navigationTitle("Traffical Debug")
            .listStyle(.insetGrouped)
        }
    }

    // MARK: Connection

    private var connectionSection: some View {
        Section("Connection") {
            kvRow("Org",        model.orgId)
            kvRow("Project",    model.projectId)
            kvRow("Env",        model.env)
            kvRow("API key",    maskKey(model.apiKey))
            kvRow("Bundle",     bundleStatusText, valueColor: bundleStatusColor)
            kvRow("Version",    model.bundleVersion ?? "—")
            kvRow("Refreshed",  relativeTime(model.lastRefresh) ?? "never")
        }
    }

    private var bundleStatusText: String {
        if model.bundleLoaded { return model.initialized ? "loaded" : "loading…" }
        return "no bundle"
    }
    private var bundleStatusColor: Color? {
        model.bundleLoaded ? .green : .orange
    }

    // MARK: Identity

    private var identitySection: some View {
        Section("Identity") {
            kvRow("Stable ID", model.stableID, monospaced: true)
            Button {
                model.reroll()
            } label: {
                Label("Re-roll user", systemImage: "shuffle")
            }
            Button {
                model.identifyAsMarcel()
            } label: {
                Label("Identify as marcel", systemImage: "person.crop.circle.badge.checkmark")
            }
        }
    }

    // MARK: Parameters

    private var parametersSection: some View {
        Section("Resolved parameters") {
            ForEach(model.resolved) { param in
                parameterRow(param)
            }
        }
    }

    private func parameterRow(_ param: ResolvedParameter) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(param.key)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                if let allocation = param.allocation {
                    Text(allocation)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.15)))
                        .foregroundStyle(.blue)
                }
            }
            HStack(spacing: 8) {
                Text("default")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(param.defaultValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Text("resolved")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .leading)
                Text(param.resolvedValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(param.differs ? .green : .primary)
                    .fontWeight(param.differs ? .semibold : .regular)
                    .lineLimit(1).truncationMode(.middle)
                if let bucket = param.bucket {
                    Spacer()
                    Text("bucket \(bucket)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Events

    private var eventsSection: some View {
        Section("Recent events") {
            if model.events.isEmpty {
                Text("No events yet")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(model.events) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: DemoEvent) -> some View {
        HStack(alignment: .top) {
            Text(event.label.uppercased())
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(event.color.opacity(0.15)))
                .foregroundStyle(event.color)
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.summary)
                    .font(.caption)
                    .lineLimit(2)
                Text(relativeTime(event.timestamp) ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Logs

    private var logsSection: some View {
        Section {
            if model.logs.isEmpty {
                Text("No SDK activity yet")
                    .foregroundStyle(.secondary)
                    .italic()
            } else {
                ForEach(model.logs) { log in
                    logRow(log)
                }
            }
        } header: {
            HStack {
                Text("SDK logs")
                Spacer()
                if !model.logs.isEmpty {
                    Button("Clear") { model.clearLogs() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
    }

    private func logRow(_ log: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(log.category.uppercased())
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(log.color.opacity(0.15)))
                    .foregroundStyle(log.color)
                if log.level != "info" {
                    Text(log.level.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.2)))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(timestampString(log.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(log.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
            if let url = log.details["url"] {
                Text(url)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            // Render remaining details as a compact key=value strip.
            let other = log.details.filter { $0.key != "url" && $0.key != "method" }
            if !other.isEmpty {
                Text(other.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Actions

    private var actionsSection: some View {
        Section("Actions") {
            Button {
                model.trackPurchase()
            } label: {
                Label("Track purchase", systemImage: "creditcard")
            }
            Button {
                Task { await model.refresh() }
            } label: {
                HStack {
                    Label("Refresh config", systemImage: "arrow.clockwise")
                    if model.refreshing {
                        Spacer()
                        ProgressView().scaleEffect(0.7)
                    }
                }
            }
            .disabled(model.refreshing)
        }
    }

    // MARK: Helpers

    private func kvRow(_ key: String, _ value: String, valueColor: Color? = nil, monospaced: Bool = false) -> some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .body)
                .foregroundStyle(valueColor ?? .primary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private func maskKey(_ key: String) -> String {
        guard key.count > 12 else { return key }
        let prefix = key.prefix(12)
        return "\(prefix)…"
    }

    private func relativeTime(_ date: Date?) -> String? {
        guard let date = date else { return nil }
        let delta = max(0, Int(-date.timeIntervalSinceNow))
        if delta < 1 { return "just now" }
        if delta < 60 { return "\(delta)s ago" }
        if delta < 3600 { return "\(delta / 60)m ago" }
        return "\(delta / 3600)h ago"
    }

    private func timestampString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
