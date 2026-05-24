import AgentBarCore
import Foundation
import Testing

@Test
func decodesClaudeSubscriptionAuthSnapshot() throws {
    let payload = try sharedFixtureData("claude", "subscription-auth.json")

    let updatedAt = Date(timeIntervalSince1970: 1_744_160_000)
    let snapshot = try ClaudeQuotaService().decodeSnapshot(
        from: payload,
        updatedAt: updatedAt
    )

    #expect(snapshot.provider == .claude)
    #expect(snapshot.accountLabel == "dev@example.com")
    #expect(snapshot.planType == "max")
    #expect(snapshot.sourceSummary == "Claude Code local auth")
    #expect(snapshot.metrics.isEmpty)
    #expect(snapshot.updatedAt == updatedAt)
}

@Test
func claudeFallsBackToConsoleAuthWhenNoAccountMetadataIsAvailable() throws {
    let payload = """
    {
      "customApiKeyResponses": {
        "default": {
          "apiKey": "sk-ant-test"
        }
      }
    }
    """

    let snapshot = try ClaudeQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.accountLabel == "Anthropic Console")
    #expect(snapshot.planType == "Anthropic Console")
    #expect(snapshot.metrics.isEmpty)
}
