import AppIntents
import SwiftUI
import WidgetKit

#if canImport(AgentBarCore)
import AgentBarCore
#endif

// MARK: - Per-Instance Selection Persistence

/// Persists the selected agent ID to a file in the widget's sandbox.
/// Written by the interactive SelectAgentBarAgentIntent, read by the timeline provider.
private enum AgentWidgetSelectionStore {
    private static let filename = "widget-selection.json"

    struct Selection: Codable {
        var selectedAgentID: String?
    }

    static func load() -> Selection {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url),
              let selection = try? JSONDecoder().decode(Selection.self, from: data) else {
            return Selection(selectedAgentID: nil)
        }
        return selection
    }

    static func save(_ selection: Selection) {
        let url = fileURL()
        guard let data = try? JSONEncoder().encode(selection) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func fileURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(filename)
    }
}

// MARK: - Interactive Intent for Agent Selection

/// Interactive intent triggered by tapping an agent tab in the widget.
struct SelectAgentBarAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Agent"
    static let description = IntentDescription("Selects which agent to display in the widget.")

    @Parameter(title: "Agent ID")
    var agentID: String

    init() {
        self.agentID = ""
    }

    init(agentID: String) {
        self.agentID = agentID
    }

    func perform() async throws -> some IntentResult {
        var selection = AgentWidgetSelectionStore.load()
        selection.selectedAgentID = agentID
        AgentWidgetSelectionStore.save(selection)
        return .result()
    }
}

// MARK: - Widget Configuration (kept for Edit UI, even though persistence is broken)

struct AgentBarWidgetEntry: TimelineEntry {
    let date: Date
    let state: AgentWidgetState
    let selectedAgentID: String?
    let availableProviders: [AgentWidgetProviderState]
}

struct AgentWidgetSelection: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Agent")
    static let defaultQuery = AgentWidgetSelectionQuery()

    let id: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(subtitle)"
        )
    }
}

struct AgentWidgetSelectionQuery: EntityQuery {
    func entities(for identifiers: [AgentWidgetSelection.ID]) async throws -> [AgentWidgetSelection] {
        let selections = Self.availableSelections()

        // Persist selection when system resolves an entity (Edit Widget confirmation)
        if let id = identifiers.first {
            var stored = AgentWidgetSelectionStore.load()
            stored.selectedAgentID = id
            AgentWidgetSelectionStore.save(stored)
        }

        return identifiers.map { identifier in
            selections.first { $0.id == identifier } ?? AgentWidgetSelection(
                id: identifier,
                title: "Unavailable Agent",
                subtitle: identifier
            )
        }
    }

    func suggestedEntities() async throws -> [AgentWidgetSelection] {
        Self.availableSelections()
    }

    func defaultResult() async -> AgentWidgetSelection? {
        nil
    }

    private static func availableSelections() -> [AgentWidgetSelection] {
        let state = AgentWidgetStateStore().loadIfPresent()
        return (state?.sortedProviders ?? AgentWidgetState.preview.sortedProviders)
            .map(selection)
    }

    private static func selection(for state: AgentWidgetProviderState) -> AgentWidgetSelection {
        let accountLabel = state.snapshot?.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let accountLabel, !accountLabel.isEmpty {
            title = "\(state.provider.title): \(accountLabel)"
        } else {
            title = state.provider.title
        }

        let subtitle: String
        if let metric = state.snapshot?.highlightMetric {
            subtitle = "\(metric.percentText) remaining"
        } else if state.snapshot != nil {
            subtitle = "Ready"
        } else if state.errorMessage != nil {
            subtitle = "Error"
        } else if state.isAvailable {
            subtitle = "Refreshing"
        } else {
            subtitle = "No credentials"
        }

        return AgentWidgetSelection(id: state.id, title: title, subtitle: subtitle)
    }
}

struct AgentBarWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Agent Bar"
    static let description = IntentDescription("Shows one local agent quota account on the desktop.")

    @Parameter(title: "Agent", description: "The AgentBar account to show in this widget.")
    var agent: AgentWidgetSelection?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$agent)")
    }
}

// MARK: - Timeline Provider

struct AgentBarWidgetTimelineProvider: AppIntentTimelineProvider {
    typealias Intent = AgentBarWidgetConfigurationIntent

    func placeholder(in context: Context) -> AgentBarWidgetEntry {
        AgentBarWidgetEntry(
            date: Date(),
            state: .preview,
            selectedAgentID: AgentWidgetState.preview.sortedProviders.first?.id,
            availableProviders: AgentWidgetState.preview.sortedProviders
        )
    }

    func snapshot(
        for configuration: AgentBarWidgetConfigurationIntent,
        in context: Context
    ) async -> AgentBarWidgetEntry {
        if context.isPreview {
            return placeholder(in: context)
        }

        // Capture any non-nil intent selection
        if let intentID = configuration.agent?.id {
            var selection = AgentWidgetSelectionStore.load()
            selection.selectedAgentID = intentID
            AgentWidgetSelectionStore.save(selection)
        }

        return loadEntry(for: configuration)
    }

    func timeline(
        for configuration: AgentBarWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<AgentBarWidgetEntry> {
        // Persist intent selection if available
        if let intentID = configuration.agent?.id {
            var selection = AgentWidgetSelectionStore.load()
            selection.selectedAgentID = intentID
            AgentWidgetSelectionStore.save(selection)
        }

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
        let providers = cached?.sortedProviders ?? []
        let selectedID = resolvedAgentID(from: configuration, state: cached)

        return AgentBarWidgetEntry(
            date: Date(),
            state: cached ?? .empty,
            selectedAgentID: selectedID,
            availableProviders: providers
        )
    }

    /// Resolves the selected agent: intent → persisted file → first provider.
    private func resolvedAgentID(from configuration: AgentBarWidgetConfigurationIntent, state: AgentWidgetState?) -> String? {
        let providers = state?.sortedProviders ?? []

        // Intent parameter (if system persistence ever works)
        if let intentID = configuration.agent?.id,
           providers.contains(where: { $0.id == intentID }) {
            return intentID
        }

        // File-based fallback (written by interactive intent button)
        if let fileID = AgentWidgetSelectionStore.load().selectedAgentID,
           providers.contains(where: { $0.id == fileID }) {
            return fileID
        }

        // Fall back to first provider
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
        .description("See one Codex, Copilot, Gemini, or Claude account on your desktop.")
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
        let providerPalette = tint(for: state.provider)
        let metrics = displayMetrics(for: state)

        VStack(alignment: .leading, spacing: 8) {
            header(state)

            if let error = state.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else if !metrics.isEmpty {
                ForEach(metrics.prefix(3)) { metric in
                    metricCard(metric, tint: providerPalette)
                }
            } else if let snapshot = state.snapshot {
                HStack(spacing: 8) {
                    detailPill(label: "Plan", value: snapshot.planType ?? "Active")
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

            // Agent picker tabs (interactive intent buttons)
            if entry.availableProviders.count > 1 {
                agentPickerBar(selectedID: state.id)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func agentPickerBar(selectedID: String) -> some View {
        HStack(spacing: 4) {
            ForEach(entry.availableProviders) { provider in
                Button(intent: SelectAgentBarAgentIntent(agentID: provider.id)) {
                    Text(provider.provider.title)
                        .font(.system(size: 9, weight: provider.id == selectedID ? .bold : .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(provider.id == selectedID
                                      ? tint(for: provider.provider).opacity(0.2)
                                      : Color.clear)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ state: AgentWidgetProviderState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(state.provider.title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            if let accountLabel = state.snapshot?.accountLabel {
                Text(accountLabel)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
        }
    }

    private func metricCard(_ metric: AgentQuotaMetric, tint: Color) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(metric.title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                ProgressView(value: metric.remainingPercent, total: 100)
                    .tint(tint)
            }

            Text(metric.remainingLabel)
                .font(.system(.caption, design: .rounded).weight(.bold))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.10))
        )
    }

    private func detailPill(label: String, value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(palette.pillBackground, in: Capsule())
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

    private func tint(for provider: AgentProviderKind) -> Color {
        switch provider {
        case .codex:
            Color(red: 0.11, green: 0.42, blue: 0.87)
        case .githubCopilot:
            Color(red: 0.08, green: 0.54, blue: 0.39)
        case .gemini:
            Color(red: 0.94, green: 0.52, blue: 0.10)
        case .claude:
            Color(red: 0.55, green: 0.35, blue: 0.24)
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

private struct WidgetPalette {
    let backgroundTop: Color
    let backgroundBottom: Color
    let pillBackground: Color
    let primaryText: Color
    let secondaryText: Color

    init(colorScheme: ColorScheme) {
        if colorScheme == .dark {
            backgroundTop = Color(red: 0.14, green: 0.16, blue: 0.22)
            backgroundBottom = Color(red: 0.18, green: 0.21, blue: 0.28)
            pillBackground = Color.white.opacity(0.12)
            primaryText = Color.white.opacity(0.98)
            secondaryText = Color.white.opacity(0.72)
        } else {
            backgroundTop = Color(red: 0.985, green: 0.988, blue: 0.995)
            backgroundBottom = Color(red: 0.945, green: 0.956, blue: 0.976)
            pillBackground = Color.white.opacity(0.92)
            primaryText = Color(red: 0.10, green: 0.16, blue: 0.23)
            secondaryText = Color(red: 0.31, green: 0.39, blue: 0.49)
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
