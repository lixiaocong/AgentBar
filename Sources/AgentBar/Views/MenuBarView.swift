import AppKit
import SwiftUI

#if canImport(AgentBarCore)
import AgentBarCore
#endif

struct MenuBarView: View {
    let model: AppModel
    let openSettingsAction: () -> Void
    let onPreferredSizeChange: @MainActor (CGSize) -> Void

    static let minimumContentSize = CGSize(width: 280, height: 180)
    private let providerColumnWidth: CGFloat = 240

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

        VStack(alignment: .leading, spacing: 0) {
            ScrollView([.horizontal, .vertical]) {
                content(visibleProviders: visibleProviders)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }

            Divider()

            controls
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(contentSizeReader)
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
            } else if model.snapshots.isEmpty && visibleProviders.allSatisfy({ model.errorMessage(for: $0) == nil }) {
                ProgressView("Loading agent usage…")
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(visibleProviders) { provider in
                        providerColumn(provider)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private func providerColumn(_ provider: AgentProviderKind) -> some View {
        let statuses = model.visibleAccountStatuses(for: provider)

        VStack(alignment: .leading, spacing: 10) {
            providerColumnHeader(provider, accountCount: statuses.count)

            if statuses.isEmpty {
                providerPlaceholder(provider)
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
        let statusTint = panelTint(
            metric: snapshot?.highlightMetric,
            error: error,
            fallback: style.tint
        )

        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(style.eyebrow)
                    .font(.system(.caption2, design: .rounded).weight(.black))
                    .tracking(1)
                    .foregroundStyle(statusTint)

                Text(style.title)
                    .font(.system(.title3, design: .rounded).weight(.heavy))
                    .foregroundStyle(statusTint)

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
                        .foregroundStyle(statusTint)

                    Text("remaining")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if snapshot != nil {
                    Text("Ready")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(statusTint)

                    Text("linked")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if error != nil {
                    Text("!")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(statusTint)

                    Text("error")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("...")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(statusTint)

                    Text("loading")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusTint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusTint.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func providerPlaceholder(_ provider: AgentProviderKind) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.errorMessage(for: provider) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No configured accounts are visible for this provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func accountSection(_ status: AgentAccountStatus) -> some View {
        let style = providerHeaderStyle(for: status.provider)
        let statusTint = panelTint(
            metric: status.snapshot?.highlightMetric,
            error: status.errorMessage,
            fallback: style.tint
        )

        VStack(alignment: .leading, spacing: 8) {
            accountHeader(status, snapshot: status.snapshot, statusTint: statusTint)

            if let snapshot = status.snapshot {
                ForEach(snapshot.metrics) { metric in
                    quotaBlock(metric: metric)
                }

                if snapshot.metrics.isEmpty {
                    Text("Local auth detected, but no quota metrics are available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let error = status.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView("Loading account usage…")
                    .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusTint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusTint.opacity(0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func accountHeader(
        _ status: AgentAccountStatus,
        snapshot: AgentQuotaSnapshot?,
        statusTint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                NonHyphenatingLabel(snapshot?.accountLabel ?? status.accountLabel ?? "Configured account")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Text(accountContextLabel(for: status, snapshot: snapshot))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusTint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let metric = snapshot?.highlightMetric {
                    Text(metric.percentText)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(statusTint)

                    Text("remaining")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if snapshot != nil {
                    Text("Ready")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(statusTint)

                    Text("linked")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if status.errorMessage != nil {
                    Text("!")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(statusTint)

                    Text("error")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("...")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(statusTint)

                    Text("loading")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func quotaBlock(metric: AgentQuotaMetric) -> some View {
        let tint = quotaTint(for: metric)

        VStack(alignment: .leading, spacing: 6) {
            Text(metric.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)

            quotaBar(value: metric.remainingPercent, tint: tint)

            HStack {
                Text(metric.remainingLabel)
                    .foregroundStyle(tint)
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

    private func quotaBar(value: Double, tint: Color) -> some View {
        let progress = min(max(value, 0), 100) / 100

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.20))

                Capsule()
                    .fill(tint)
                    .frame(width: max(3, proxy.size.width * progress))
            }
        }
        .frame(height: 6)
    }

    private func quotaTint(for metric: AgentQuotaMetric) -> Color {
        quotaTint(for: metric.remainingPercent)
    }

    private func accountContextLabel(
        for status: AgentAccountStatus,
        snapshot: AgentQuotaSnapshot?
    ) -> String {
        guard status.provider == .codex,
              let spaceLabel = trimmedSpaceLabel(snapshot?.spaceLabel) else {
            return status.provider.title
        }

        return "\(status.provider.title): \(spaceLabel)"
    }

    private func trimmedSpaceLabel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func panelTint(
        metric: AgentQuotaMetric?,
        error: String?,
        fallback: Color
    ) -> Color {
        if error != nil {
            return .red
        }

        guard let metric else {
            return fallback
        }

        return quotaTint(for: metric.remainingPercent)
    }

    private func quotaTint(for remainingPercent: Double) -> Color {
        switch remainingPercent {
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
        HStack(spacing: 8) {

            Button("Settings…") {
                openSettingsAction()
            }

            Spacer(minLength: 0)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
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

struct NonHyphenatingLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: Self.displayText(for: text))
            .lineLimit(1)
            .truncationMode(.tail)
    }

    nonisolated static func displayText(for text: String) -> String {
        text.replacingOccurrences(of: "\u{00AD}", with: "")
    }
}
