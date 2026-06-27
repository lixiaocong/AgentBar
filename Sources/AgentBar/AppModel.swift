import AppKit
import CryptoKit
import Foundation
import os

#if canImport(AgentBarCore)
import AgentBarCore
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel(startImmediately: false)
    static let defaultRefreshIntervalSeconds = 10
    static let minimumRefreshIntervalSeconds = 5
    static let maximumRefreshIntervalSeconds = 300
    static let refreshIntervalStepSeconds = 5
    static let defaultMenuBarMaxDisplayedAccounts = 2
    static let minimumMenuBarMaxDisplayedAccounts = 1
    static let maximumMenuBarMaxDisplayedAccounts = 3

    private static let menuBarMaxDisplayedAccountsDefaultsKey = "menuBarMaxDisplayedAgents"
    private static let menuBarSelectedAccountIDsDefaultsKey = "menuBarSelectedAccountIDs"
    private static let refreshIntervalDefaultsKey = "refreshIntervalSeconds"
    private static let configuredAccountDirectoriesDefaultsKeyPrefix = "configuredAccountDirectories."
    private static let accountLabelsDefaultsKey = "configuredAccountLabels"
    private let userDefaults: UserDefaults
    private let providerAvailabilityOverride: (@Sendable () -> AgentProviderAvailability)?
    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false
    private var needsRefreshAfterCurrentRun = false
    private var configuredDirectoriesByProvider: [AgentProviderKind: [ConfiguredAccountDirectory]]
    private var accountSnapshotsByID: [String: AgentQuotaSnapshot] = [:]
    private var accountErrorsByID: [String: String] = [:]
    private var accountLabelsByID: [String: String]
    private var isMenuBarAccountSelectionExplicit = false
    private var codexReconnectInProgressAccountIDs: Set<String> = []
    private var codexAutoReconnectAttemptedAccountIDs: Set<String> = []
    private var codexRevokedAccountIDs: Set<String> = []

    var providerAvailability: AgentProviderAvailability
    var isRefreshing = false
    var isCodexLoginInProgress = false
    var codexLoginError: String?
    var providerLoginInProgress: Set<AgentProviderKind> = []
    var providerLoginErrors: [AgentProviderKind: String] = [:]
    var providerLoginMessages: [AgentProviderKind: String] = [:]
    var menuBarMaxDisplayedAccounts: Int {
        didSet {
            let normalized = Self.normalizedMenuBarMaxDisplayedAccounts(menuBarMaxDisplayedAccounts)
            if menuBarMaxDisplayedAccounts != normalized {
                menuBarMaxDisplayedAccounts = normalized
                return
            }

            guard oldValue != menuBarMaxDisplayedAccounts else { return }
            userDefaults.set(menuBarMaxDisplayedAccounts, forKey: Self.menuBarMaxDisplayedAccountsDefaultsKey)
            trimMenuBarSelectedAccountIDsToDisplayLimit()
        }
    }
    var menuBarSelectedAccountIDs: [String] = [] {
        didSet {
            guard oldValue != menuBarSelectedAccountIDs else { return }
            persistMenuBarAccountSelection()
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

    var zaiSnapshot: AgentQuotaSnapshot? {
        get { summarySnapshot(for: .zai) }
        set { setPrimaryAccountState(snapshot: newValue, error: nil, for: .zai) }
    }

    var junieSnapshot: AgentQuotaSnapshot? {
        get { summarySnapshot(for: .junie) }
        set { setPrimaryAccountState(snapshot: newValue, error: nil, for: .junie) }
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

    var zaiError: String? {
        get { summaryError(for: .zai) }
        set { setPrimaryAccountState(snapshot: nil, error: newValue, for: .zai) }
    }

    var junieError: String? {
        get { summaryError(for: .junie) }
        set { setPrimaryAccountState(snapshot: nil, error: newValue, for: .junie) }
    }

    init(
        userDefaults: UserDefaults = .standard,
        providerAvailabilityResolver: (@Sendable () -> AgentProviderAvailability)? = nil,
        startImmediately: Bool = true
    ) {
        self.userDefaults = userDefaults
        self.providerAvailabilityOverride = providerAvailabilityResolver
        self.configuredDirectoriesByProvider = Self.loadConfiguredDirectories(from: userDefaults)
        self.accountLabelsByID = userDefaults.dictionary(forKey: Self.accountLabelsDefaultsKey) as? [String: String] ?? [:]
        self.providerAvailability = .none
        menuBarMaxDisplayedAccounts = Self.normalizedMenuBarMaxDisplayedAccounts(
            userDefaults.object(forKey: Self.menuBarMaxDisplayedAccountsDefaultsKey) as? Int
        )
        isMenuBarAccountSelectionExplicit = userDefaults.object(forKey: Self.menuBarSelectedAccountIDsDefaultsKey) != nil
        menuBarSelectedAccountIDs = Self.uniqueMenuBarAccountIDs(
            userDefaults.stringArray(forKey: Self.menuBarSelectedAccountIDsDefaultsKey) ?? []
        )
        refreshIntervalSeconds = Self.normalizedRefreshInterval(
            userDefaults.object(forKey: Self.refreshIntervalDefaultsKey) as? Int
        )

        if startImmediately {
            start()
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshProviderAvailability()
        refreshNow()
        startAutoRefresh()
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
                title: provider.menuBarTitlePrefix,
                snapshot: snapshot(for: provider),
                error: errorMessage(for: provider)
            )
        }

        return segments.isEmpty ? "Agent Bar" : segments.joined(separator: "  ")
    }

    var menuBarAccessibilityTitle: String {
        let segments = menuBarAccountStatuses.map { status in
            accessibilitySummarySegment(for: status)
        }

        if !segments.isEmpty {
            return segments.joined(separator: ", ")
        }

        if availableProviders.isEmpty {
            return "No supported agents detected on this Mac"
        }

        return isMenuBarAccountSelectionExplicit ? "No menu bar accounts selected" : "No signed-in accounts available"
    }

    var statusIconQuotaBars: [MenuBarStatusImage.Bar] {
        let statuses = Array(menuBarAccountStatuses.prefix(menuBarMaxDisplayedAccounts))

        guard !statuses.isEmpty else {
            return [MenuBarStatusImage.Bar(provider: nil, remainingPercent: nil)]
        }

        let providerCounts = Dictionary(grouping: statuses, by: \.provider).mapValues(\.count)
        var providerIndexes: [AgentProviderKind: Int] = [:]

        return statuses.map { status in
            let provider = status.provider
            let index = (providerIndexes[provider] ?? 0) + 1
            providerIndexes[provider] = index

            return MenuBarStatusImage.Bar(
                provider: provider,
                label: statusIconLabel(
                    for: status,
                    duplicateIndex: index,
                    duplicateCount: providerCounts[provider] ?? 1
                ),
                remainingPercent: status.snapshot?.highlightMetric?.remainingPercent,
                isError: status.errorMessage != nil
            )
        }
    }

    var hasExplicitMenuBarAccountSelection: Bool {
        isMenuBarAccountSelectionExplicit
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

    var zaiUsedPercent: Double? {
        usedPercent(for: .zai)
    }

    var junieUsedPercent: Double? {
        usedPercent(for: .junie)
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

    func isAccountShownInMenuBar(_ account: ConfiguredAgentAccount) -> Bool {
        effectiveMenuBarSelectedAccountIDs.contains(account.id)
    }

    func setAccount(_ account: ConfiguredAgentAccount, shownInMenuBar: Bool) {
        var selectedIDs = effectiveMenuBarSelectedAccountIDs.filter { $0 != account.id }

        if shownInMenuBar {
            while selectedIDs.count >= menuBarMaxDisplayedAccounts {
                selectedIDs.removeFirst()
            }

            selectedIDs.append(account.id)
        }

        isMenuBarAccountSelectionExplicit = true
        menuBarSelectedAccountIDs = Self.uniqueMenuBarAccountIDs(selectedIDs)
    }

    func isCodexReconnectInProgress(_ account: ConfiguredAgentAccount) -> Bool {
        codexReconnectInProgressAccountIDs.contains(account.id)
    }

    func reconnectCodexAccount(_ account: ConfiguredAgentAccount) {
        startCodexReconnect(for: account, automatic: false)
    }

    func resetMenuBarAccountSelection() {
        isMenuBarAccountSelectionExplicit = false
        menuBarSelectedAccountIDs = []
        userDefaults.removeObject(forKey: Self.menuBarSelectedAccountIDsDefaultsKey)
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
        if provider == .claude {
            guard Self.hasClaudeAuthFile(in: directory) else {
                return .credentialsFileMissing(
                    ClaudeCLIInstallation(configDirectory: directory.url).authFile.path
                )
            }
        } else if !isAppManagedAccountDirectory(directory, for: provider) {
            return .browserLoginRequired
        }

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

    @discardableResult
    func addJunieAPIToken(_ rawToken: String) -> AddJunieAPITokenResult {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .emptyToken
        }

        let accountID = Self.stableJunieAccountID(for: token)
        let directoryURL = AgentProviderAppAuthStore.accountDirectory(
            for: .junie,
            accountID: accountID
        )
        let directory = ConfiguredAccountDirectory(path: directoryURL.path)
        guard !configuredAccounts(for: .junie).contains(directory) else {
            return .duplicate
        }

        do {
            let session = AgentProviderStoredAuthSession(
                provider: .junie,
                accountID: accountID,
                accountLabel: "Junie API Key",
                accessToken: token,
                refreshToken: nil,
                expiryDate: nil,
                scopes: ["junie"],
                lastRefresh: Date()
            )
            try AgentProviderAppAuthStore.save(session: session)
            try AgentProviderAppAuthStore.ensureAccountDirectoryExists(
                for: .junie,
                accountID: accountID
            )
            let result = addConfiguredAccountDirectory(path: directoryURL.path, for: .junie)
            switch result {
            case .added:
                persistStoredAccountLabelIfNeeded(
                    for: ConfiguredAgentAccount(provider: .junie, directory: directory),
                    accountLabel: session.accountLabel
                )
                return .added
            case .duplicate:
                return .duplicate
            case .emptyPath, .browserLoginRequired:
                return .saveFailed("Junie token was saved, but AgentBar could not save the account reference.")
            case .credentialsFileMissing(let path):
                return .saveFailed("Junie token was saved, but AgentBar could not find the saved account at \(path).")
            }
        } catch {
            return .saveFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    @discardableResult
    func addZAICodingPlanCredential(
        _ rawToken: String,
        baseURL rawBaseURL: String = ZAIQuotaService.defaultMonitorBaseURL.absoluteString
    ) -> AddZAICodingPlanCredentialResult {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .emptyToken
        }

        let baseURL: URL
        do {
            baseURL = try ZAIQuotaService.normalizedMonitorBaseURL(from: rawBaseURL)
        } catch {
            return .invalidBaseURL
        }

        let accountID = Self.stableZAIAccountID(for: token, baseURL: baseURL)
        let directoryURL = AgentProviderAppAuthStore.accountDirectory(
            for: .zai,
            accountID: accountID
        )
        let directory = ConfiguredAccountDirectory(path: directoryURL.path)
        guard !configuredAccounts(for: .zai).contains(directory) else {
            return .duplicate
        }

        do {
            let session = AgentProviderStoredAuthSession(
                provider: .zai,
                accountID: accountID,
                accountLabel: "Z.ai Coding Plan",
                accessToken: token,
                refreshToken: nil,
                expiryDate: nil,
                scopes: [
                    "zai-coding-plan",
                    ZAIQuotaService.baseURLScopeValue(from: baseURL)
                ],
                lastRefresh: Date()
            )
            try AgentProviderAppAuthStore.save(session: session)
            try AgentProviderAppAuthStore.ensureAccountDirectoryExists(
                for: .zai,
                accountID: accountID
            )
            let result = addConfiguredAccountDirectory(path: directoryURL.path, for: .zai)
            switch result {
            case .added:
                persistStoredAccountLabelIfNeeded(
                    for: ConfiguredAgentAccount(provider: .zai, directory: directory),
                    accountLabel: session.accountLabel
                )
                return .added
            case .duplicate:
                return .duplicate
            case .emptyPath, .browserLoginRequired:
                return .saveFailed("Z.ai Coding Plan credential was saved, but AgentBar could not save the account reference.")
            case .credentialsFileMissing(let path):
                return .saveFailed("Z.ai Coding Plan credential was saved, but AgentBar could not find the saved account at \(path).")
            }
        } catch {
            return .saveFailed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    func removeConfiguredAccount(_ account: ConfiguredAgentAccount) {
        if account.provider == .codex,
           let accountID = CodexAppAuthStore.accountID(fromAccountDirectory: account.directory.url) {
            _ = try? CodexAppAuthStore.deleteSession(accountID: accountID)
            try? CodexAppAuthStore.deleteAccountDirectory(accountID: accountID)
        } else if let accountID = AgentProviderAppAuthStore.accountID(
            fromAccountDirectory: account.directory.url,
            provider: account.provider
        ) {
            _ = try? AgentProviderAppAuthStore.deleteSession(provider: account.provider, accountID: accountID)
            try? AgentProviderAppAuthStore.deleteAccountDirectory(provider: account.provider, accountID: accountID)
        }

        let updated = configuredAccounts(for: account.provider).filter { $0 != account.directory }
        clearStoredAccountState(for: [account.id])
        codexReconnectInProgressAccountIDs.remove(account.id)
        codexAutoReconnectAttemptedAccountIDs.remove(account.id)
        codexRevokedAccountIDs.remove(account.id)
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
        let refreshableAccounts = availableConfiguredAccounts().filter(shouldRefreshAccount)
        let visibleProviderTitles = availableProviders.map(\.menuBarTitlePrefix)

        Task {
            defer {
                isRefreshing = false

                if needsRefreshAfterCurrentRun {
                    needsRefreshAfterCurrentRun = false
                    refreshNow()
                }
            }

            guard !refreshableAccounts.isEmpty else {
                logInfo("No accounts need refresh right now.")
                return
            }

            logInfo("Refreshing detected providers: \(visibleProviderTitles.joined(separator: ", "))")

            let results = await Self.loadAccounts(refreshableAccounts)
            apply(results: results)
        }
    }

    func signInToCodexWithBrowser() {
        signInWithBrowser(for: .codex)
    }

    func isLoginInProgress(for provider: AgentProviderKind) -> Bool {
        provider == .codex ? isCodexLoginInProgress : providerLoginInProgress.contains(provider)
    }

    func loginError(for provider: AgentProviderKind) -> String? {
        provider == .codex ? codexLoginError : providerLoginErrors[provider]
    }

    func loginMessage(for provider: AgentProviderKind) -> String? {
        providerLoginMessages[provider]
    }

    func supportsBrowserSignIn(for provider: AgentProviderKind) -> Bool {
        switch provider {
        case .codex, .githubCopilot, .gemini:
            return true
        case .claude, .zai, .junie:
            return false
        }
    }

    func signInWithBrowser(for provider: AgentProviderKind, forceAccountSelection: Bool = false) {
        guard supportsBrowserSignIn(for: provider) else {
            switch provider {
            case .claude:
                providerLoginErrors[provider] = "Claude accounts are read from Claude Code auth.json. Add a directory containing auth.json instead of browser sign-in."
            case .junie:
                providerLoginErrors[provider] = "Junie accounts must be added with a Junie API token from AgentBar settings."
            case .zai:
                providerLoginErrors[provider] = "Z.ai accounts must be added with a Coding Plan credential from AgentBar settings."
            case .codex, .githubCopilot, .gemini:
                break
            }
            return
        }

        if provider == .codex {
            signInToCodexWithBrowserImpl()
            return
        }

        guard !providerLoginInProgress.contains(provider) else {
            return
        }

        providerLoginInProgress.insert(provider)
        providerLoginErrors[provider] = nil
        providerLoginMessages[provider] = nil

        Task {
            defer {
                providerLoginInProgress.remove(provider)
            }

            do {
                let session: AgentProviderStoredAuthSession
                switch provider {
                case .githubCopilot:
                    session = try await GitHubCopilotBrowserLoginService().signIn { message in
                        self.providerLoginMessages[provider] = message
                    }
                case .gemini:
                    session = try await GeminiBrowserLoginService().signIn(forceAccountSelection: forceAccountSelection)
                case .codex, .claude, .zai, .junie:
                    return
                }

                try AgentProviderAppAuthStore.save(session: session)
                try AgentProviderAppAuthStore.ensureAccountDirectoryExists(
                    for: provider,
                    accountID: session.accountID
                )
                let directoryURL = AgentProviderAppAuthStore.accountDirectory(
                    for: provider,
                    accountID: session.accountID
                )
                let addResult = addConfiguredAccountDirectory(path: directoryURL.path, for: provider)
                let account = ConfiguredAgentAccount(
                    provider: provider,
                    directory: ConfiguredAccountDirectory(path: directoryURL.path)
                )
                persistStoredAccountLabelIfNeeded(for: account, accountLabel: session.accountLabel)

                switch addResult {
                case .added:
                    providerLoginErrors[provider] = nil
                    providerLoginMessages[provider] = nil
                    break
                case .duplicate:
                    if provider == .gemini {
                        providerLoginErrors[provider] = nil
                        providerLoginMessages[provider] = "Gemini credentials refreshed for the existing account."
                    } else {
                        providerLoginErrors[provider] = "That \(provider.title) account is already signed in. Choose a different account in the browser and try again."
                    }
                    refreshProviderAvailability()
                    refreshNow()
                case .emptyPath, .browserLoginRequired:
                    providerLoginErrors[provider] = "\(provider.title) sign-in completed, but AgentBar could not save the account reference."
                case .credentialsFileMissing:
                    providerLoginErrors[provider] = "\(provider.title) sign-in completed, but AgentBar could not find the saved credentials."
                }
            } catch {
                providerLoginErrors[provider] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func signInToCodexWithBrowserImpl() {
        guard !isCodexLoginInProgress else {
            return
        }

        isCodexLoginInProgress = true
        codexLoginError = nil

        Task {
            defer {
                isCodexLoginInProgress = false
            }

            do {
                let authSession = try await CodexBrowserLoginService().signIn()
                let localAccountID = CodexAppAuthStore.localAccountID(
                    for: authSession,
                    existingLocalAccountIDs: configuredCodexLocalAccountIDs()
                )
                let session = CodexStoredAuthSession(
                    idToken: authSession.idToken,
                    accessToken: authSession.accessToken,
                    refreshToken: authSession.refreshToken,
                    accountID: authSession.accountID,
                    localAccountID: localAccountID,
                    lastRefresh: authSession.lastRefresh
                )
                try CodexAppAuthStore.save(session: session)
                try CodexAppAuthStore.ensureAccountDirectoryExists(for: localAccountID)
                let directoryURL = CodexAppAuthStore.accountDirectory(for: localAccountID)
                let addResult = addConfiguredAccountDirectory(path: directoryURL.path, for: .codex)
                let account = ConfiguredAgentAccount(
                    provider: .codex,
                    directory: ConfiguredAccountDirectory(path: directoryURL.path)
                )
                codexRevokedAccountIDs.remove(account.id)
                codexAutoReconnectAttemptedAccountIDs.remove(account.id)
                persistStoredAccountLabelIfNeeded(
                    for: account,
                    accountLabel: CodexQuotaService().preferredAccountLabel(
                        idToken: session.idToken,
                        fallbackAccountID: session.accountID
                    )
                )

                switch addResult {
                case .added:
                    codexLoginError = nil
                    break
                case .duplicate:
                    codexLoginError = "That Codex account is already signed in. Choose a different account in the browser, or sign out of ChatGPT there and try again."
                    refreshProviderAvailability()
                    refreshNow()
                case .emptyPath, .browserLoginRequired:
                    codexLoginError = "Codex sign-in completed, but AgentBar could not save the account reference."
                case .credentialsFileMissing:
                    codexLoginError = "Codex sign-in completed, but AgentBar could not find the saved credentials."
                }
            } catch {
                codexLoginError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
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
            accountLabel: cachedAccountLabel(for: account),
            snapshot: accountSnapshotsByID[account.id],
            errorMessage: accountErrorsByID[account.id],
            credentialsDetected: isConfiguredAccountAvailable(account)
        )
    }

    private func cachedAccountLabel(for account: ConfiguredAgentAccount) -> String? {
        accountLabelsByID[account.id]
    }

    private func configuredCodexLocalAccountIDs() -> [String] {
        configuredAccounts(for: .codex).compactMap { directory in
            CodexAppAuthStore.accountID(fromAccountDirectory: directory.url)
        }
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

        persistWidgetState()
    }

    private func startAutoRefresh() {
        refreshTask?.cancel()

        guard hasStarted else { return }
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
        persistWidgetState()
    }

    private func computedProviderAvailability() -> AgentProviderAvailability {
        AgentProviderAvailability(
            codex: hasAvailableAccount(for: .codex),
            githubCopilot: hasAvailableAccount(for: .githubCopilot),
            gemini: hasAvailableAccount(for: .gemini),
            claude: hasAvailableAccount(for: .claude),
            zai: hasAvailableAccount(for: .zai),
            junie: hasAvailableAccount(for: .junie)
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

    private var menuBarCandidateAccountStatuses: [AgentAccountStatus] {
        availableProviders.flatMap(accountStatuses(for:))
    }

    private var defaultMenuBarSelectedAccountIDs: [String] {
        Array(menuBarCandidateAccountStatuses.prefix(menuBarMaxDisplayedAccounts).map(\.id))
    }

    private var effectiveMenuBarSelectedAccountIDs: [String] {
        isMenuBarAccountSelectionExplicit
            ? menuBarSelectedAccountIDs
            : defaultMenuBarSelectedAccountIDs
    }

    private var menuBarAccountStatuses: [AgentAccountStatus] {
        let candidates = menuBarCandidateAccountStatuses
        let statusesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

        if isMenuBarAccountSelectionExplicit {
            return menuBarSelectedAccountIDs.compactMap { statusesByID[$0] }
        }

        return Array(candidates.prefix(menuBarMaxDisplayedAccounts))
    }

    private func availableConfiguredAccounts() -> [ConfiguredAgentAccount] {
        allConfiguredAccounts().filter(isConfiguredAccountAvailable)
    }

    private func shouldRefreshAccount(_ account: ConfiguredAgentAccount) -> Bool {
        guard account.provider == .codex else { return true }
        return !codexRevokedAccountIDs.contains(account.id) &&
            !codexReconnectInProgressAccountIDs.contains(account.id)
    }

    private func isConfiguredAccountAvailable(_ account: ConfiguredAgentAccount) -> Bool {
        AgentAccountSnapshotLoader.isAvailable(account)
    }

    private func pruneStoredAccountResults() {
        let accounts = allConfiguredAccounts()
        let validIDs = Set(accounts.map(\.id))
        accountSnapshotsByID = accountSnapshotsByID.filter { validIDs.contains($0.key) }
        accountErrorsByID = accountErrorsByID.filter { validIDs.contains($0.key) }
        let labelsBeforePrune = accountLabelsByID
        accountLabelsByID = accountLabelsByID.filter { validIDs.contains($0.key) }
        if labelsBeforePrune != accountLabelsByID {
            persistCachedAccountLabels()
        }

        let unavailableIDs = Set(
            accounts
                .filter { !isConfiguredAccountAvailable($0) }
                .map(\.id)
        )

        clearStoredAccountState(for: unavailableIDs)
    }

    private func clearStoredAccountState(for accountIDs: some Sequence<String>) {
        var didClearLabel = false
        for accountID in accountIDs {
            accountSnapshotsByID.removeValue(forKey: accountID)
            accountErrorsByID.removeValue(forKey: accountID)
            if accountLabelsByID.removeValue(forKey: accountID) != nil {
                didClearLabel = true
            }
        }

        if didClearLabel {
            persistCachedAccountLabels()
        }
    }

    private func persistCachedAccountLabels() {
        userDefaults.set(accountLabelsByID, forKey: Self.accountLabelsDefaultsKey)
    }

    private func updateConfiguredAccounts(
        _ directories: [ConfiguredAccountDirectory],
        for provider: AgentProviderKind
    ) {
        configuredDirectoriesByProvider[provider] = directories
        persistConfiguredAccounts(for: provider)
        pruneMenuBarSelectedAccountIDs()
        refreshProviderAvailability()

        guard hasStarted else { return }

        if isRefreshing {
            needsRefreshAfterCurrentRun = true
        } else {
            refreshNow()
        }
    }

    private func trimMenuBarSelectedAccountIDsToDisplayLimit() {
        guard isMenuBarAccountSelectionExplicit,
              menuBarSelectedAccountIDs.count > menuBarMaxDisplayedAccounts else {
            return
        }

        menuBarSelectedAccountIDs = Array(menuBarSelectedAccountIDs.prefix(menuBarMaxDisplayedAccounts))
    }

    private func pruneMenuBarSelectedAccountIDs() {
        guard isMenuBarAccountSelectionExplicit else { return }

        let configuredIDs = Set(allConfiguredAccounts().map(\.id))
        menuBarSelectedAccountIDs = menuBarSelectedAccountIDs.filter(configuredIDs.contains)
    }

    private func persistMenuBarAccountSelection() {
        guard isMenuBarAccountSelectionExplicit else { return }

        userDefaults.set(
            Self.uniqueMenuBarAccountIDs(menuBarSelectedAccountIDs),
            forKey: Self.menuBarSelectedAccountIDsDefaultsKey
        )
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
                if result.account.provider == .codex {
                    codexRevokedAccountIDs.remove(result.account.id)
                    codexAutoReconnectAttemptedAccountIDs.remove(result.account.id)
                }
                setAccountState(snapshot: snapshot, error: nil, for: result.account)
                persistStoredAccountLabelIfNeeded(for: result.account, accountLabel: snapshot.accountLabel)
                if let metric = snapshot.highlightMetric {
                    logInfo("\(result.account.provider.title) account \(snapshot.accountLabel) loaded — \(metric.percentText) remaining")
                } else {
                    logInfo("\(result.account.provider.title) account \(snapshot.accountLabel) loaded — local auth detected")
                }
            case .failure(let error):
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if result.account.provider == .codex,
                   isRecoverableCodexRevocation(error) {
                    codexRevokedAccountIDs.insert(result.account.id)
                    setAccountState(
                        snapshot: nil,
                        error: "Codex login was revoked. AgentBar is opening browser sign-in to reconnect this account.",
                        for: result.account
                    )
                    startCodexReconnect(for: result.account, automatic: true)
                } else if result.account.provider == .gemini,
                          isInvalidGeminiLogin(error) {
                    removeInvalidGeminiAccount(result.account)
                } else {
                    setAccountState(snapshot: nil, error: message, for: result.account)
                }
                logError("[AppModel] \(result.account.provider.title) refresh failed for \(result.account.displayPath): \(message)")
            }
        }

        refreshProviderAvailability()
    }

    private func isRecoverableCodexRevocation(_ error: Error) -> Bool {
        if let codexError = error as? CodexQuotaError,
           case .tokenRevoked = codexError {
            return true
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return message.localizedCaseInsensitiveContains("token_revoked") ||
            message.localizedCaseInsensitiveContains("token_invalidated") ||
            message.localizedCaseInsensitiveContains("invalidated oauth token")
    }

    private func isInvalidGeminiLogin(_ error: Error) -> Bool {
        if let geminiError = error as? GeminiQuotaError {
            return geminiError.invalidatesStoredLogin
        }

        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return message.localizedCaseInsensitiveContains("invalid_grant")
            || message.localizedCaseInsensitiveContains("invalid_token")
            || message.localizedCaseInsensitiveContains("refresh token")
    }

    private func removeInvalidGeminiAccount(_ account: ConfiguredAgentAccount) {
        let message = "Stored Gemini login expired and was removed locally. Sign in again from AgentBar settings."
        setAccountState(snapshot: nil, error: message, for: account)
        providerLoginMessages[.gemini] = nil
        providerLoginErrors[.gemini] = message
        removeConfiguredAccount(account)
    }

    private func startCodexReconnect(for account: ConfiguredAgentAccount, automatic: Bool) {
        guard account.provider == .codex else { return }
        guard !codexReconnectInProgressAccountIDs.contains(account.id) else { return }
        if automatic {
            guard !codexAutoReconnectAttemptedAccountIDs.contains(account.id) else { return }
            codexAutoReconnectAttemptedAccountIDs.insert(account.id)
        }

        guard let localAccountID = CodexAppAuthStore.accountID(fromAccountDirectory: account.directory.url) else {
            return
        }

        let existingSession = try? CodexAppAuthStore.loadSession(accountID: localAccountID)
        codexReconnectInProgressAccountIDs.insert(account.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                codexReconnectInProgressAccountIDs.remove(account.id)
            }

            do {
                let authSession = try await CodexBrowserLoginService().signIn()
                try validateCodexReconnect(
                    existingSession: existingSession,
                    newSession: authSession
                )

                let session = CodexStoredAuthSession(
                    idToken: authSession.idToken,
                    accessToken: authSession.accessToken,
                    refreshToken: authSession.refreshToken,
                    accountID: authSession.accountID,
                    localAccountID: localAccountID,
                    lastRefresh: authSession.lastRefresh
                )
                try CodexAppAuthStore.save(session: session)
                try CodexAppAuthStore.ensureAccountDirectoryExists(for: localAccountID)
                codexRevokedAccountIDs.remove(account.id)
                codexAutoReconnectAttemptedAccountIDs.remove(account.id)
                persistStoredAccountLabelIfNeeded(
                    for: account,
                    accountLabel: CodexQuotaService().preferredAccountLabel(
                        idToken: session.idToken,
                        fallbackAccountID: session.accountID
                    )
                )

                setAccountState(
                    snapshot: nil,
                    error: nil,
                    for: account
                )
                refreshProviderAvailability()
                refreshNow()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                setAccountState(
                    snapshot: nil,
                    error: "Codex reconnect failed: \(message)",
                    for: account
                )
            }
        }
    }

    private func validateCodexReconnect(
        existingSession: CodexStoredAuthSession?,
        newSession: CodexStoredAuthSession
    ) throws {
        guard let existingSession else { return }

        guard existingSession.accountID == newSession.accountID else {
            throw CodexReconnectError.accountMismatch
        }

        let existingIdentity = CodexAppAuthStore.identity(from: existingSession.idToken)
        let newIdentity = CodexAppAuthStore.identity(from: newSession.idToken)
        let existingSpace = normalizedCodexSpaceIdentity(existingIdentity)
        let newSpace = normalizedCodexSpaceIdentity(newIdentity)
        if existingSpace != nil || newSpace != nil {
            guard existingSpace == newSpace else {
                throw CodexReconnectError.workspaceMismatch
            }
        }
    }

    private func normalizedCodexSpaceIdentity(_ identity: CodexTokenIdentity?) -> String? {
        if let spaceID = identity?.spaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !spaceID.isEmpty {
            return "id:\(spaceID.lowercased())"
        }

        if let spaceName = identity?.spaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !spaceName.isEmpty {
            return "name:\(spaceName.lowercased())"
        }

        return nil
    }

    private func persistStoredAccountLabelIfNeeded(
        for account: ConfiguredAgentAccount,
        accountLabel: String
    ) {
        let label = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty,
              accountLabelsByID[account.id] != label else {
            return
        }

        accountLabelsByID[account.id] = label
        persistCachedAccountLabels()
        persistWidgetState()
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
        try await AgentAccountSnapshotLoader.loadSnapshot(for: account)
    }

    private func menuBarSummarySegment(
        title: String,
        snapshot: AgentQuotaSnapshot?,
        error: String?
    ) -> String {
        "\(title) \(menuBarValueText(snapshot: snapshot, error: error))"
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

    private func accessibilitySummarySegment(for status: AgentAccountStatus) -> String {
        let title = status.displayLabel ?? status.provider.menuBarTitlePrefix

        if let snapshot = status.snapshot, let metric = snapshot.highlightMetric {
            return "\(title) \(status.provider.menuBarTitlePrefix) \(metric.percentText) remaining"
        }

        if status.snapshot != nil {
            return "\(title) \(status.provider.menuBarTitlePrefix) ready"
        }

        if status.errorMessage != nil {
            return "\(title) \(status.provider.menuBarTitlePrefix) unavailable"
        }

        return "\(title) \(status.provider.menuBarTitlePrefix) loading"
    }

    private func statusIconLabel(
        for status: AgentAccountStatus,
        duplicateIndex: Int,
        duplicateCount: Int
    ) -> String {
        duplicateAwareProviderLabel(
            shortProviderLabel(for: status.provider),
            duplicateIndex: duplicateIndex,
            duplicateCount: duplicateCount
        )
    }

    private func duplicateAwareProviderLabel(
        _ label: String,
        duplicateIndex: Int,
        duplicateCount: Int
    ) -> String {
        duplicateCount > 1 ? "\(label)\(duplicateIndex)" : label
    }

    private func shortProviderLabel(for provider: AgentProviderKind) -> String {
        switch provider {
        case .codex:
            return "cx"
        case .githubCopilot:
            return "cp"
        case .gemini:
            return "gm"
        case .claude:
            return "cl"
        case .zai:
            return "za"
        case .junie:
            return "jn"
        }
    }

    private func menuBarValueText(
        snapshot: AgentQuotaSnapshot?,
        error: String?
    ) -> String {
        if let snapshot, let metric = snapshot.highlightMetric {
            return metric.percentText
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
        if provider == .claude {
            let paths = userDefaults.stringArray(forKey: key) ?? [provider.defaultAccountDirectory.path]
            return ConfiguredAccountDirectory
                .unique(paths: paths)
                .filter(hasClaudeAuthFile)
        }

        if provider == .codex {
            return ConfiguredAccountDirectory
                .unique(paths: userDefaults.stringArray(forKey: key) ?? [])
                .filter(CodexAppAuthStore.isAppManagedAccountDirectory)
        }

        if provider == .githubCopilot || provider == .gemini || provider == .zai || provider == .junie {
            return ConfiguredAccountDirectory
                .unique(paths: userDefaults.stringArray(forKey: key) ?? [])
                .filter { AgentProviderAppAuthStore.isAppManagedAccountDirectory($0, provider: provider) }
        }

        return ConfiguredAccountDirectory.unique(paths: userDefaults.stringArray(forKey: key) ?? [])
    }

    private func isAppManagedAccountDirectory(
        _ directory: ConfiguredAccountDirectory,
        for provider: AgentProviderKind
    ) -> Bool {
        if provider == .codex {
            return CodexAppAuthStore.isAppManagedAccountDirectory(directory)
        }

        if provider == .claude {
            return Self.hasClaudeAuthFile(in: directory)
        }

        return AgentProviderAppAuthStore.isAppManagedAccountDirectory(directory, provider: provider)
    }

    private static func hasClaudeAuthFile(in directory: ConfiguredAccountDirectory) -> Bool {
        ClaudeQuotaService(
            installation: ClaudeCLIInstallation(configDirectory: directory.url)
        ).isAvailable
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

    private static func normalizedMenuBarMaxDisplayedAccounts(_ value: Int?) -> Int {
        let rawValue = value ?? defaultMenuBarMaxDisplayedAccounts
        return min(max(rawValue, minimumMenuBarMaxDisplayedAccounts), maximumMenuBarMaxDisplayedAccounts)
    }

    private static func uniqueMenuBarAccountIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()

        return ids.filter { id in
            seen.insert(id).inserted
        }
    }

    private static func stableJunieAccountID(for token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let prefix = digest.prefix(16).map { byte in
            String(format: "%02x", byte)
        }.joined()
        return "junie-\(prefix)"
    }

    private static func stableZAIAccountID(for token: String, baseURL: URL) -> String {
        let material = "\(baseURL.absoluteString)\n\(token)"
        let digest = SHA256.hash(data: Data(material.utf8))
        let prefix = digest.prefix(16).map { byte in
            String(format: "%02x", byte)
        }.joined()
        return "zai-\(prefix)"
    }

    private func persistWidgetState() {
        do {
            try AgentWidgetStateStore().save(currentWidgetState())
        } catch {
            logError("[Widget] Failed to save widget state: \(error.localizedDescription)")
        }

        #if canImport(WidgetKit)
        if #available(macOS 14.0, *) {
            WidgetCenter.shared.reloadTimelines(ofKind: AgentBarWidgetConstants.kind)
            WidgetCenter.shared.reloadAllTimelines()
        }
        #endif
    }

    private func currentWidgetState() -> AgentWidgetState {
        AgentWidgetState(
            generatedAt: Date(),
            providers: AgentProviderKind.allCases.flatMap { provider in
                accountStatuses(for: provider).map { status in
                    AgentWidgetProviderState(
                        id: status.id,
                        provider: provider,
                        accountLabel: status.displayLabel,
                        snapshot: status.snapshot,
                        errorMessage: status.errorMessage,
                        isAvailable: status.credentialsDetected
                    )
                }
            }
        )
    }

    enum AddConfiguredAccountDirectoryResult: Equatable {
        case added
        case emptyPath
        case duplicate
        case browserLoginRequired
        case credentialsFileMissing(String)
    }

    enum AddJunieAPITokenResult: Equatable {
        case added
        case emptyToken
        case duplicate
        case saveFailed(String)
    }

    enum AddZAICodingPlanCredentialResult: Equatable {
        case added
        case emptyToken
        case duplicate
        case invalidBaseURL
        case saveFailed(String)
    }

    private struct AccountRefreshResult {
        let account: ConfiguredAgentAccount
        let result: Result<AgentQuotaSnapshot, Error>
    }
}

private enum CodexReconnectError: LocalizedError {
    case accountMismatch
    case workspaceMismatch

    var errorDescription: String? {
        switch self {
        case .accountMismatch:
            return "The browser returned a different Codex account. Choose the same account and try again."
        case .workspaceMismatch:
            return "The browser returned a different Codex workspace. Choose the same workspace and try again."
        }
    }
}
