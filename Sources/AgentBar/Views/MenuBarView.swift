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
    private let providerColumnWidth: CGFloat = 264

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
                    .padding(16)
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

        HStack(alignment: .center, spacing: 10) {
            providerIconBadge(style, tint: statusTint)

            VStack(alignment: .leading, spacing: 3) {
                Text(style.eyebrow)
                    .font(.system(.caption2, design: .rounded).weight(.black))
                    .tracking(1.2)
                    .foregroundStyle(statusTint)
                    .lineLimit(1)

                Text(style.title)
                    .font(.system(.headline, design: .rounded).weight(.heavy))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(accountCount == 1 ? "1 account" : "\(accountCount) accounts")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

            Spacer()

            providerSummaryValue(snapshot: snapshot, error: error, tint: statusTint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusTint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(statusTint.opacity(0.16), lineWidth: 1)
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

        VStack(alignment: .leading, spacing: 9) {
            accountHeader(status, snapshot: status.snapshot, statusTint: statusTint)

            if let snapshot = status.snapshot {
                if snapshot.metrics.isEmpty {
                    Text(snapshot.sourceSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    metricsStack(snapshot.metrics)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusTint.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(statusTint.opacity(0.13), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func accountHeader(
        _ status: AgentAccountStatus,
        snapshot: AgentQuotaSnapshot?,
        statusTint: Color
    ) -> some View {
        let badges = accountBadges(provider: status.provider, snapshot: snapshot)

        VStack(alignment: .leading, spacing: 4) {
            if !badges.isEmpty ||
                compactAccountStateLabel(status: status, snapshot: snapshot) != nil {
                HStack(spacing: 5) {
                    if badges.isEmpty,
                       let stateLabel = compactAccountStateLabel(status: status, snapshot: snapshot) {
                        accountBadge(stateLabel, tint: statusTint)
                    } else {
                        ForEach(badges, id: \.self) { badge in
                            accountBadge(badge, tint: statusTint)
                        }
                    }
                }
            }

            NonHyphenatingLabel(snapshot?.accountLabel ?? status.accountLabel ?? "Configured account")
                .font(.headline.weight(.heavy))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func metricsStack(_ metrics: [AgentQuotaMetric]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Divider()
                        .opacity(0.28)
                }

                quotaBlock(metric: metric)
            }
        }
    }

    @ViewBuilder
    private func quotaBlock(metric: AgentQuotaMetric) -> some View {
        let tint = quotaTint(for: metric)

        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                QuotaMetricTitle(title: metric.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .help(metric.title)

                Text(compactRemainingLabel(metric.remainingLabel))
                    .font(.system(.caption, design: .rounded).weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(3)
            }

            quotaBar(value: metric.remainingPercent, tint: tint)

            HStack(spacing: 8) {
                Text(metric.usedLabel)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let resetsAt = metric.resetsAt {
                    Text("Resets \(resetsAt, style: .relative) at \(resetsAt.formatted(date: .omitted, time: .shortened))")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
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
        .frame(height: 5)
    }

    private func quotaTint(for metric: AgentQuotaMetric) -> Color {
        quotaTint(for: metric.remainingPercent)
    }

    private func compactRemainingLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        let normalized = trimmed.replacingOccurrences(of: " / ", with: "/")

        if lowercased.hasSuffix(" monthly credits left") {
            return normalized.replacingOccurrences(
                of: " monthly credits left",
                with: " left",
                options: [.caseInsensitive]
            )
        }

        return normalized
    }

    private func accountBadges(provider: AgentProviderKind, snapshot: AgentQuotaSnapshot?) -> [String] {
        let values: [String?]
        if provider == .codex {
            values = [
                trimmedSpaceLabel(snapshot?.spaceLabel),
                userFacingPlanLabel(snapshot?.planType)
            ]
        } else {
            values = [
                userFacingPlanLabel(snapshot?.planType),
                trimmedSpaceLabel(snapshot?.spaceLabel)
            ]
        }

        return values
        .compactMap { $0 }
        .reduce(into: [String]()) { result, badge in
            if !result.contains(badge) {
                result.append(badge)
            }
        }
    }

    private func userFacingPlanLabel(_ value: String?) -> String? {
        guard let trimmed = trimmedSpaceLabel(value) else {
            return nil
        }

        switch trimmed.lowercased() {
        case "prolite":
            return nil
        default:
            return trimmed
        }
    }

    private func compactAccountStateLabel(status: AgentAccountStatus, snapshot: AgentQuotaSnapshot?) -> String? {
        if snapshot?.metrics.isEmpty == false {
            return nil
        }

        if snapshot != nil {
            return "Ready"
        }

        if status.errorMessage != nil {
            return "Error"
        }

        return "Loading"
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
        Color(agentQuotaRGB: AgentQuotaDisplayColor.color(for: remainingPercent))
    }

    private func providerIconBadge(_ style: ProviderHeaderStyle, tint: Color) -> some View {
        Image(style.assetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 21, height: 21)
            .frame(width: 34, height: 34)
            .background(.background.opacity(0.82), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(0.18), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func providerSummaryValue(
        snapshot: AgentQuotaSnapshot?,
        error: String?,
        tint: Color
    ) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let metric = snapshot?.highlightMetric {
                Text(metric.percentText)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)

                Text("remaining")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if snapshot != nil {
                Text("Ready")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)

                Text("linked")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else if error != nil {
                Text("!")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)

                Text("error")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("...")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)

                Text("loading")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func accountBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.subheadline.weight(.heavy))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.14), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(tint.opacity(0.20), lineWidth: 1)
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

    private func providerHeaderStyle(for provider: AgentProviderKind) -> ProviderHeaderStyle {
        switch provider {
        case .codex:
            return ProviderHeaderStyle(eyebrow: "OPENAI", title: "Codex", assetName: "ProviderLogoCodex", tint: .orange)
        case .githubCopilot:
            return ProviderHeaderStyle(eyebrow: "GITHUB", title: "Copilot", assetName: "ProviderLogoCopilot", tint: .green)
        case .gemini:
            return ProviderHeaderStyle(eyebrow: "GOOGLE", title: "Gemini", assetName: "ProviderLogoGemini", tint: .green)
        case .claude:
            return ProviderHeaderStyle(eyebrow: "ANTHROPIC", title: "Claude", assetName: "ProviderLogoClaude", tint: .purple)
        case .junie:
            return ProviderHeaderStyle(eyebrow: "JETBRAINS", title: "Junie", assetName: "ProviderLogoJunie", tint: .orange)
        }
    }

    private var contentSizeReader: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: MenuBarContentSizePreferenceKey.self, value: proxy.size)
        }
    }
}

private extension Color {
    init(agentQuotaRGB rgb: AgentQuotaDisplayRGB) {
        self.init(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

private struct QuotaMetricTitle: View {
    let title: String

    var body: some View {
        if let parts = Self.windowTitleParts(from: title) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                if let prefix = parts.prefix {
                    Text(prefix)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0)
                }

                Text(parts.suffix)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        } else {
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private static func windowTitleParts(from title: String) -> (prefix: String?, suffix: String)? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        guard let match = windowSuffixPattern.firstMatch(in: trimmed, range: range),
              let suffixRange = Range(match.range, in: trimmed) else {
            return nil
        }

        let suffix = String(trimmed[suffixRange])
        let prefix = String(trimmed[..<suffixRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (prefix.isEmpty ? nil : prefix, suffix)
    }

    private static let windowSuffixPattern = try! NSRegularExpression(
        pattern: #"\b\d+\s+(?:minute|hour|day|week|month)s?\s+window$"#,
        options: [.caseInsensitive]
    )
}

private struct ProviderHeaderStyle {
    let eyebrow: String
    let title: String
    let assetName: String
    let tint: Color
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
