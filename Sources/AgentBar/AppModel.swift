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
    private static let configuredAccountDirectoriesDefaultsKeyPrefix = "configuredAccountDirectories."

    private let userDefaults: UserDefaults
    private let autoRefreshEnabled: Bool
    private let providerAvailabilityOverride: (@Sendable () -> AgentProviderAvailability)?
    private var refreshTask: Task<Void, Never>?
    private var needsRefreshAfterCurrentRun = false
    private var configuredDirectoriesByProvider: [AgentProviderKind: [ConfiguredAccountDirectory]]
    private var accountSnapshotsByID: [String: AgentQuotaSnapshot] = [:]
    private var accountErrorsByID: [String: String] = [:]

    var providerAvailability: AgentProviderAvailability
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

    var codexSnapshot: AgentQuotaSnapshot? {
        get { summarySnapshot(for: .codex) }
        set { setPrimaryAccountState(snapshot: newValue, error: nil, for: .codex) }
    }

    var copilotSnapshot: AgentQuotaSnapshot? {
        get { summarySnapshot(for: .githubCopilot) }
        set { setPrimaryAccountState(snapshot: newValue, error: nil, for: .githubCopilot) }
    }

    var geminiSnapshot: AgentQuotaSnapshot? {
        get { summarySnapshot(for: .gemini) }
        set { setPrimaryAccountState(snapshot: newValue, error: nil, for: .gemini) }
    }

    var claudeSnapshot: AgentQuotaSnapshot? {
        get { summarySnapshot(for: .claude) }
        set { setPrimaryAccountState(snapshot: newValue, error: nil, for: .claude) }
    }

    var codexError: String? {
        get { summaryError(for: .codex) }
        set { setPrimaryAccountState(snapshot: nil, error: newValue, for: .codex) }
    }

    var copilotError: String? {
        get { summaryError(for: .githubCopilot) }
        set { setPrimaryAccountState(snapshot: nil, error: newValue, for: .githubCopilot) }
    }

    var geminiError: String? {
        get { summaryError(for: .gemini) }
        set { setPrimaryAccountState(snapshot: nil, error: newValue, for: .gemini) }
    }

    var claudeError: String? {
        get { summaryError(for: .claude) }
        set { setPrimaryAccountState(snapshot: nil, error: newValue, for: .claude) }
    }

    init(
        userDefaults: UserDefaults = .standard,
        providerAvailabilityResolver: (@Sendable () -> AgentProviderAvailability)? = nil,
        startImmediately: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.autoRefreshEnabled = startImmediately
        self.providerAvailabilityOverride = providerAvailabilityResolver
        self.configuredDirectoriesByProvider = Self.loadConfiguredDirectories(from: userDefaults)
        self.providerAvailability = .none
        menuBarDisplayMode = MenuBarDisplayMode.fromStoredValue(
            userDefaults.string(forKey: Self.menuBarDisplayModeDefaultsKey)
        )
        refreshIntervalSeconds = Self.normalizedRefreshInterval(
            userDefaults.object(forKey: Self.refreshIntervalDefaultsKey) as? Int
        )
        refreshProviderAvailability()

        if startImmediately {
            refreshNow()
            startAutoRefresh()
        }
    }

    var availableProviders: [AgentProviderKind] {
        providerAvailability.availableProviders
    }

    /// All successfully loaded snapshots for visible accounts.
    var snapshots: [AgentQuotaSnapshot] {
        availableProviders.flatMap { provider in
            visibleAccountStatuses(for: provider).compactMap(\.snapshot)
        }
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
        usedPercent(for: .codex)
    }

    var copilotUsedPercent: Double? {
        usedPercent(for: .githubCopilot)
    }

    var geminiUsedPercent: Double? {
        usedPercent(for: .gemini)
    }

    var claudeUsedPercent: Double? {
        usedPercent(for: .claude)
    }

    var menuBarIconEmphasis: MenuBarStatusImage.Emphasis {
        guard let metric = highlightMetric else { return .idle }
        switch metric.usedPercent {
        case 90...: return .critical
        case 75...: return .warning
        default:    return .normal
        }
    }

    func configuredAccounts(for provider: AgentProviderKind) -> [ConfiguredAccountDirectory] {
        configuredDirectoriesByProvider[provider] ?? []
    }

    func accountStatuses(for provider: AgentProviderKind) -> [AgentAccountStatus] {
        configuredAccounts(for: provider).map { directory in
            let account = ConfiguredAgentAccount(provider: provider, directory: directory)
            return accountStatus(for: account)
        }
    }

    func visibleAccountStatuses(for provider: AgentProviderKind) -> [AgentAccountStatus] {
        accountStatuses(for: provider).filter(\.shouldDisplayInMenu)
    }

    func selectAccountDirectory(for provider: AgentProviderKind) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.title = "Choose \(provider.title) Account Directory"
        panel.message = "Choose the \(provider.title) config directory that contains \(provider.credentialsFileDescription). Hidden folders are shown here."
        panel.directoryURL = provider.defaultAccountDirectory.url.deletingLastPathComponent()

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url
    }

    func addAccountDirectory(for provider: AgentProviderKind) {
        guard let directoryURL = selectAccountDirectory(for: provider) else {
            return
        }

        addConfiguredAccountDirectory(directoryURL, for: provider)
    }

    @discardableResult
    func addConfiguredAccountDirectory(
        path rawPath: String,
        for provider: AgentProviderKind
    ) -> AddConfiguredAccountDirectoryResult {
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            return .emptyPath
        }

        let directory = ConfiguredAccountDirectory(path: trimmedPath)
        guard !configuredAccounts(for: provider).contains(directory) else {
            return .duplicate
        }

        updateConfiguredAccounts(
            configuredAccounts(for: provider) + [directory],
            for: provider
        )
        return .added
    }

    func addConfiguredAccountDirectory(
        _ directoryURL: URL,
        for provider: AgentProviderKind
    ) {
        _ = addConfiguredAccountDirectory(path: directoryURL.path, for: provider)
    }

    func removeConfiguredAccount(_ account: ConfiguredAgentAccount) {
        let updated = configuredAccounts(for: account.provider).filter { $0 != account.directory }
        clearStoredAccountState(for: [account.id])
        updateConfiguredAccounts(updated, for: account.provider)
    }

    func openConfiguredAccountDirectory(_ account: ConfiguredAgentAccount) {
        NSWorkspace.shared.open(account.directory.url)
    }

    func refreshNow() {
        if isRefreshing {
            needsRefreshAfterCurrentRun = true
            return
        }

        refreshProviderAvailability()
        isRefreshing = true
        let availableAccounts = availableConfiguredAccounts()
        let visibleProviderTitles = availableProviders.map(\.menuBarTitlePrefix)

        Task {
            defer {
                isRefreshing = false

                if needsRefreshAfterCurrentRun {
                    needsRefreshAfterCurrentRun = false
                    refreshNow()
                }
            }

            guard !availableAccounts.isEmpty else {
                logInfo("No supported providers detected locally.")
                return
            }

            logInfo("Refreshing detected providers: \(visibleProviderTitles.joined(separator: ", "))")

            let results = await Self.loadAccounts(availableAccounts)
            apply(results: results)
        }
    }

    func snapshot(for provider: AgentProviderKind) -> AgentQuotaSnapshot? {
        summarySnapshot(for: provider)
    }

    func errorMessage(for provider: AgentProviderKind) -> String? {
        summaryError(for: provider)
    }

    func usedPercent(for provider: AgentProviderKind) -> Double? {
        summarySnapshot(for: provider)?.highlightMetric?.usedPercent
    }

    // MARK: - Private

    private func summarySnapshot(for provider: AgentProviderKind) -> AgentQuotaSnapshot? {
        let snapshots = visibleAccountStatuses(for: provider).compactMap(\.snapshot)
        return snapshots.max { snapshotPriority($0) < snapshotPriority($1) } ?? snapshots.first
    }

    private func summaryError(for provider: AgentProviderKind) -> String? {
        guard summarySnapshot(for: provider) == nil else { return nil }
        return visibleAccountStatuses(for: provider).compactMap(\.errorMessage).first
    }

    private func snapshotPriority(_ snapshot: AgentQuotaSnapshot) -> Double {
        snapshot.highlightMetric?.usedPercent ?? -1
    }

    private func accountStatus(for account: ConfiguredAgentAccount) -> AgentAccountStatus {
        AgentAccountStatus(
            account: account,
            snapshot: accountSnapshotsByID[account.id],
            errorMessage: accountErrorsByID[account.id],
            credentialsDetected: isConfiguredAccountAvailable(account)
        )
    }

    private func setPrimaryAccountState(
        snapshot: AgentQuotaSnapshot?,
        error: String?,
        for provider: AgentProviderKind
    ) {
        let account = ConfiguredAgentAccount(
            provider: provider,
            directory: configuredAccounts(for: provider).first ?? provider.defaultAccountDirectory
        )
        setAccountState(snapshot: snapshot, error: error, for: account)
    }

    private func setAccountState(
        snapshot: AgentQuotaSnapshot?,
        error: String?,
        for account: ConfiguredAgentAccount
    ) {
        if let snapshot {
            accountSnapshotsByID[account.id] = snapshot
        } else {
            accountSnapshotsByID.removeValue(forKey: account.id)
        }

        if let error, !error.isEmpty {
            accountErrorsByID[account.id] = error
        } else {
            accountErrorsByID.removeValue(forKey: account.id)
        }
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
        pruneStoredAccountResults()
        providerAvailability = providerAvailabilityOverride?() ?? computedProviderAvailability()
    }

    private func computedProviderAvailability() -> AgentProviderAvailability {
        AgentProviderAvailability(
            codex: hasAvailableAccount(for: .codex),
            githubCopilot: hasAvailableAccount(for: .githubCopilot),
            gemini: hasAvailableAccount(for: .gemini),
            claude: hasAvailableAccount(for: .claude)
        )
    }

    private func hasAvailableAccount(for provider: AgentProviderKind) -> Bool {
        configuredAccounts(for: provider).contains { directory in
            isConfiguredAccountAvailable(
                ConfiguredAgentAccount(provider: provider, directory: directory)
            )
        }
    }

    private func allConfiguredAccounts() -> [ConfiguredAgentAccount] {
        AgentProviderKind.allCases.flatMap { provider in
            configuredAccounts(for: provider).map { directory in
                ConfiguredAgentAccount(provider: provider, directory: directory)
            }
        }
    }

    private func availableConfiguredAccounts() -> [ConfiguredAgentAccount] {
        allConfiguredAccounts().filter(isConfiguredAccountAvailable)
    }

    private func isConfiguredAccountAvailable(_ account: ConfiguredAgentAccount) -> Bool {
        switch account.provider {
        case .codex:
            return CodexQuotaService(
                installation: CodexInstallation(rootDirectory: account.directory.url)
            ).isAvailable
        case .githubCopilot:
            return GitHubCopilotQuotaService(
                installation: GitHubCopilotCLIInstallation(configDirectory: account.directory.url)
            ).isAvailable
        case .gemini:
            return GeminiQuotaService(
                installation: GeminiCLIInstallation(
                    configDirectory: account.directory.url,
                    executableLocations: GeminiCLIInstallation.defaultExecutableLocations
                )
            ).isAvailable
        case .claude:
            return ClaudeQuotaService(
                installation: ClaudeCLIInstallation(configDirectory: account.directory.url)
            ).isAvailable
        }
    }

    private func pruneStoredAccountResults() {
        let accounts = allConfiguredAccounts()
        let validIDs = Set(accounts.map(\.id))
        accountSnapshotsByID = accountSnapshotsByID.filter { validIDs.contains($0.key) }
        accountErrorsByID = accountErrorsByID.filter { validIDs.contains($0.key) }

        let unavailableIDs = Set(
            accounts
                .filter { !isConfiguredAccountAvailable($0) }
                .map(\.id)
        )

        clearStoredAccountState(for: unavailableIDs)
    }

    private func clearStoredAccountState(for accountIDs: some Sequence<String>) {
        for accountID in accountIDs {
            accountSnapshotsByID.removeValue(forKey: accountID)
            accountErrorsByID.removeValue(forKey: accountID)
        }
    }

    private func updateConfiguredAccounts(
        _ directories: [ConfiguredAccountDirectory],
        for provider: AgentProviderKind
    ) {
        configuredDirectoriesByProvider[provider] = directories
        persistConfiguredAccounts(for: provider)
        refreshProviderAvailability()

        guard autoRefreshEnabled else { return }

        if isRefreshing {
            needsRefreshAfterCurrentRun = true
        } else {
            refreshNow()
        }
    }

    private func persistConfiguredAccounts(for provider: AgentProviderKind) {
        userDefaults.set(
            configuredAccounts(for: provider).map(\.path),
            forKey: Self.configuredAccountDirectoriesDefaultsKey(for: provider)
        )
    }

    private func apply(results: [AccountRefreshResult]) {
        let configuredIDs = Set(allConfiguredAccounts().map(\.id))

        for result in results where configuredIDs.contains(result.account.id) {
            switch result.result {
            case .success(let snapshot):
                setAccountState(snapshot: snapshot, error: nil, for: result.account)
                if let metric = snapshot.highlightMetric {
                    logInfo("\(result.account.provider.title) account \(snapshot.accountLabel) loaded — \(metric.percentText) remaining")
                } else {
                    logInfo("\(result.account.provider.title) account \(snapshot.accountLabel) loaded — local auth detected")
                }
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                setAccountState(snapshot: nil, error: message, for: result.account)
                logError("[AppModel] \(result.account.provider.title) refresh failed for \(result.account.displayPath): \(message)")
            }
        }

        refreshProviderAvailability()
    }

    private static func loadAccounts(
        _ accounts: [ConfiguredAgentAccount]
    ) async -> [AccountRefreshResult] {
        await withTaskGroup(of: AccountRefreshResult.self, returning: [AccountRefreshResult].self) { group in
            for account in accounts {
                group.addTask {
                    await loadAccount(account)
                }
            }

            var results: [AccountRefreshResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    private static func loadAccount(_ account: ConfiguredAgentAccount) async -> AccountRefreshResult {
        do {
            return AccountRefreshResult(
                account: account,
                result: .success(try await loadSnapshot(for: account))
            )
        } catch {
            return AccountRefreshResult(account: account, result: .failure(error))
        }
    }

    private static func loadSnapshot(for account: ConfiguredAgentAccount) async throws -> AgentQuotaSnapshot {
        switch account.provider {
        case .codex:
            return try await CodexQuotaService(
                installation: CodexInstallation(rootDirectory: account.directory.url)
            ).loadSnapshot()
        case .githubCopilot:
            return try await GitHubCopilotQuotaService(
                installation: GitHubCopilotCLIInstallation(configDirectory: account.directory.url)
            ).loadSnapshot()
        case .gemini:
            return try await GeminiQuotaService(
                installation: GeminiCLIInstallation(
                    configDirectory: account.directory.url,
                    executableLocations: GeminiCLIInstallation.defaultExecutableLocations
                )
            ).loadSnapshot()
        case .claude:
            return try await ClaudeQuotaService(
                installation: ClaudeCLIInstallation(configDirectory: account.directory.url)
            ).loadSnapshot()
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
            let value = menuBarValueText(snapshot: snapshot, error: error, style: .percent)
            let separator = value.first?.isNumber == true ? "" : " "
            return "\(shortTitle)\(separator)\(value)"
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

        if snapshot != nil {
            return "\(title) ready"
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

        if snapshot != nil {
            return "Ready"
        }

        if error != nil {
            return "!"
        }

        return "--"
    }

    private static func loadConfiguredDirectories(
        from userDefaults: UserDefaults
    ) -> [AgentProviderKind: [ConfiguredAccountDirectory]] {
        Dictionary(uniqueKeysWithValues: AgentProviderKind.allCases.map { provider in
            (
                provider,
                loadConfiguredAccounts(for: provider, from: userDefaults)
            )
        })
    }

    private static func loadConfiguredAccounts(
        for provider: AgentProviderKind,
        from userDefaults: UserDefaults
    ) -> [ConfiguredAccountDirectory] {
        let key = configuredAccountDirectoriesDefaultsKey(for: provider)
        guard userDefaults.object(forKey: key) != nil else {
            return [provider.defaultAccountDirectory]
        }

        return ConfiguredAccountDirectory.unique(paths: userDefaults.stringArray(forKey: key) ?? [])
    }

    private static func configuredAccountDirectoriesDefaultsKey(
        for provider: AgentProviderKind
    ) -> String {
        "\(configuredAccountDirectoriesDefaultsKeyPrefix)\(provider.rawValue)"
    }

    private static func normalizedRefreshInterval(_ value: Int?) -> Int {
        let rawValue = value ?? defaultRefreshIntervalSeconds
        return min(max(rawValue, minimumRefreshIntervalSeconds), maximumRefreshIntervalSeconds)
    }

    private enum MenuBarValueStyle {
        case percent
        case remainingLabel
    }

    enum AddConfiguredAccountDirectoryResult: Equatable {
        case added
        case emptyPath
        case duplicate
    }

    private struct AccountRefreshResult {
        let account: ConfiguredAgentAccount
        let result: Result<AgentQuotaSnapshot, Error>
    }
}
