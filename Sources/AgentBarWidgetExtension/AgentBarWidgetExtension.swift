import AppIntents
import SwiftUI
import WidgetKit

#if canImport(AgentBarCore)
import AgentBarCore
#endif

struct AgentBarWidgetEntry: TimelineEntry {
    let date: Date
    let state: AgentWidgetState
}

struct AgentBarWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agent Bar"
    static let description = IntentDescription("Shows local agent quota usage on the desktop.")
}

struct AgentBarWidgetTimelineProvider: AppIntentTimelineProvider {
    typealias Intent = AgentBarWidgetConfigurationIntent

    func placeholder(in context: Context) -> AgentBarWidgetEntry {
        AgentBarWidgetEntry(date: Date(), state: .preview)
    }

    func snapshot(
        for configuration: AgentBarWidgetConfigurationIntent,
        in context: Context
    ) async -> AgentBarWidgetEntry {
        if context.isPreview {
            return placeholder(in: context)
        }

        return await loadEntry()
    }

    func timeline(
        for configuration: AgentBarWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<AgentBarWidgetEntry> {
        let entry = await loadEntry()
        let nextRefreshDate = entry.date.addingTimeInterval(
            AgentBarWidgetConstants.timelineRefreshInterval
        )
        return Timeline(
            entries: [entry],
            policy: .after(nextRefreshDate)
        )
    }

    private func loadEntry() async -> AgentBarWidgetEntry {
        let store = AgentWidgetStateStore()
        if let cached = store.loadIfPresent() {
            return AgentBarWidgetEntry(date: Date(), state: cached)
        }

        // The widget extension is sandboxed. It should only render the shared cache
        // written by the main app, not probe provider config files directly.
        return AgentBarWidgetEntry(date: Date(), state: .empty)
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
        .description("See Codex, Copilot, Gemini, and Claude usage on your desktop.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct AgentBarDesktopWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: AgentBarWidgetEntry

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: columnCount)
    }

    private var columnCount: Int {
        switch family {
        case .systemSmall:
            1
        case .systemMedium:
            2
        case .systemLarge, .systemExtraLarge:
            2
        @unknown default:
            2
        }
    }

    private var maxVisibleProviders: Int {
        switch family {
        case .systemSmall:
            1
        case .systemMedium:
            2
        case .systemLarge, .systemExtraLarge:
            4
        @unknown default:
            4
        }
    }

    private var visibleProviders: [AgentWidgetProviderState] {
        Array(candidateProviders.prefix(maxVisibleProviders))
    }

    private var candidateProviders: [AgentWidgetProviderState] {
        switch family {
        case .systemSmall, .systemMedium:
            return prioritizedProviders
        case .systemLarge, .systemExtraLarge:
            return entry.state.sortedProviders
        @unknown default:
            return entry.state.sortedProviders
        }
    }

    private var prioritizedProviders: [AgentWidgetProviderState] {
        entry.state.sortedProviders.sorted { lhs, rhs in
            let leftPriority = providerPriority(lhs)
            let rightPriority = providerPriority(rhs)

            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }

            if lhs.provider.sortOrder != rhs.provider.sortOrder {
                return lhs.provider.sortOrder < rhs.provider.sortOrder
            }

            return lhs.id < rhs.id
        }
    }

    private var gridSpacing: CGFloat {
        switch family {
        case .systemSmall:
            0
        case .systemMedium:
            10
        case .systemLarge, .systemExtraLarge:
            12
        @unknown default:
            10
        }
    }

    private var widgetPadding: CGFloat {
        switch family {
        case .systemSmall:
            4
        case .systemMedium:
            10
        case .systemLarge, .systemExtraLarge:
            12
        @unknown default:
            14
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let contentSize = CGSize(
                width: max(0, proxy.size.width - (widgetPadding * 2)),
                height: max(0, proxy.size.height - (widgetPadding * 2))
            )

            widgetContent(for: contentSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(widgetPadding)
        }
        .containerBackground(for: .widget) {
            LinearGradient(
                colors: [
                    Color(red: 0.97, green: 0.98, blue: 0.99),
                    Color.white,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    @ViewBuilder
    private func widgetContent(for size: CGSize) -> some View {
        if visibleProviders.isEmpty {
            emptyState
        } else {
            switch family {
            case .systemSmall:
                if let providerState = visibleProviders.first {
                    providerCard(providerState)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            case .systemMedium:
                mediumLayout(size: size)
            case .systemLarge, .systemExtraLarge:
                largeLayout(size: size)
            @unknown default:
                largeLayout(size: size)
            }
        }
    }

    private func mediumLayout(size: CGSize) -> some View {
        return HStack(alignment: .top, spacing: gridSpacing) {
            ForEach(visibleProviders) { providerState in
                providerCard(providerState)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if visibleProviders.count == 1 {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func largeLayout(size: CGSize) -> some View {
        let side = max(0, min((size.width - gridSpacing) / 2, (size.height - gridSpacing) / 2))
        let firstRow = Array(visibleProviders.prefix(2))
        let secondRow = Array(visibleProviders.dropFirst(2).prefix(2))

        return VStack(alignment: .leading, spacing: gridSpacing) {
            cardRow(firstRow, side: side)

            if !secondRow.isEmpty {
                cardRow(secondRow, side: side)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func cardRow(_ states: [AgentWidgetProviderState], side: CGFloat) -> some View {
        HStack(alignment: .top, spacing: gridSpacing) {
            ForEach(states) { providerState in
                providerCard(providerState)
                    .frame(width: side, height: side, alignment: .topLeading)
            }

            if states.count == 1 {
                Spacer(minLength: 0)
            }
        }
    }

    private func providerCard(_ state: AgentWidgetProviderState) -> some View {
        let palette = palette(for: state.provider)

        return VStack(alignment: .leading, spacing: cardSpacing) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.provider.menuBarTitlePrefix)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(palette.tint)
                }

                Spacer(minLength: 0)

                Text(primaryValue(for: state))
                    .font(primaryValueFont)
                    .foregroundStyle(primaryValueColor(for: state, palette: palette))
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .lineLimit(1)
            }

            if let metric = state.snapshot?.highlightMetric {
                ProgressView(value: metric.remainingPercent, total: 100)
                    .tint(palette.tint)

                Text(metric.title)
                    .font(metricTitleFont)
                    .lineLimit(family == .systemSmall ? 2 : 1)

                Text(metric.remainingLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let snapshot = state.snapshot {
                Text(snapshot.accountLabel)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Text(snapshot.planType ?? "Local auth detected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if let error = state.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(family == .systemMedium ? 2 : 3)
            } else if state.isAvailable {
                Text("Refreshing latest usage…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text("No local credentials found")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(cardPadding)
        .frame(
            maxWidth: .infinity,
            minHeight: minimumCardHeight,
            maxHeight: maximumCardHeight,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(palette.background)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(palette.stroke, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No cached data yet")
                .font(.headline)

            Text("Open Agent Bar once, then the desktop widget will update from the shared cache.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.85))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        }
    }

    private var cardPadding: CGFloat {
        switch family {
        case .systemSmall:
            13
        case .systemMedium:
            14
        case .systemLarge, .systemExtraLarge:
            16
        @unknown default:
            12
        }
    }

    private var cardSpacing: CGFloat {
        switch family {
        case .systemSmall:
            7
        case .systemMedium:
            10
        case .systemLarge, .systemExtraLarge:
            12
        @unknown default:
            8
        }
    }

    private var minimumCardHeight: CGFloat {
        switch family {
        case .systemSmall:
            0
        case .systemMedium:
            118
        case .systemLarge, .systemExtraLarge:
            124
        @unknown default:
            118
        }
    }

    private var maximumCardHeight: CGFloat? {
        switch family {
        case .systemSmall:
            .infinity
        case .systemMedium:
            .infinity
        case .systemLarge, .systemExtraLarge:
            nil
        @unknown default:
            nil
        }
    }

    private var primaryValueFont: Font {
        switch family {
        case .systemSmall:
            .system(size: 22, weight: .bold, design: .rounded)
        case .systemMedium:
            .system(size: 18, weight: .bold, design: .rounded)
        case .systemLarge, .systemExtraLarge:
            .system(size: 22, weight: .bold, design: .rounded)
        @unknown default:
            .system(size: 16, weight: .bold, design: .rounded)
        }
    }

    private var metricTitleFont: Font {
        switch family {
        case .systemSmall:
            .caption.weight(.semibold)
        case .systemMedium:
            .footnote.weight(.semibold)
        case .systemLarge, .systemExtraLarge:
            .callout.weight(.semibold)
        @unknown default:
            .caption.weight(.semibold)
        }
    }

    private func primaryValue(for state: AgentWidgetProviderState) -> String {
        if let metric = state.snapshot?.highlightMetric {
            return metric.percentText
        }

        if state.snapshot != nil {
            return "Ready"
        }

        if state.errorMessage != nil {
            return "Error"
        }

        if state.isAvailable {
            return "..."
        }

        return "--"
    }

    private func providerPriority(_ state: AgentWidgetProviderState) -> Double {
        if let usedPercent = state.snapshot?.highlightMetric?.usedPercent {
            return -usedPercent
        }

        if state.snapshot != nil {
            return 1_000
        }

        if state.errorMessage != nil {
            return 2_000
        }

        return 3_000
    }

    private func primaryValueColor(
        for state: AgentWidgetProviderState,
        palette: ProviderPalette
    ) -> Color {
        if state.errorMessage != nil {
            return Color.red.opacity(0.85)
        }

        return palette.tint
    }

    private func palette(for provider: AgentProviderKind) -> ProviderPalette {
        switch provider {
        case .codex:
            return ProviderPalette(
                tint: Color(red: 0.11, green: 0.42, blue: 0.87),
                background: Color(red: 0.92, green: 0.96, blue: 1.00),
                stroke: Color(red: 0.77, green: 0.86, blue: 0.98)
            )
        case .githubCopilot:
            return ProviderPalette(
                tint: Color(red: 0.08, green: 0.54, blue: 0.39),
                background: Color(red: 0.92, green: 0.98, blue: 0.95),
                stroke: Color(red: 0.77, green: 0.92, blue: 0.84)
            )
        case .gemini:
            return ProviderPalette(
                tint: Color(red: 0.94, green: 0.52, blue: 0.10),
                background: Color(red: 1.00, green: 0.96, blue: 0.90),
                stroke: Color(red: 0.98, green: 0.87, blue: 0.72)
            )
        case .claude:
            return ProviderPalette(
                tint: Color(red: 0.45, green: 0.33, blue: 0.26),
                background: Color(red: 0.96, green: 0.94, blue: 0.92),
                stroke: Color(red: 0.87, green: 0.82, blue: 0.77)
            )
        }
    }
}

private struct ProviderPalette {
    let tint: Color
    let background: Color
    let stroke: Color
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
        ]
    )
}

@main
struct AgentBarWidgetExtension: WidgetBundle {
    var body: some Widget {
        AgentBarDesktopWidget()
    }
}
