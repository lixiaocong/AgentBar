import AgentBarCore
import Foundation
import Testing
@testable import AgentBar

@Test
@MainActor
func appModelDefaultsToTwoMenuBarAccountsAndTenSecondRefresh() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: { .all },
        startImmediately: false
    )

    model.addConfiguredAccountDirectory(
        CodexAppAuthStore.accountDirectory(for: "account-format"),
        for: .codex
    )
    addAppManagedAccount(to: model, provider: .githubCopilot, accountID: "copilot-format")
    addAppManagedAccount(to: model, provider: .gemini, accountID: "gemini-format")
    addAppManagedAccount(to: model, provider: .claude, accountID: "claude-format")
    addAppManagedAccount(to: model, provider: .zai, accountID: "zai-format")
    addAppManagedAccount(to: model, provider: .junie, accountID: "junie-format")
    model.codexSnapshot = makeSnapshot(provider: .codex, usedPercent: 66, remainingLabel: "34% left")
    model.copilotSnapshot = makeSnapshot(provider: .githubCopilot, usedPercent: 23, remainingLabel: "231 left")
    model.geminiSnapshot = makeSnapshot(provider: .gemini, usedPercent: 0, remainingLabel: "100% left")
    model.claudeSnapshot = makeSnapshot(provider: .claude, usedPercent: 12, remainingLabel: "88% left")
    model.zaiSnapshot = makeSnapshot(provider: .zai, usedPercent: 19, remainingLabel: "81% left")
    model.junieSnapshot = makeSnapshot(provider: .junie, usedPercent: 5, remainingLabel: "95% left")

    #expect(model.menuBarMaxDisplayedAccounts == 2)
    #expect(model.refreshIntervalSeconds == 10)
    #expect(model.menuBarTitle == "Codex 34%  Copilot 77%  Gemini 100%  Claude 88%  Z.ai 81%  Junie 95%")
    #expect(
        model.statusIconQuotaBars == [
            MenuBarStatusImage.Bar(provider: .codex, label: "cx", remainingPercent: 34),
            MenuBarStatusImage.Bar(provider: .githubCopilot, label: "cp", remainingPercent: 77),
        ]
    )

    model.menuBarMaxDisplayedAccounts = 3
    #expect(
        model.statusIconQuotaBars == [
            MenuBarStatusImage.Bar(provider: .codex, label: "cx", remainingPercent: 34),
            MenuBarStatusImage.Bar(provider: .githubCopilot, label: "cp", remainingPercent: 77),
            MenuBarStatusImage.Bar(provider: .gemini, label: "gm", remainingPercent: 100),
        ]
    )
}

@Test
@MainActor
func appModelChoosesAccountsForMenuBarInsteadOfProviders() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: {
            AgentProviderAvailability(codex: true, githubCopilot: false, gemini: false, claude: false)
        },
        startImmediately: false
    )

    let firstDirectory = CodexAppAuthStore.accountDirectory(for: "codex-account-one")
    let secondDirectory = CodexAppAuthStore.accountDirectory(for: "codex-account-two")
    model.addConfiguredAccountDirectory(firstDirectory, for: .codex)
    model.addConfiguredAccountDirectory(secondDirectory, for: .codex)
    model.codexSnapshot = makeSnapshot(provider: .codex, usedPercent: 66, remainingLabel: "34% left")

    #expect(
        model.statusIconQuotaBars == [
            MenuBarStatusImage.Bar(provider: .codex, label: "cx1", remainingPercent: 34),
            MenuBarStatusImage.Bar(provider: .codex, label: "cx2", remainingPercent: nil),
        ]
    )

    let firstAccount = ConfiguredAgentAccount(
        provider: .codex,
        directory: ConfiguredAccountDirectory(path: firstDirectory.path)
    )
    let secondAccount = ConfiguredAgentAccount(
        provider: .codex,
        directory: ConfiguredAccountDirectory(path: secondDirectory.path)
    )

    model.setAccount(firstAccount, shownInMenuBar: false)
    #expect(!model.isAccountShownInMenuBar(firstAccount))
    #expect(model.isAccountShownInMenuBar(secondAccount))
    #expect(
        model.statusIconQuotaBars == [
            MenuBarStatusImage.Bar(provider: .codex, label: "cx", remainingPercent: nil),
        ]
    )
}

@Test
@MainActor
func appModelMenuBarSelectionPreservesProviderDisplayOrder() {
    let defaults = testDefaults(named: #function)
    defaults.set(["gemini", "codex", "githubCopilot"], forKey: "providerDisplayOrder")
    defaults.set([String](), forKey: "menuBarSelectedAccountIDs")
    let model = AppModel(userDefaults: defaults, startImmediately: false)
    model.menuBarMaxDisplayedAccounts = 3

    model.addConfiguredAccountDirectory(CodexAppAuthStore.accountDirectory(for: "order-codex"), for: .codex)
    addAppManagedAccount(to: model, provider: .githubCopilot, accountID: "order-copilot")
    addAppManagedAccount(to: model, provider: .gemini, accountID: "order-gemini")
    model.codexSnapshot = makeSnapshot(provider: .codex, usedPercent: 10, remainingLabel: "90% left")
    model.copilotSnapshot = makeSnapshot(provider: .githubCopilot, usedPercent: 20, remainingLabel: "80% left")
    model.geminiSnapshot = makeSnapshot(provider: .gemini, usedPercent: 30, remainingLabel: "70% left")
    model.providerAvailability = .all

    for provider in [AgentProviderKind.githubCopilot, .codex, .gemini] {
        let account = model.accountStatuses(for: provider)[0].account
        model.setAccount(account, shownInMenuBar: true)
    }

    let expected: [AgentProviderKind] = [.gemini, .codex, .githubCopilot]
    #expect(Array(model.providerOrder.prefix(3)) == expected)
    #expect(model.availableProviders.flatMap(model.visibleAccountStatuses(for:)).map(\.provider) == expected)
    #expect(model.statusIconQuotaBars.map(\.provider) == expected.map(Optional.some))
    #expect(model.statusIconQuotaBars.map(\.remainingPercent) == [70, 90, 80])

    let geminiAccount = model.accountStatuses(for: .gemini)[0].account
    model.setAccount(geminiAccount, shownInMenuBar: false)
    #expect(model.statusIconQuotaBars.map(\.provider) == [.codex, .githubCopilot])
    model.setAccount(geminiAccount, shownInMenuBar: true)
    #expect(model.statusIconQuotaBars.map(\.provider) == expected.map(Optional.some))

    let reloaded = AppModel(userDefaults: defaults, startImmediately: false)
    reloaded.providerAvailability = .all
    #expect(reloaded.statusIconQuotaBars.map(\.provider) == expected.map(Optional.some))
}

@Test
@MainActor
func appModelLoadsStoredPreferences() {
    let defaults = testDefaults(named: #function)
    defaults.set(3, forKey: "menuBarMaxDisplayedAgents")
    defaults.set(45, forKey: "refreshIntervalSeconds")

    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: { .all },
        startImmediately: false
    )

    #expect(model.menuBarMaxDisplayedAccounts == 3)
    #expect(model.refreshIntervalSeconds == 45)
}

@Test
@MainActor
func appModelUsesStoredProviderOrderForVisibleProviders() {
    let defaults = testDefaults(named: #function)
    let expectedOrder: [AgentProviderKind] = [
        .gemini,
        .codex,
        .githubCopilot,
        .claude,
        .zai,
        .junie,
    ]
    defaults.set(expectedOrder.map(\.rawValue), forKey: "providerDisplayOrder")
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: { .all },
        startImmediately: false
    )
    model.providerAvailability = .all

    #expect(model.providerOrder == expectedOrder)
    #expect(model.availableProviders == expectedOrder)

    let reloaded = AppModel(userDefaults: defaults, startImmediately: false)
    #expect(reloaded.providerOrder == expectedOrder)
}

@Test
@MainActor
func appModelNormalizesStoredProviderOrder() {
    let defaults = testDefaults(named: #function)
    defaults.set(
        ["junie", "unknown-provider", "codex", "junie"],
        forKey: "providerDisplayOrder"
    )

    let model = AppModel(userDefaults: defaults, startImmediately: false)

    #expect(model.providerOrder == [
        .junie,
        .codex,
        .githubCopilot,
        .gemini,
        .claude,
        .zai,
    ])
}

@Test
@MainActor
func appModelPersistsAccountOrderWithinProvider() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(userDefaults: defaults, startImmediately: false)
    let firstDirectory = CodexAppAuthStore.accountDirectory(for: "ordered-account-one")
    let secondDirectory = CodexAppAuthStore.accountDirectory(for: "ordered-account-two")
    let thirdDirectory = CodexAppAuthStore.accountDirectory(for: "ordered-account-three")

    model.addConfiguredAccountDirectory(firstDirectory, for: .codex)
    model.addConfiguredAccountDirectory(secondDirectory, for: .codex)
    model.addConfiguredAccountDirectory(thirdDirectory, for: .codex)

    let otherProviderAccounts = model.configuredAccounts(for: .gemini)
    model.moveAccounts(for: .codex, fromOffsets: IndexSet(integer: 0), toOffset: 3)

    let expectedOrder = [
        ConfiguredAccountDirectory(path: secondDirectory.path),
        ConfiguredAccountDirectory(path: thirdDirectory.path),
        ConfiguredAccountDirectory(path: firstDirectory.path),
    ]
    #expect(model.configuredAccounts(for: .codex) == expectedOrder)
    #expect(model.accountStatuses(for: .codex).map(\.account.directory) == expectedOrder)

    let reloaded = AppModel(userDefaults: defaults, startImmediately: false)
    #expect(reloaded.configuredAccounts(for: .codex) == expectedOrder)

    model.moveAccounts(for: .codex, fromOffsets: IndexSet(integer: 2), toOffset: 0)
    #expect(model.configuredAccounts(for: .codex).map(\.path) == [
        firstDirectory.path, secondDirectory.path, thirdDirectory.path,
    ])
    #expect(model.configuredAccounts(for: .gemini) == otherProviderAccounts)
}

@Test
@MainActor
func appModelHidesUnavailableProvidersFromMenuBarSummary() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: {
            AgentProviderAvailability(codex: true, githubCopilot: false, gemini: true, claude: false)
        },
        startImmediately: false
    )

    model.addConfiguredAccountDirectory(
        CodexAppAuthStore.accountDirectory(for: "account-visible"),
        for: .codex
    )
    addAppManagedAccount(to: model, provider: .gemini, accountID: "gemini-visible")
    model.codexSnapshot = makeSnapshot(provider: .codex, usedPercent: 66, remainingLabel: "34% left")
    model.copilotSnapshot = makeSnapshot(provider: .githubCopilot, usedPercent: 23, remainingLabel: "231 left")
    model.geminiSnapshot = makeSnapshot(provider: .gemini, usedPercent: 0, remainingLabel: "100% left")

    #expect(model.availableProviders == [.codex, .gemini])
    #expect(model.menuBarTitle == "Codex 34%  Gemini 100%")
}

@Test
@MainActor
func appModelIgnoresGPTReserveQuotaInOverallStatus() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: {
            AgentProviderAvailability(codex: true, githubCopilot: false, gemini: false, claude: false)
        },
        startImmediately: false
    )
    model.addConfiguredAccountDirectory(
        CodexAppAuthStore.accountDirectory(for: "account-with-reserve"),
        for: .codex
    )
    model.codexSnapshot = AgentQuotaSnapshot(
        provider: .codex,
        accountLabel: "test@example.com",
        planType: "Pro",
        modelName: nil,
        sourceSummary: "Test",
        metrics: [
            AgentQuotaMetric(
                id: "window-10080",
                title: "7 day window",
                usedPercent: 31,
                usedLabel: "31% used",
                remainingLabel: "69% left",
                resetsAt: nil
            ),
            AgentQuotaMetric(
                id: "additional-1-window-10080",
                title: "gpt-reserve 7 day window",
                usedPercent: 99,
                usedLabel: "99% used",
                remainingLabel: "1% left",
                resetsAt: nil
            ),
        ],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(model.highlightMetric?.id == "window-10080")
    #expect(model.menuBarTitle == "Codex 69%")
    #expect(model.statusIconQuotaBars == [
        MenuBarStatusImage.Bar(
            provider: .codex,
            label: "cx",
            remainingPercent: 69,
            windowDuration: 7 * 24 * 60 * 60
        ),
    ])
}

@Test
@MainActor
func appModelShowsReadyForProvidersWithoutQuotaMetrics() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: {
            AgentProviderAvailability(codex: false, githubCopilot: false, gemini: false, claude: true)
        },
        startImmediately: false
    )

    addAppManagedAccount(to: model, provider: .claude, accountID: "claude-ready")
    model.claudeSnapshot = AgentQuotaSnapshot(
        provider: .claude,
        accountLabel: "dev@example.com",
        planType: "Claude subscription",
        modelName: nil,
        sourceSummary: "Claude usage API",
        metrics: [],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    #expect(model.menuBarTitle == "Claude Ready")
    #expect(model.menuBarAccessibilityTitle == "dev@example.com Claude ready")
}

@Test
@MainActor
func appModelDefaultsConfiguredDirectoriesToStandardLocations() {
    let defaults = testDefaults(named: #function)
    defaults.set([], forKey: "configuredAccountDirectories.claude")
    let model = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    #expect(model.configuredAccounts(for: .codex) == [])
    #expect(model.configuredAccounts(for: .githubCopilot) == [])
    #expect(model.configuredAccounts(for: .gemini) == [])
    #expect(model.configuredAccounts(for: .claude) == [])
    #expect(model.configuredAccounts(for: .zai) == [])
    #expect(model.configuredAccounts(for: .junie) == [])
}

@Test
@MainActor
func appModelRejectsClaudeDirectoriesItDoesNotOwn() throws {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: { .all },
        startImmediately: false
    )

    // Claude is browser sign-in only, so pointing at a Claude Code config
    // directory is rejected the same way as the other OAuth providers.
    let result = model.addConfiguredAccountDirectory(
        path: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path,
        for: .claude
    )

    #expect(result == .browserLoginRequired)
    #expect(model.configuredAccounts(for: .claude) == [])
}

@Test
@MainActor
func appModelPersistsAddedAndRemovedConfiguredDirectories() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    let firstCodexDirectory = CodexAppAuthStore.accountDirectory(for: "account-one")
    let secondCodexDirectory = CodexAppAuthStore.accountDirectory(for: "account-two")

    model.addConfiguredAccountDirectory(firstCodexDirectory, for: .codex)
    model.addConfiguredAccountDirectory(secondCodexDirectory, for: .codex)
    #expect(
        model.configuredAccounts(for: .codex)
            == [
                ConfiguredAccountDirectory(path: firstCodexDirectory.path),
                ConfiguredAccountDirectory(path: secondCodexDirectory.path),
            ]
    )

    model.removeConfiguredAccount(
        ConfiguredAgentAccount(provider: .codex, directory: ConfiguredAccountDirectory(path: firstCodexDirectory.path))
    )

    let reloaded = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    #expect(
        reloaded.configuredAccounts(for: .codex)
            == [ConfiguredAccountDirectory(path: secondCodexDirectory.path)]
    )
}

@Test
@MainActor
func appModelRemovingAccountsKeepsCredentialsAndManagedDirectories() throws {
    let defaults = testDefaults(named: #function)
    let uniqueSuffix = UUID().uuidString
    let codexAccountID = "remove-codex-\(uniqueSuffix)"
    let copilotAccountID = "remove-copilot-\(uniqueSuffix)"
    let codexSession = CodexStoredAuthSession(
        idToken: "codex-id-token",
        accessToken: "codex-access-token",
        refreshToken: "codex-refresh-token",
        accountID: codexAccountID,
        localAccountID: codexAccountID,
        lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let copilotSession = AgentProviderStoredAuthSession(
        provider: .githubCopilot,
        accountID: copilotAccountID,
        accountLabel: "copilot@example.com",
        accessToken: "copilot-access-token",
        lastRefresh: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let codexDirectory = CodexAppAuthStore.accountDirectory(for: codexAccountID)
    let copilotDirectory = AgentProviderAppAuthStore.accountDirectory(
        for: .githubCopilot,
        accountID: copilotAccountID
    )
    defer {
        _ = try? CodexAppAuthStore.deleteSession(accountID: codexAccountID)
        try? CodexAppAuthStore.deleteAccountDirectory(accountID: codexAccountID)
        _ = try? AgentProviderAppAuthStore.deleteSession(
            provider: .githubCopilot,
            accountID: copilotAccountID
        )
        try? AgentProviderAppAuthStore.deleteAccountDirectory(
            provider: .githubCopilot,
            accountID: copilotAccountID
        )
    }

    try CodexAppAuthStore.save(session: codexSession)
    try CodexAppAuthStore.ensureAccountDirectoryExists(for: codexAccountID)
    try AgentProviderAppAuthStore.save(session: copilotSession)
    try AgentProviderAppAuthStore.ensureAccountDirectoryExists(
        for: .githubCopilot,
        accountID: copilotAccountID
    )

    let model = AppModel(userDefaults: defaults, startImmediately: false)
    model.addConfiguredAccountDirectory(codexDirectory, for: .codex)
    model.addConfiguredAccountDirectory(copilotDirectory, for: .githubCopilot)

    model.removeConfiguredAccount(
        ConfiguredAgentAccount(
            provider: .codex,
            directory: ConfiguredAccountDirectory(path: codexDirectory.path)
        )
    )
    model.removeConfiguredAccount(
        ConfiguredAgentAccount(
            provider: .githubCopilot,
            directory: ConfiguredAccountDirectory(path: copilotDirectory.path)
        )
    )

    #expect(model.configuredAccounts(for: .codex).isEmpty)
    #expect(model.configuredAccounts(for: .githubCopilot).isEmpty)
    #expect(try CodexAppAuthStore.loadSession(accountID: codexAccountID) == codexSession)
    #expect(
        try AgentProviderAppAuthStore.loadSession(
            provider: .githubCopilot,
            accountID: copilotAccountID
        ) == copilotSession
    )
    #expect(FileManager.default.fileExists(atPath: codexDirectory.path))
    #expect(FileManager.default.fileExists(atPath: copilotDirectory.path))
}

@Test
@MainActor
func appModelAddsAppManagedCodexDirectoriesFromTypedPaths() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )
    let directory = CodexAppAuthStore.accountDirectory(for: "account-typed")

    let result = model.addConfiguredAccountDirectory(
        path: directory.path,
        for: .codex
    )

    #expect(result == .added)
    #expect(
        model.configuredAccounts(for: .codex).last
            == ConfiguredAccountDirectory(path: directory.path)
    )
}

@Test
@MainActor
func appModelRejectsLocalAgentDirectories() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    #expect(
        model.addConfiguredAccountDirectory(
            path: "/tmp/agent-bar-tests/.codex-work/",
            for: .codex
        ) == .browserLoginRequired
    )
    #expect(
        model.addConfiguredAccountDirectory(
            path: "/tmp/agent-bar-tests/.config/github-copilot/",
            for: .githubCopilot
        ) == .browserLoginRequired
    )
    #expect(
        model.addConfiguredAccountDirectory(
            path: "/tmp/agent-bar-tests/.gemini/",
            for: .gemini
        ) == .browserLoginRequired
    )
    #expect(
        model.addConfiguredAccountDirectory(
            path: "/tmp/agent-bar-tests/.junie/",
            for: .junie
        ) == .browserLoginRequired
    )
    #expect(
        model.addConfiguredAccountDirectory(
            path: "/tmp/agent-bar-tests/.zai/",
            for: .zai
        ) == .browserLoginRequired
    )
}

@Test
@MainActor
func appModelRejectsEmptyAndDuplicateTypedPaths() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    #expect(model.addConfiguredAccountDirectory(path: "   ", for: .codex) == .emptyPath)
    let directory = CodexAppAuthStore.accountDirectory(for: "account-duplicate")
    #expect(
        model.addConfiguredAccountDirectory(
            path: directory.path,
            for: .codex
        ) == .added
    )
    #expect(
        model.addConfiguredAccountDirectory(
            path: directory.path,
            for: .codex
        ) == .duplicate
    )
}

@Test
@MainActor
func appModelCanCancelAbandonedBrowserLogin() async {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        codexBrowserLoginAction: { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        },
        startImmediately: false
    )

    model.signInWithBrowser(for: .codex)
    #expect(model.isLoginInProgress(for: .codex))

    model.cancelBrowserSignIn(for: .codex)
    await Task.yield()

    #expect(!model.isLoginInProgress(for: .codex))
    #expect(model.loginError(for: .codex) == nil)
    #expect(model.loginMessage(for: .codex) == "Sign-in cancelled.")
}

@Test
@MainActor
func appModelTimesOutAbandonedBrowserLogin() async {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        codexBrowserLoginAction: { _, _ in
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        },
        browserLoginTimeout: .milliseconds(20),
        startImmediately: false
    )

    model.signInWithBrowser(for: .codex)
    #expect(model.isLoginInProgress(for: .codex))
    for _ in 0 ..< 100 where model.isLoginInProgress(for: .codex) {
        try? await Task.sleep(for: .milliseconds(10))
    }

    #expect(!model.isLoginInProgress(for: .codex))
    #expect(model.loginError(for: .codex) == "Codex sign-in timed out. Try again.")
}

@Test
@MainActor
func appModelClearsBrowserLoginProgressAfterFailure() async {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerBrowserLoginAction: { _, _, _, _ in
            throw BrowserLoginTestError.failed
        },
        startImmediately: false
    )

    model.signInWithBrowser(for: .githubCopilot)
    for _ in 0 ..< 10 where model.isLoginInProgress(for: .githubCopilot) {
        await Task.yield()
    }

    #expect(!model.isLoginInProgress(for: .githubCopilot))
    #expect(model.loginError(for: .githubCopilot) == "Test sign-in failed.")
}

@Test
@MainActor
func appModelCanCopySignInURLWithoutOpeningDefaultBrowser() async {
    let defaults = testDefaults(named: #function)
    let authorizationURL = URL(string: "https://example.com/oauth/authorize?state=test")!
    let copySpy = BrowserLoginURLCopySpy()
    let model = AppModel(
        userDefaults: defaults,
        codexBrowserLoginAction: { openBrowser, progress in
            #expect(!openBrowser)
            progress.report("Enter the displayed code if prompted.")
            progress.reportAuthorizationURL(authorizationURL)
            try await Task.sleep(for: .seconds(30))
            throw CancellationError()
        },
        browserLoginURLCopyAction: { url in
            copySpy.urls.append(url)
            return true
        },
        startImmediately: false
    )

    model.copyBrowserSignInURL(for: .codex)
    for _ in 0 ..< 20 where copySpy.urls.isEmpty {
        await Task.yield()
    }

    #expect(copySpy.urls == [authorizationURL])
    #expect(model.isLoginInProgress(for: .codex))
    #expect(model.canCopyBrowserSignInURL(for: .codex))
    let expectedMessage = "Enter the displayed code if prompted.\nSign-in URL copied. Complete sign-in in your preferred browser."
    #expect(model.loginMessage(for: .codex) == expectedMessage)

    model.copyBrowserSignInURL(for: .codex)
    #expect(copySpy.urls == [authorizationURL, authorizationURL])
    #expect(model.loginMessage(for: .codex) == expectedMessage)

    model.cancelBrowserSignIn(for: .codex)
}

@MainActor
private final class BrowserLoginURLCopySpy {
    var urls: [URL] = []
}

private func makeSnapshot(
    provider: AgentProviderKind,
    usedPercent: Double,
    remainingLabel: String
) -> AgentQuotaSnapshot {
    AgentQuotaSnapshot(
        provider: provider,
        accountLabel: "test@example.com",
        planType: nil,
        modelName: nil,
        sourceSummary: "Test",
        metrics: [
            AgentQuotaMetric(
                id: "\(provider.rawValue)-metric",
                title: "Primary",
                usedPercent: usedPercent,
                usedLabel: "\(Int(usedPercent.rounded()))% used",
                remainingLabel: remainingLabel,
                resetsAt: nil
            )
        ],
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@MainActor
private func addAppManagedAccount(
    to model: AppModel,
    provider: AgentProviderKind,
    accountID: String
) {
    model.addConfiguredAccountDirectory(
        AgentProviderAppAuthStore.accountDirectory(for: provider, accountID: accountID),
        for: provider
    )
}

private func testDefaults(named name: String) -> UserDefaults {
    let suiteName = "AgentBarTests.\(name)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private enum BrowserLoginTestError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test sign-in failed."
    }
}
