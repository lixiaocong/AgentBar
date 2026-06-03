import AppIntents
import SwiftUI
import WidgetKit

#if canImport(AgentBarCore)
import AgentBarCore
#endif

// MARK: - Widget Configuration

struct AgentBarWidgetEntry: TimelineEntry {
    let date: Date
    let state: AgentWidgetState
    let selectedAgentID: String?
}

private enum AgentBarWidgetAccountValue {
    /// Returns a human-friendly display name for the Edit Widget picker.
    /// Format: "Provider: account (space)" or just "Provider" if no account label.
    static func widgetValue(for state: AgentWidgetProviderState) -> String {
        if let accountLabel = accountSubtitle(for: state) {
            return "\(state.provider.title): \(accountLabel)"
        }
        return state.provider.title
    }

    static func accountSubtitle(for state: AgentWidgetProviderState) -> String? {
        guard let label = state.displayLabel else {
            return nil
        }

        guard state.provider == .codex,
              let spaceLabel = trimmedSpaceLabel(state.snapshot?.spaceLabel) else {
            return label
        }

        return "\(label) (\(spaceLabel))"
    }

    /// Resolves a friendly display name back to the internal provider ID.
    static func providerID(for widgetValue: String, in state: AgentWidgetState?) -> String? {
        let trimmed = widgetValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let providers = state?.sortedProviders ?? []

        // Try exact match on display name
        if let match = providers.first(where: { Self.widgetValue(for: $0) == trimmed }) {
            return match.id
        }

        // Try match on provider title only
        if let match = providers.first(where: { $0.provider.title == trimmed }) {
            return match.id
        }

        // Try match on raw ID (fallback for existing selections)
        if let match = providers.first(where: { $0.id == trimmed }) {
            return match.id
        }

        return nil
    }

    private static func trimmedSpaceLabel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }
}

struct AgentBarWidgetAgentOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        (AgentWidgetStateStore().loadIfPresent()?.sortedProviders ?? [])
            .map(AgentBarWidgetAccountValue.widgetValue)
    }
}

struct AgentBarWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agent Bar"
    static let description = IntentDescription("Shows one local agent quota account on the desktop.")

    @Parameter(
        title: "Agent",
        description: "The AgentBar account to show in this widget.",
        optionsProvider: AgentBarWidgetAgentOptionsProvider()
    )
    var agentID: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$agentID)")
    }
}

// MARK: - Timeline Provider

struct AgentBarWidgetTimelineProvider: AppIntentTimelineProvider {
    typealias Intent = AgentBarWidgetConfigurationIntent

    func placeholder(in context: Context) -> AgentBarWidgetEntry {
        let selectedAgent = AgentWidgetState.preview.sortedProviders.first
        return AgentBarWidgetEntry(
            date: Date(),
            state: .preview,
            selectedAgentID: selectedAgent?.id
        )
    }

    func snapshot(
        for configuration: AgentBarWidgetConfigurationIntent,
        in context: Context
    ) async -> AgentBarWidgetEntry {
        if context.isPreview {
            return placeholder(in: context)
        }

        return loadEntry(for: configuration)
    }

    func timeline(
        for configuration: AgentBarWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<AgentBarWidgetEntry> {
        let entry = loadEntry(for: configuration)
        let nextRefreshDate = entry.date.addingTimeInterval(
            AgentBarWidgetConstants.timelineRefreshInterval
        )
        return Timeline(
            entries: [entry],
            policy: .after(nextRefreshDate)
        )
    }

    private func loadEntry(for configuration: AgentBarWidgetConfigurationIntent) -> AgentBarWidgetEntry {
        let store = AgentWidgetStateStore()
        let cached = store.loadIfPresent()
        let selectedID = resolvedAgentID(from: configuration, state: cached)

        return AgentBarWidgetEntry(
            date: Date(),
            state: cached ?? .empty,
            selectedAgentID: selectedID
        )
    }

    /// Resolves the selected agent from this widget instance's edit configuration.
    private func resolvedAgentID(
        from configuration: AgentBarWidgetConfigurationIntent,
        state: AgentWidgetState?
    ) -> String? {
        let providers = state?.sortedProviders ?? []

        if let raw = configuration.agentID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let resolvedID = AgentBarWidgetAccountValue.providerID(for: raw, in: state),
           providers.contains(where: { $0.id == resolvedID }) {
            return resolvedID
        }

        return providers.first?.id
    }
}

struct AgentBarDesktopWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: AgentBarWidgetConstants.kind,
            intent: AgentBarWidgetConfigurationIntent.self,
            provider: AgentBarWidgetTimelineProvider()
        ) { entry in
            AgentBarDesktopWidgetView(entry: entry)
        }
        .configurationDisplayName("Agent Bar")
        .description("See one Codex, Copilot, Gemini, Claude, or Junie account on your desktop.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}

struct AgentBarDesktopWidgetView: View {
    @Environment(\.colorScheme) private var colorScheme

    let entry: AgentBarWidgetEntry

    private var selectedProvider: AgentWidgetProviderState? {
        let providers = entry.state.sortedProviders
        if let selectedAgentID = entry.selectedAgentID,
           let selectedProvider = providers.first(where: { $0.id == selectedAgentID }) {
            return selectedProvider
        }

        return providers.first
    }

    var body: some View {
        ZStack {
            widgetBackground

            if let selectedProvider {
                providerContent(selectedProvider)
            } else if entry.selectedAgentID != nil {
                emptyState(
                    title: "Agent Not Found",
                    message: "Edit the widget and choose an AgentBar account that is still available."
                )
            } else {
                emptyState(
                    title: "No Data Yet",
                    message: "Open Agent Bar once so it can populate widget data."
                )
            }
        }
        .foregroundStyle(palette.primaryText)
        .containerBackground(for: .widget) {
            widgetBackground
        }
    }

    @ViewBuilder
    private func providerContent(_ state: AgentWidgetProviderState) -> some View {
        let metrics = displayMetrics(for: state)

        VStack(alignment: .leading, spacing: 7) {
            header(state)

            if let error = state.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if !metrics.isEmpty {
                metricsStack(Array(metrics.prefix(2)))

                if let snapshot = state.snapshot {
                    widgetFooter(snapshot)
                }
            } else if let snapshot = state.snapshot {
                HStack(spacing: 8) {
                    if let context = snapshotContext(for: state, snapshot: snapshot) {
                        detailPill(label: context.label, value: context.value)
                    }
                    detailPill(label: "Updated", value: snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                }
                Spacer(minLength: 0)
            } else if state.isAvailable {
                Text("Refreshing…")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 0)
            } else {
                Text("No local credentials found")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(_ state: AgentWidgetProviderState) -> some View {
        let style = providerStyle(for: state.provider)

        return HStack(alignment: .center, spacing: 8) {
            providerIconBadge(style)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(state.provider.title)
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    if let plan = userFacingPlanLabel(state.snapshot?.planType) {
                        detailPill(label: "", value: plan)
                    }
                }

                if let accountLabel = AgentBarWidgetAccountValue.accountSubtitle(for: state) {
                    Text(accountLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            Circle()
                .fill(style.tint)
                .frame(width: 7, height: 7)
        }
    }

    @ViewBuilder
    private func metricsStack(_ metrics: [AgentQuotaMetric]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                if index > 0 {
                    Divider()
                        .opacity(0.32)
                }

                metricRow(metric)
            }
        }
    }

    private func metricRow(_ metric: AgentQuotaMetric) -> some View {
        let tint = quotaTint(for: metric)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                QuotaMetricTitle(title: metric.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
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
                    Text("Reset \(resetsAt.formatted(date: .omitted, time: .shortened))")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(palette.secondaryText)
        }
    }

    private func quotaBar(value: Double, tint: Color) -> some View {
        let progress = min(max(value, 0), 100) / 100

        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(palette.track)

                Capsule()
                    .fill(tint)
                    .frame(width: max(3, proxy.size.width * progress))
            }
        }
        .frame(height: 5)
    }

    private func detailPill(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            if !label.isEmpty {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            }
            Text(value)
                .font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(palette.pillBackground, in: Capsule())
    }

    private func widgetFooter(_ snapshot: AgentQuotaSnapshot) -> some View {
        HStack(spacing: 6) {
            Text("Updated")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.secondaryText)

            Text(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(palette.secondaryText)

            Spacer(minLength: 0)

            Text("AgentBar")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.top, 1)
    }

    private func snapshotContext(
        for state: AgentWidgetProviderState,
        snapshot: AgentQuotaSnapshot
    ) -> (label: String, value: String)? {
        if state.provider == .codex,
           let workspace = trimmedDetailValue(snapshot.spaceLabel) {
            return ("Workspace", workspace)
        }

        if let plan = trimmedDetailValue(snapshot.planType) {
            return ("Plan", plan)
        }

        return ("Status", "Active")
    }

    private func trimmedDetailValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func userFacingPlanLabel(_ value: String?) -> String? {
        guard let trimmed = trimmedDetailValue(value) else {
            return nil
        }

        switch trimmed.lowercased() {
        case "prolite":
            return nil
        default:
            return trimmed
        }
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.headline, design: .rounded).weight(.semibold))

            Text(message)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func displayMetrics(for state: AgentWidgetProviderState) -> [AgentQuotaMetric] {
        guard let metrics = state.snapshot?.metrics else {
            return []
        }

        guard state.provider == .codex else {
            return metrics
        }

        return metrics.enumerated()
            .sorted { lhs, rhs in
                let leftPriority = codexMetricDisplayPriority(lhs.element)
                let rightPriority = codexMetricDisplayPriority(rhs.element)

                if leftPriority != rightPriority {
                    return leftPriority < rightPriority
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func codexMetricDisplayPriority(_ metric: AgentQuotaMetric) -> Int {
        isCodexWeeklyMetric(metric) ? 0 : 1
    }

    private func isCodexWeeklyMetric(_ metric: AgentQuotaMetric) -> Bool {
        metric.id == "window-10080" || metric.title.localizedCaseInsensitiveContains("7 day")
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

    private func quotaTint(for remainingPercent: Double) -> Color {
        Color(agentQuotaRGB: AgentQuotaDisplayColor.color(for: remainingPercent))
    }

    private func providerIconBadge(_ style: WidgetProviderStyle) -> some View {
        Image(style.assetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: 18, height: 18)
            .frame(width: 28, height: 28)
            .background(palette.pillBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(style.tint.opacity(0.20), lineWidth: 1)
            }
    }

    private func providerStyle(for provider: AgentProviderKind) -> WidgetProviderStyle {
        switch provider {
        case .codex:
            return WidgetProviderStyle(assetName: "ProviderLogoCodex", tint: Color(agentQuotaRGB: AgentQuotaDisplayColor.warning))
        case .githubCopilot:
            return WidgetProviderStyle(assetName: "ProviderLogoCopilot", tint: Color(agentQuotaRGB: AgentQuotaDisplayColor.healthy))
        case .gemini:
            return WidgetProviderStyle(assetName: "ProviderLogoGemini", tint: Color(agentQuotaRGB: AgentQuotaDisplayColor.healthy))
        case .claude:
            return WidgetProviderStyle(assetName: "ProviderLogoClaude", tint: Color.purple)
        case .junie:
            return WidgetProviderStyle(assetName: "ProviderLogoJunie", tint: Color(agentQuotaRGB: AgentQuotaDisplayColor.low))
        }
    }

    private var widgetBackground: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.06 : 0.52),
                    Color.white.opacity(0)
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
    }

    private var palette: WidgetPalette {
        WidgetPalette(colorScheme: colorScheme)
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

private struct WidgetProviderStyle {
    let assetName: String
    let tint: Color
}

private struct WidgetPalette {
    let backgroundTop: Color
    let backgroundBottom: Color
    let pillBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let track: Color

    init(colorScheme: ColorScheme) {
        if colorScheme == .dark {
            backgroundTop = Color(red: 0.14, green: 0.16, blue: 0.22)
            backgroundBottom = Color(red: 0.18, green: 0.21, blue: 0.28)
            pillBackground = Color.white.opacity(0.12)
            primaryText = Color.white.opacity(0.98)
            secondaryText = Color.white.opacity(0.72)
            track = Color.white.opacity(0.22)
        } else {
            backgroundTop = Color(red: 0.985, green: 0.988, blue: 0.995)
            backgroundBottom = Color(red: 0.945, green: 0.956, blue: 0.976)
            pillBackground = Color.white.opacity(0.92)
            primaryText = Color(red: 0.10, green: 0.16, blue: 0.23)
            secondaryText = Color(red: 0.31, green: 0.39, blue: 0.49)
            track = Color.black.opacity(0.22)
        }
    }
}

private extension AgentWidgetState {
    static let empty = AgentWidgetState(
        generatedAt: Date(timeIntervalSince1970: 1_776_240_000),
        providers: []
    )

    static let preview = AgentWidgetState(
        generatedAt: Date(timeIntervalSince1970: 1_776_240_000),
        providers: [
            AgentWidgetProviderState(
                id: "preview-codex",
                provider: .codex,
                snapshot: AgentQuotaSnapshot(
                    provider: .codex,
                    accountLabel: "dev@example.com",
                    spaceLabel: "Personal Pro",
                    planType: "Pro",
                    modelName: nil,
                    sourceSummary: "Preview",
                    metrics: [
                        AgentQuotaMetric(
                            id: "codex-preview",
                            title: "5 hour window",
                            usedPercent: 61,
                            usedLabel: "61% used",
                            remainingLabel: "39% left",
                            resetsAt: nil
                        )
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_776_240_000)
                ),
                errorMessage: nil,
                isAvailable: true
            ),
            AgentWidgetProviderState(
                id: "preview-copilot",
                provider: .githubCopilot,
                snapshot: AgentQuotaSnapshot(
                    provider: .githubCopilot,
                    accountLabel: "@monalisa",
                    planType: "Pro",
                    modelName: nil,
                    sourceSummary: "Preview",
                    metrics: [
                        AgentQuotaMetric(
                            id: "copilot-preview",
                            title: "Premium requests / month",
                            usedPercent: 32,
                            usedLabel: "96/300 used",
                            remainingLabel: "204 left",
                            resetsAt: nil
                        )
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_776_240_000)
                ),
                errorMessage: nil,
                isAvailable: true
            ),
            AgentWidgetProviderState(
                id: "preview-gemini",
                provider: .gemini,
                snapshot: AgentQuotaSnapshot(
                    provider: .gemini,
                    accountLabel: "you@gmail.com",
                    planType: "Free",
                    modelName: nil,
                    sourceSummary: "Preview",
                    metrics: [
                        AgentQuotaMetric(
                            id: "gemini-preview",
                            title: "Gemini 2.5 Flash",
                            usedPercent: 18,
                            usedLabel: "36/200 used",
                            remainingLabel: "164 left",
                            resetsAt: nil
                        )
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_776_240_000)
                ),
                errorMessage: nil,
                isAvailable: true
            ),
            AgentWidgetProviderState(
                id: "preview-claude",
                provider: .claude,
                snapshot: AgentQuotaSnapshot(
                    provider: .claude,
                    accountLabel: "dev@example.com",
                    planType: "Claude subscription",
                    modelName: nil,
                    sourceSummary: "Preview",
                    metrics: [],
                    updatedAt: Date(timeIntervalSince1970: 1_776_240_000)
                ),
                errorMessage: nil,
                isAvailable: true
            ),
            AgentWidgetProviderState(
                id: "preview-junie",
                provider: .junie,
                snapshot: AgentQuotaSnapshot(
                    provider: .junie,
                    accountLabel: "JetBrains Account",
                    planType: "Junie API Key · $120 / $200 left",
                    modelName: nil,
                    sourceSummary: "Active · $120 / $200 left",
                    metrics: [
                        AgentQuotaMetric(
                            id: "preview-junie-quota",
                            title: "Subscription quota",
                            usedPercent: 40,
                            usedLabel: "$80 used",
                            remainingLabel: "$120 / $200 left",
                            resetsAt: nil
                        ),
                    ],
                    updatedAt: Date(timeIntervalSince1970: 1_776_240_000)
                ),
                errorMessage: nil,
                isAvailable: true
            ),
        ]
    )
}

@main
struct AgentBarWidgets: WidgetBundle {
    var body: some Widget {
        AgentBarDesktopWidget()
    }
}
