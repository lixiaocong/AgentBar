import Charts
import SwiftUI

#if canImport(AgentBarCore)
import AgentBarCore
#endif

struct QuotaHistorySidebarView: View {
    @Bindable var viewModel: QuotaHistoryViewModel

    var body: some View {
        accountSidebar
        .onChange(of: viewModel.selectedAccountKey) {
            Task { await viewModel.loadSelection() }
        }
    }

    private var accountSidebar: some View {
        List(selection: $viewModel.selectedAccountKey) {
            ForEach(AgentProviderKind.allCases) { provider in
                let providerAccounts = viewModel.accounts.filter { $0.provider == provider }
                if !providerAccounts.isEmpty {
                    Section(provider.title) {
                        ForEach(providerAccounts) { account in
                            accountRow(account)
                                .tag(account.accountKey)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("Recorded while AgentBar is running")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }

    private func accountRow(_ account: QuotaHistoryAccount) -> some View {
        HStack(spacing: 8) {
            Image(account.provider.historyAssetName)
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)

            Text(account.displayLabel)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)

            if !viewModel.isConfigured(account) {
                Image(systemName: "minus.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Removed account")
            }
        }
    }
}

struct QuotaHistoryDetailView: View {
    let manager: QuotaHistoryManager

    @Bindable var viewModel: QuotaHistoryViewModel

    var body: some View {
        historyDetail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task {
                manager.start()
                await viewModel.load()
            }
            .onChange(of: viewModel.range) {
                Task { await viewModel.loadRange() }
            }
            .onChange(of: manager.revision) {
                Task { await viewModel.load() }
            }
    }

    @ViewBuilder
    private var historyDetail: some View {
        if let account = viewModel.selectedAccount {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(account: account)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)

                Divider()

                if let errorMessage = viewModel.errorMessage {
                    ContentUnavailableView(
                        "History Unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if viewModel.isLoading && viewModel.windows.isEmpty {
                    ProgressView("Loading quota history...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.windows.isEmpty {
                    ContentUnavailableView(
                        "No Quota History",
                        systemImage: "chart.xyaxis.line",
                        description: Text("History begins after the next successful quota refresh.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.windows) { window in
                                QuotaHistoryChartCard(
                                    provider: account.provider,
                                    window: window,
                                    samples: viewModel.samplesByWindowID[window.id] ?? [],
                                    isCurrent: viewModel.isCurrent(window)
                                )
                                .transaction { transaction in
                                    transaction.animation = nil
                                }
                            }
                        }
                        .padding(16)
                    }
                    .overlay(alignment: .topTrailing) {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(12)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView(
                "No History Yet",
                systemImage: "chart.xyaxis.line",
                description: Text("AgentBar will record the first sample after a successful quota refresh.")
            )
        }
    }

    private func detailHeader(account: QuotaHistoryAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(account.provider.historyAssetName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                    .padding(6)
                    .background(account.provider.historyTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(account.displayLabel)
                            .font(.title3.weight(.bold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)

                        if let planType = account.planType, !planType.isEmpty {
                            Text(planType)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(account.provider.historyTint)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(account.provider.historyTint.opacity(0.10), in: Capsule())
                        }
                    }

                    Text(viewModel.isConfigured(account) ? account.provider.title : "Removed account - history retained")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            HStack {
                Spacer(minLength: 0)

                Picker("Range", selection: $viewModel.range) {
                    ForEach(QuotaHistoryRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 360)
            }
        }
    }
}

private struct QuotaHistoryChartCard: View {
    let provider: AgentProviderKind
    let window: QuotaHistoryWindow
    let samples: [QuotaHistorySample]
    let isCurrent: Bool

    @State private var hoveredSample: QuotaHistorySample?

    private var numericSamples: [QuotaHistorySample] {
        samples.filter { !$0.isUnlimited && $0.remainingPercent != nil }
    }

    private var resetSamples: [QuotaHistorySample] {
        numericSamples.filter { $0.eventKind == .reset }
    }

    private var segments: [QuotaHistoryChartSegment] {
        var result: [QuotaHistoryChartSegment] = []
        var current: [QuotaHistorySample] = []

        for sample in numericSamples {
            if let previous = current.last,
               sample.sampledAt.timeIntervalSince(previous.sampledAt) > 40 * 60 {
                result.append(QuotaHistoryChartSegment(index: result.count, samples: current))
                current = []
            }
            current.append(sample)
        }

        if !current.isEmpty {
            result.append(QuotaHistoryChartSegment(index: result.count, samples: current))
        }
        return result
    }

    private var detailSample: QuotaHistorySample? {
        hoveredSample ?? latestVisibleSample
    }

    private var latestVisibleSample: QuotaHistorySample? {
        samples.last
    }

    private var chartDuration: TimeInterval {
        guard let first = numericSamples.first?.sampledAt,
              let last = numericSamples.last?.sampledAt else { return 0 }
        return last.timeIntervalSince(first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            chartHeader

            if numericSamples.isEmpty {
                emptyChartState
            } else {
                historyChart
                    .frame(height: 150)
            }

            sampleDetail
                .frame(height: 20)
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var chartHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(window.title)
                .font(.headline.weight(.bold))
                .lineLimit(1)
                .truncationMode(.tail)

            if !isCurrent {
                Text("No longer reported")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.10), in: Capsule())
            }

            Spacer(minLength: 8)

            if let latest = latestVisibleSample {
                if latest.isUnlimited {
                    Text("Unlimited")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(provider.historyTint)
                } else if let remaining = latest.remainingPercent {
                    Text("\(Int(remaining.rounded()))% left")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(remaining.historyColor)
                }
            }

            if let resetDate = latestVisibleSample?.resetsAt,
               resetDate > Date() {
                Text("Resets \(resetDate, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var emptyChartState: some View {
        HStack(spacing: 10) {
            Image(systemName: latestVisibleSample?.isUnlimited == true ? "infinity" : "clock")
                .font(.title2.weight(.semibold))
                .foregroundStyle(provider.historyTint)

            VStack(alignment: .leading, spacing: 3) {
                Text(latestVisibleSample?.isUnlimited == true ? "Unlimited during this period" : "No samples in this range")
                    .font(.subheadline.weight(.semibold))
                Text("Last recorded \(window.lastSeenAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
    }

    private var historyChart: some View {
        Chart {
            ForEach(segments) { segment in
                ForEach(segment.samples) { sample in
                    if let remaining = sample.remainingPercent {
                        LineMark(
                            x: .value("Time", sample.sampledAt),
                            y: .value("Remaining", remaining),
                            series: .value("Segment", segment.index)
                        )
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(provider.historyTint)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
            }

            ForEach(resetSamples) { sample in
                RuleMark(x: .value("Reset", sample.sampledAt))
                    .foregroundStyle(.green.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .annotation(position: .top, spacing: 2) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
            }

            if numericSamples.count == 1,
               let sample = numericSamples.first,
               let remaining = sample.remainingPercent {
                PointMark(
                    x: .value("Recorded time", sample.sampledAt),
                    y: .value("Recorded remaining", remaining)
                )
                .foregroundStyle(provider.historyTint)
                .symbolSize(36)
            }

            if let hoveredSample,
               let remaining = hoveredSample.remainingPercent {
                RuleMark(x: .value("Selected", hoveredSample.sampledAt))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                PointMark(
                    x: .value("Selected time", hoveredSample.sampledAt),
                    y: .value("Selected remaining", remaining)
                )
                .foregroundStyle(provider.historyTint)
                .symbolSize(34)
            }
        }
        .chartYScale(domain: 0 ... 100)
        .chartYAxis {
            AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(for: date))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let plotFrame = proxy.plotFrame.map({ geometry[$0] }),
                                  plotFrame.contains(location),
                                  let date: Date = proxy.value(atX: location.x - plotFrame.origin.x) else {
                                hoveredSample = nil
                                return
                            }
                            hoveredSample = numericSamples.min {
                                abs($0.sampledAt.timeIntervalSince(date)) < abs($1.sampledAt.timeIntervalSince(date))
                            }
                        case .ended:
                            hoveredSample = nil
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var sampleDetail: some View {
        if let sample = detailSample {
            HStack(spacing: 10) {
                Text(sample.sampledAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                if let remainingLabel = sample.remainingLabel {
                    Text(remainingLabel)
                        .fontWeight(.semibold)
                }
                if let usedLabel = sample.usedLabel, usedLabel != sample.remainingLabel {
                    Text(usedLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
        } else {
            Text("No recorded samples")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func axisLabel(for date: Date) -> String {
        switch chartDuration {
        case ..<(18 * 60 * 60):
            return date.formatted(.dateTime.hour().minute())
        case ..<(2 * 24 * 60 * 60):
            return date.formatted(.dateTime.weekday(.abbreviated).hour())
        case ..<(14 * 24 * 60 * 60):
            return date.formatted(.dateTime.month(.abbreviated).day().hour())
        case ..<(120 * 24 * 60 * 60):
            return date.formatted(.dateTime.month(.abbreviated).day())
        default:
            return date.formatted(.dateTime.month(.abbreviated).year())
        }
    }
}

private struct QuotaHistoryChartSegment: Identifiable {
    let index: Int
    let samples: [QuotaHistorySample]

    var id: Int { index }
}

private extension AgentProviderKind {
    var historyAssetName: String {
        switch self {
        case .codex: return "ProviderLogoCodex"
        case .githubCopilot: return "ProviderLogoCopilot"
        case .gemini: return "ProviderLogoGemini"
        case .claude: return "ProviderLogoClaude"
        case .zai: return "ProviderLogoZAI"
        case .junie: return "ProviderLogoJunie"
        }
    }

    var historyTint: Color {
        switch self {
        case .codex: return .orange
        case .githubCopilot: return .green
        case .gemini: return .purple
        case .claude: return .orange
        case .zai: return .blue
        case .junie: return .green
        }
    }
}

private extension Double {
    var historyColor: Color {
        let rgb = AgentQuotaDisplayColor.color(for: self)
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}
