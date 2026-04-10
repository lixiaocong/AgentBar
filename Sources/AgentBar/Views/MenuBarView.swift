import AppKit
import SwiftUI

struct MenuBarView: View {
    let model: AppModel
    let openSettingsAction: () -> Void
    let onPreferredSizeChange: @MainActor (CGSize) -> Void

    static let minimumContentSize = CGSize(width: 360, height: 260)
    private let providerColumnWidth: CGFloat = 300

    init(
        model: AppModel,
        openSettingsAction: @escaping () -> Void = {},
        onPreferredSizeChange: @escaping @MainActor (CGSize) -> Void = { _ in }
    ) {
        self.model = model
        self.openSettingsAction = openSettingsAction
        self.onPreferredSizeChange = onPreferredSizeChange
    }

    var body: some View {
        let visibleProviders = model.availableProviders

        ScrollView([.horizontal, .vertical]) {
            content(visibleProviders: visibleProviders)
                .fixedSize(horizontal: true, vertical: true)
            .padding(12)
            .background(contentSizeReader)
        }
        .frame(
            minWidth: Self.minimumContentSize.width,
            minHeight: Self.minimumContentSize.height,
            alignment: .topLeading
        )
        .onPreferenceChange(MenuBarContentSizePreferenceKey.self) { size in
            let preferredSize = CGSize(
                width: max(size.width, Self.minimumContentSize.width),
                height: max(size.height, Self.minimumContentSize.height)
            )
            onPreferredSizeChange(preferredSize)
        }
    }

    @ViewBuilder
    private func content(visibleProviders: [AgentProviderKind]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if visibleProviders.isEmpty {
                Text("No supported agents detected on this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
            } else if model.snapshots.isEmpty && visibleProviders.allSatisfy({ model.errorMessage(for: $0) == nil }) {
                ProgressView("Loading agent usage…")
                Divider()
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(visibleProviders) { provider in
                        providerColumn(provider)
                    }
                }
                .padding(.vertical, 2)

                Divider()
            }

            controls
        }
    }

    @ViewBuilder
    private func providerColumn(_ provider: AgentProviderKind) -> some View {
        let statuses = model.visibleAccountStatuses(for: provider)

        VStack(alignment: .leading, spacing: 10) {
            providerColumnHeader(provider, accountCount: statuses.count)

            if statuses.isEmpty {
                Text("No configured accounts are visible for this provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(statuses) { status in
                    accountSection(status)
                }
            }
        }
        .frame(width: providerColumnWidth, alignment: .topLeading)
    }

    @ViewBuilder
    private func providerColumnHeader(
        _ provider: AgentProviderKind,
        accountCount: Int
    ) -> some View {
        let style = providerHeaderStyle(for: provider)
        let snapshot = model.snapshot(for: provider)
        let error = model.errorMessage(for: provider)

        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(style.eyebrow)
                    .font(.system(.caption2, design: .rounded).weight(.black))
                    .tracking(1)
                    .foregroundStyle(style.tint)

                Text(style.title)
                    .font(.system(.title3, design: .rounded).weight(.heavy))

                Text(accountCount == 1 ? "1 account" : "\(accountCount) accounts")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let metric = snapshot?.highlightMetric {
                    Text(metric.percentText)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()

                    Text("remaining")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if snapshot != nil {
                    Text("Ready")
                        .font(.system(size: 18, weight: .bold, design: .rounded))

                    Text("linked")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if error != nil {
                    Text("!")
                        .font(.system(size: 22, weight: .bold, design: .rounded))

                    Text("error")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("...")
                        .font(.system(size: 22, weight: .bold, design: .rounded))

                    Text("loading")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
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
    private func accountSection(_ status: AgentAccountStatus) -> some View {
        let style = providerHeaderStyle(for: status.provider)

        VStack(alignment: .leading, spacing: 10) {
            accountHeader(status, snapshot: status.snapshot)

            if let snapshot = status.snapshot {
                ForEach(snapshot.metrics) { metric in
                    quotaBlock(metric: metric)
                }

                if snapshot.metrics.isEmpty {
                    Text("Local auth was detected for this provider, but AgentBar does not have quota metrics for it yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                detailRow(label: "Config", value: status.displayPath)
                detailRow(label: "Source", value: snapshot.sourceSummary)
                if let planType = snapshot.planType {
                    detailRow(label: "Plan", value: formattedPlan(planType))
                }
                if let modelName = snapshot.modelName {
                    detailRow(label: "Model", value: modelName)
                }
                detailRow(label: "Updated", value: snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened))
            } else if let error = status.errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                detailRow(label: "Config", value: status.displayPath)
            } else {
                ProgressView("Loading account usage…")
                    .controlSize(.small)
                detailRow(label: "Config", value: status.displayPath)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.tint.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(style.tint.opacity(0.12), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func accountHeader(
        _ status: AgentAccountStatus,
        snapshot: AgentQuotaSnapshot?
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot?.accountLabel ?? "Configured account")
                    .font(.subheadline.weight(.semibold))

                Text(status.displayPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let metric = snapshot?.highlightMetric {
                    Text(metric.percentText)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()

                    Text("remaining")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if snapshot != nil {
                    Text("Ready")
                        .font(.system(size: 16, weight: .bold, design: .rounded))

                    Text("linked")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func quotaBlock(metric: AgentQuotaMetric) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title)
                .font(.subheadline.weight(.semibold))

            ProgressView(value: metric.remainingPercent, total: 100)
                .tint(quotaTint(for: metric))

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

    private func quotaTint(for metric: AgentQuotaMetric) -> Color {
        switch metric.remainingPercent {
        case 75...:
            return .green
        case 45..<75:
            return .yellow
        case 20..<45:
            return .orange
        default:
            return .red
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
                .multilineTextAlignment(.trailing)
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
        case .claude:
            return ("ANTHROPIC", "Claude", .brown)
        }
    }

    private var contentSizeReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MenuBarContentSizePreferenceKey.self, value: proxy.size)
        }
    }
}

private struct MenuBarContentSizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
