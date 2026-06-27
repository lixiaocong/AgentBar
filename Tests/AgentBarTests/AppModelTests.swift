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
        sourceSummary: "Claude Code local auth",
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
func appModelAcceptsClaudeAuthJSONDirectories() throws {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: { .all },
        startImmediately: false
    )
    let directory = try temporaryClaudeAuthDirectory(named: #function)

    let result = model.addConfiguredAccountDirectory(
        path: directory.path,
        for: .claude
    )

    #expect(result == .added)
    #expect(model.configuredAccounts(for: .claude) == [ConfiguredAccountDirectory(path: directory.path)])
    #expect(model.accountStatuses(for: .claude).first?.credentialsDetected == true)
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
    if provider == .claude {
        let directory = try! temporaryClaudeAuthDirectory(named: accountID)
        model.addConfiguredAccountDirectory(directory, for: provider)
        return
    }

    model.addConfiguredAccountDirectory(
        AgentProviderAppAuthStore.accountDirectory(for: provider, accountID: accountID),
        for: provider
    )
}

private func temporaryClaudeAuthDirectory(named name: String) throws -> URL {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "AgentBarTests-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let auth = #"{"user":{"email":"claude@example.com"},"accessToken":"token","refreshToken":"refresh"}"#
    try auth.data(using: .utf8)!.write(to: directory.appending(path: "auth.json"))
    return directory
}

private func testDefaults(named name: String) -> UserDefaults {
    let suiteName = "AgentBarTests.\(name)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
