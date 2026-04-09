import AppKit
import SwiftUI

struct MenuBarView: View {
    let model: AppModel
    let openSettingsAction: () -> Void
    private let palette: [Color] = [.blue, .indigo, .teal]

    init(
        model: AppModel,
        openSettingsAction: @escaping () -> Void = {}
    ) {
        self.model = model
        self.openSettingsAction = openSettingsAction
    }

    var body: some View {
        let visibleProviders = model.availableProviders

        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if visibleProviders.isEmpty {
                    Text("No supported agents detected on this Mac.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider()
                } else if model.snapshots.isEmpty && visibleProviders.allSatisfy({ model.errorMessage(for: $0) == nil }) {
                    ProgressView("Loading agent usage…")
                    Divider()
                }

                ForEach(visibleProviders) { provider in
                    providerSection(
                        snapshot: model.snapshot(for: provider),
                        error: model.errorMessage(for: provider),
                        provider: provider
                    )
                }

                controls
            }
            .padding(12)
        }
        .frame(width: 340, height: 500)
    }

    @ViewBuilder
    private func providerSection(
        snapshot: AgentQuotaSnapshot?,
        error: String?,
        provider: AgentProviderKind
    ) -> some View {
        if let snapshot {
            header(snapshot: snapshot)

            ForEach(Array(snapshot.metrics.enumerated()), id: \.element.id) { index, metric in
                quotaBlock(metric: metric, tint: palette[index % palette.count])
            }

            detailRow(label: "Source", value: snapshot.sourceSummary)
            if let planType = snapshot.planType {
                detailRow(label: "Plan", value: formattedPlan(planType))
            }
            if let modelName = snapshot.modelName {
                detailRow(label: "Model", value: modelName)
            }
            detailRow(label: "Updated", value: snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))

            Divider()
        } else if let error {
            Text(providerHeaderStyle(for: provider).title)
                .font(.system(.title3, design: .rounded).weight(.bold))
            Text(error)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }

    @ViewBuilder
    private func header(snapshot: AgentQuotaSnapshot) -> some View {
        let style = providerHeaderStyle(for: snapshot.provider)

        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(style.eyebrow)
                    .font(.system(.caption2, design: .rounded).weight(.black))
                    .tracking(1)
                    .foregroundStyle(style.tint)

                Text(style.title)
                    .font(.system(.title3, design: .rounded).weight(.heavy))

                Text(snapshot.accountLabel)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(snapshot.highlightMetric?.percentText ?? "--")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()

                Text("remaining")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(style.tint.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func quotaBlock(metric: AgentQuotaMetric, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title)
                .font(.subheadline.weight(.semibold))

            ProgressView(value: metric.remainingPercent, total: 100)
                .tint(tint)

            HStack {
                Text(metric.remainingLabel)
                Spacer()
                Text(metric.usedLabel)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let resetsAt = metric.resetsAt {
                Text("Resets \(resetsAt, style: .relative) at \(resetsAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(model.isRefreshing ? "Refreshing..." : "Refresh Now") {
                model.refreshNow()
            }
            .disabled(model.isRefreshing)

            Button("Settings…") {
                logInfo("Settings button pressed")
                openSettingsAction()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
        .font(.caption)
    }

    private func formattedPlan(_ planType: String?) -> String {
        guard let planType, !planType.isEmpty else {
            return "Unknown"
        }

        return planType == planType.lowercased() ? planType.capitalized : planType
    }

    private func providerHeaderStyle(for provider: AgentProviderKind) -> (
        eyebrow: String,
        title: String,
        tint: Color
    ) {
        switch provider {
        case .codex:
            return ("OPENAI", "Codex", .blue)
        case .githubCopilot:
            return ("GITHUB", "Copilot", .green)
        case .gemini:
            return ("GOOGLE", "Gemini", .orange)
        }
    }
}
