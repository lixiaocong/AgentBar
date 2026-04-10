import Foundation
import Testing
@testable import AgentBar

@Test
@MainActor
func appModelDefaultsToClearerMenuBarFormatAndTenSecondRefresh() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: { .all },
        startImmediately: false
    )

    model.codexSnapshot = makeSnapshot(provider: .codex, usedPercent: 66, remainingLabel: "34% left")
    model.copilotSnapshot = makeSnapshot(provider: .githubCopilot, usedPercent: 23, remainingLabel: "231 left")
    model.geminiSnapshot = makeSnapshot(provider: .gemini, usedPercent: 0, remainingLabel: "100% left")
    model.claudeSnapshot = makeSnapshot(provider: .claude, usedPercent: 12, remainingLabel: "88% left")

    #expect(model.menuBarDisplayMode == .clearer)
    #expect(model.refreshIntervalSeconds == 10)
    #expect(model.menuBarTitle == "Codex 34%  Copilot 77%  Gemini 100%  Claude 88%")
}

@Test
@MainActor
func appModelSupportsShorterAndMixedMetricFormats() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: { .all },
        startImmediately: false
    )

    model.codexSnapshot = makeSnapshot(provider: .codex, usedPercent: 66, remainingLabel: "34% left")
    model.copilotSnapshot = makeSnapshot(provider: .githubCopilot, usedPercent: 23, remainingLabel: "231 left")
    model.geminiSnapshot = makeSnapshot(provider: .gemini, usedPercent: 0, remainingLabel: "100% left")
    model.claudeSnapshot = makeSnapshot(provider: .claude, usedPercent: 12, remainingLabel: "88% left")

    model.menuBarDisplayMode = .shorter
    #expect(model.menuBarTitle == "C34%  P77%  G100%  Cl88%")

    model.menuBarDisplayMode = .mixedMetrics
    #expect(model.menuBarTitle == "Codex 34%  Copilot 231 left  Gemini 100%  Claude 88%")
}

@Test
@MainActor
func appModelLoadsStoredPreferences() {
    let defaults = testDefaults(named: #function)
    defaults.set(MenuBarDisplayMode.shorter.rawValue, forKey: "menuBarDisplayMode")
    defaults.set(45, forKey: "refreshIntervalSeconds")

    let model = AppModel(
        userDefaults: defaults,
        providerAvailabilityResolver: { .all },
        startImmediately: false
    )

    #expect(model.menuBarDisplayMode == .shorter)
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
    #expect(model.menuBarAccessibilityTitle == "Claude ready")
}

@Test
@MainActor
func appModelDefaultsConfiguredDirectoriesToStandardLocations() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    #expect(model.configuredAccounts(for: .codex) == [AgentProviderKind.codex.defaultAccountDirectory])
    #expect(model.configuredAccounts(for: .githubCopilot) == [AgentProviderKind.githubCopilot.defaultAccountDirectory])
    #expect(model.configuredAccounts(for: .gemini) == [AgentProviderKind.gemini.defaultAccountDirectory])
    #expect(model.configuredAccounts(for: .claude) == [AgentProviderKind.claude.defaultAccountDirectory])
}

@Test
@MainActor
func appModelPersistsAddedAndRemovedConfiguredDirectories() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    let customCodexDirectory = URL(fileURLWithPath: "/tmp/agent-bar-tests/codex-work")
    let defaultCodexDirectory = model.configuredAccounts(for: .codex).first!

    model.addConfiguredAccountDirectory(customCodexDirectory, for: .codex)
    #expect(
        model.configuredAccounts(for: .codex)
            == [
                AgentProviderKind.codex.defaultAccountDirectory,
                ConfiguredAccountDirectory(path: customCodexDirectory.path),
            ]
    )

    model.removeConfiguredAccount(
        ConfiguredAgentAccount(provider: .codex, directory: defaultCodexDirectory)
    )

    let reloaded = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    #expect(
        reloaded.configuredAccounts(for: .codex)
            == [ConfiguredAccountDirectory(path: customCodexDirectory.path)]
    )
}

@Test
@MainActor
func appModelAddsConfiguredDirectoriesFromTypedPaths() {
    let defaults = testDefaults(named: #function)
    let model = AppModel(
        userDefaults: defaults,
        startImmediately: false
    )

    let result = model.addConfiguredAccountDirectory(
        path: "/tmp/agent-bar-tests/.codex-work/",
        for: .codex
    )

    #expect(result == .added)
    #expect(
        model.configuredAccounts(for: .codex).last
            == ConfiguredAccountDirectory(path: "/tmp/agent-bar-tests/.codex-work")
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
    #expect(
        model.addConfiguredAccountDirectory(
            path: AgentProviderKind.codex.defaultAccountDirectoryDisplayPath,
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

private func testDefaults(named name: String) -> UserDefaults {
    let suiteName = "AgentBarTests.\(name)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}
