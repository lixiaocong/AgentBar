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

    #expect(model.menuBarDisplayMode == .clearer)
    #expect(model.refreshIntervalSeconds == 10)
    #expect(model.menuBarTitle == "Codex 34%  Copilot 77%  Gemini 100%")
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

    model.menuBarDisplayMode = .shorter
    #expect(model.menuBarTitle == "C34%  P77%  G100%")

    model.menuBarDisplayMode = .mixedMetrics
    #expect(model.menuBarTitle == "Codex 34%  Copilot 231 left  Gemini 100%")
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
            AgentProviderAvailability(codex: true, githubCopilot: false, gemini: true)
        },
        startImmediately: false
    )

    model.codexSnapshot = makeSnapshot(provider: .codex, usedPercent: 66, remainingLabel: "34% left")
    model.copilotSnapshot = makeSnapshot(provider: .githubCopilot, usedPercent: 23, remainingLabel: "231 left")
    model.geminiSnapshot = makeSnapshot(provider: .gemini, usedPercent: 0, remainingLabel: "100% left")

    #expect(model.availableProviders == [.codex, .gemini])
    #expect(model.menuBarTitle == "Codex 34%  Gemini 100%")
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
