import AgentBarCore
import Foundation
import Testing

@Test
func widgetProviderStateDecodesLegacyCacheWithoutExplicitID() throws {
    let json = """
    {
      "provider": "codex",
      "snapshot": null,
      "errorMessage": null,
      "isAvailable": true,
      "accountCount": 2
    }
    """

    let decoder = JSONDecoder()
    let state = try decoder.decode(AgentWidgetProviderState.self, from: Data(json.utf8))

    #expect(state.id == "codex")
    #expect(state.provider == .codex)
    #expect(state.isAvailable)
}

@Test
func widgetStateKeepsDuplicateProviderOrderStable() {
    let state = AgentWidgetState(
        generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        providers: [
            AgentWidgetProviderState(
                id: "copilot-1",
                provider: .githubCopilot,
                snapshot: nil,
                errorMessage: nil,
                isAvailable: true
            ),
            AgentWidgetProviderState(
                id: "codex-2",
                provider: .codex,
                snapshot: nil,
                errorMessage: nil,
                isAvailable: true
            ),
            AgentWidgetProviderState(
                id: "codex-1",
                provider: .codex,
                snapshot: nil,
                errorMessage: nil,
                isAvailable: true
            ),
        ]
    )

    #expect(state.sortedProviders.map(\.id) == ["codex-2", "codex-1", "copilot-1"])
}
