import AppKit
import Foundation
import os

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()
    static let defaultRefreshIntervalSeconds = 10
    static let minimumRefreshIntervalSeconds = 5
    static let maximumRefreshIntervalSeconds = 300
    static let refreshIntervalStepSeconds = 5
    private static let menuBarDisplayModeDefaultsKey = "menuBarDisplayMode"
    private static let refreshIntervalDefaultsKey = "refreshIntervalSeconds"

    private let codexCloudService: CodexQuotaService
    private let copilotService: GitHubCopilotQuotaService
    private let geminiService: GeminiQuotaService
    private let userDefaults: UserDefaults
    private let autoRefreshEnabled: Bool
    private let providerAvailabilityResolver: @Sendable () -> AgentProviderAvailability
    private var refreshTask: Task<Void, Never>?

    var providerAvailability: AgentProviderAvailability
    var codexSnapshot: AgentQuotaSnapshot?
    var copilotSnapshot: AgentQuotaSnapshot?
    var geminiSnapshot: AgentQuotaSnapshot?
    var codexError: String?
    var copilotError: String?
    var geminiError: String?
    var isRefreshing = false
    var menuBarDisplayMode: MenuBarDisplayMode {
        didSet {
            guard oldValue != menuBarDisplayMode else { return }
            userDefaults.set(menuBarDisplayMode.rawValue, forKey: Self.menuBarDisplayModeDefaultsKey)
        }
    }
    var refreshIntervalSeconds: Int {
        didSet {
            let normalized = Self.normalizedRefreshInterval(refreshIntervalSeconds)
            if refreshIntervalSeconds != normalized {
                refreshIntervalSeconds = normalized
                return
            }

            guard oldValue != refreshIntervalSeconds else { return }
            userDefaults.set(refreshIntervalSeconds, forKey: Self.refreshIntervalDefaultsKey)
            restartAutoRefresh()
        }
    }

    init(
        codexCloudService: CodexQuotaService = CodexQuotaService(),
        copilotService: GitHubCopilotQuotaService = GitHubCopilotQuotaService(),
        geminiService: GeminiQuotaService = GeminiQuotaService(),
        userDefaults: UserDefaults = .standard,
        providerAvailabilityResolver: (@Sendable () -> AgentProviderAvailability)? = nil,
        startImmediately: Bool = true
    ) {
        self.codexCloudService = codexCloudService
        self.copilotService = copilotService
        self.geminiService = geminiService
        self.userDefaults = userDefaults
        self.autoRefreshEnabled = startImmediately
        self.providerAvailabilityResolver = providerAvailabilityResolver ?? {
            AgentProviderAvailability(
                codex: codexCloudService.isAvailable,
                githubCopilot: copilotService.isAvailable,
                gemini: geminiService.isAvailable
            )
        }
        self.providerAvailability = self.providerAvailabilityResolver()
        menuBarDisplayMode = MenuBarDisplayMode.fromStoredValue(
            userDefaults.string(forKey: Self.menuBarDisplayModeDefaultsKey)
        )
        refreshIntervalSeconds = Self.normalizedRefreshInterval(
            userDefaults.object(forKey: Self.refreshIntervalDefaultsKey) as? Int
        )

        if startImmediately {
            refreshNow()
            startAutoRefresh()
        }
    }

    var availableProviders: [AgentProviderKind] {
        providerAvailability.availableProviders
    }

    /// All successfully loaded snapshots for locally available providers.
    var snapshots: [AgentQuotaSnapshot] {
        availableProviders.compactMap(snapshot(for:))
    }

    /// The most critical metric across all providers (highest usedPercent).
    var highlightMetric: AgentQuotaMetric? {
        snapshots.flatMap(\.metrics).max { $0.usedPercent < $1.usedPercent }
    }

    var menuBarTitle: String {
        let segments = availableProviders.map { provider in
            menuBarSummarySegment(
                shortTitle: provider.menuBarShortPrefix,
                title: provider.menuBarTitlePrefix,
                snapshot: snapshot(for: provider),
                error: errorMessage(for: provider)
            )
        }

        return segments.isEmpty ? "Agent Bar" : segments.joined(separator: "  ")
    }

    var menuBarAccessibilityTitle: String {
        let segments = availableProviders.map { provider in
            accessibilitySummarySegment(
                title: provider.menuBarTitlePrefix,
                snapshot: snapshot(for: provider),
                error: errorMessage(for: provider)
            )
        }

        return segments.isEmpty ? "No supported agents detected on this Mac" : segments.joined(separator: ", ")
    }

    var statusIconUsedPercents: [Double?] {
        let values = availableProviders.map(usedPercent(for:))
        return values.isEmpty ? [nil] : values
    }

    var codexUsedPercent: Double? {
        codexSnapshot?.highlightMetric?.usedPercent
    }

    var copilotUsedPercent: Double? {
        copilotSnapshot?.highlightMetric?.usedPercent
    }

    var geminiUsedPercent: Double? {
        geminiSnapshot?.highlightMetric?.usedPercent
    }

    var menuBarIconEmphasis: MenuBarStatusImage.Emphasis {
        guard let metric = highlightMetric else { return .idle }
        switch metric.usedPercent {
        case 90...: return .critical
        case 75...: return .warning
        default:    return .normal
        }
    }

    func refreshNow() {
        guard !isRefreshing else { return }
        refreshProviderAvailability()
        isRefreshing = true

        Task {
            defer { isRefreshing = false }
            let availability = providerAvailability
            guard !availableProviders.isEmpty else {
                logInfo("No supported providers detected locally.")
                return
            }

            logInfo("Refreshing detected providers: \(availableProviders.map(\.menuBarTitlePrefix).joined(separator: ", "))")

            async let codexResult = loadIfAvailable(availability.codex, using: loadCodex)
            async let copilotResult = loadIfAvailable(availability.githubCopilot, using: loadCopilot)
            async let geminiResult = loadIfAvailable(availability.gemini, using: loadGemini)

            let (codex, copilot, gemini) = await (codexResult, copilotResult, geminiResult)

            apply(result: codex, provider: .codex)
            apply(result: copilot, provider: .githubCopilot)
            apply(result: gemini, provider: .gemini)
        }
    }

    func snapshot(for provider: AgentProviderKind) -> AgentQuotaSnapshot? {
        switch provider {
        case .codex:
            return codexSnapshot
        case .githubCopilot:
            return copilotSnapshot
        case .gemini:
            return geminiSnapshot
        }
    }

    func errorMessage(for provider: AgentProviderKind) -> String? {
        switch provider {
        case .codex:
            return codexError
        case .githubCopilot:
            return copilotError
        case .gemini:
            return geminiError
        }
    }

    func usedPercent(for provider: AgentProviderKind) -> Double? {
        snapshot(for: provider)?.highlightMetric?.usedPercent
    }

    func openCodexRoot() {
        NSWorkspace.shared.open(codexCloudService.installation.rootDirectory)
    }

    func openCopilotConfigDirectory() {
        NSWorkspace.shared.open(copilotService.installation.configDirectory)
    }

    func openGeminiConfigDirectory() {
        NSWorkspace.shared.open(geminiService.installation.configDirectory)
    }

    // MARK: - Private

    private func loadCodex() async -> Result<AgentQuotaSnapshot, Error> {
        do {
            return .success(try await codexCloudService.loadSnapshot())
        } catch {
            return .failure(error)
        }
    }

    private func loadCopilot() async -> Result<AgentQuotaSnapshot, Error> {
        do {
            return .success(try await copilotService.loadSnapshot())
        } catch {
            return .failure(error)
        }
    }

    private func loadGemini() async -> Result<AgentQuotaSnapshot, Error> {
        do {
            return .success(try await geminiService.loadSnapshot())
        } catch {
            return .failure(error)
        }
    }

    private func loadIfAvailable(
        _ isAvailable: Bool,
        using loader: @escaping () async -> Result<AgentQuotaSnapshot, Error>
    ) async -> Result<AgentQuotaSnapshot, Error>? {
        guard isAvailable else { return nil }
        return await loader()
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()

        guard autoRefreshEnabled else { return }
        let interval = refreshIntervalSeconds
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.refreshNow()
            }
        }
    }

    private func restartAutoRefresh() {
        startAutoRefresh()
    }

    private func refreshProviderAvailability() {
        providerAvailability = providerAvailabilityResolver()

        if !providerAvailability.codex {
            codexSnapshot = nil
            codexError = nil
        }

        if !providerAvailability.githubCopilot {
            copilotSnapshot = nil
            copilotError = nil
        }

        if !providerAvailability.gemini {
            geminiSnapshot = nil
            geminiError = nil
        }
    }

    private func apply(
        result: Result<AgentQuotaSnapshot, Error>?,
        provider: AgentProviderKind
    ) {
        guard let result else { return }

        switch result {
        case .success(let snap):
            setSnapshot(snap, error: nil, for: provider)
            logInfo("\(provider.title) snapshot loaded — \(snap.highlightMetric?.percentText ?? "n/a") remaining")
        case .failure(let err):
            let message = (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
            setSnapshot(nil, error: message, for: provider)
            logError("[AppModel] \(provider.title) refresh failed: \(message)")
        }
    }

    private func setSnapshot(
        _ snapshot: AgentQuotaSnapshot?,
        error: String?,
        for provider: AgentProviderKind
    ) {
        switch provider {
        case .codex:
            codexSnapshot = snapshot
            codexError = error
        case .githubCopilot:
            copilotSnapshot = snapshot
            copilotError = error
        case .gemini:
            geminiSnapshot = snapshot
            geminiError = error
        }
    }

    private func menuBarSummarySegment(
        shortTitle: String,
        title: String,
        snapshot: AgentQuotaSnapshot?,
        error: String?
    ) -> String {
        switch menuBarDisplayMode {
        case .shorter:
            return "\(shortTitle)\(menuBarValueText(snapshot: snapshot, error: error, style: .percent))"
        case .clearer:
            return "\(title) \(menuBarValueText(snapshot: snapshot, error: error, style: .percent))"
        case .mixedMetrics:
            let style: MenuBarValueStyle = title == "Copilot" ? .remainingLabel : .percent
            return "\(title) \(menuBarValueText(snapshot: snapshot, error: error, style: style))"
        }
    }

    private func accessibilitySummarySegment(
        title: String,
        snapshot: AgentQuotaSnapshot?,
        error: String?
    ) -> String {
        if let snapshot, let metric = snapshot.highlightMetric {
            return "\(title) \(metric.percentText) remaining"
        }

        if error != nil {
            return "\(title) unavailable"
        }

        return "\(title) loading"
    }

    private func menuBarValueText(
        snapshot: AgentQuotaSnapshot?,
        error: String?,
        style: MenuBarValueStyle
    ) -> String {
        if let snapshot, let metric = snapshot.highlightMetric {
            switch style {
            case .percent:
                return metric.percentText
            case .remainingLabel:
                return metric.remainingLabel
            }
        }

        if error != nil {
            return "!"
        }

        return "--"
    }

    private static func normalizedRefreshInterval(_ value: Int?) -> Int {
        let rawValue = value ?? defaultRefreshIntervalSeconds
        return min(max(rawValue, minimumRefreshIntervalSeconds), maximumRefreshIntervalSeconds)
    }

    private enum MenuBarValueStyle {
        case percent
        case remainingLabel
    }
}
