import AgentBarCore
import Foundation
import Testing

/// Claude accounts are always AgentBar browser sign-ins, so decoding tests run
/// against an app-managed installation.
private func testClaudeService() -> ClaudeQuotaService {
    ClaudeQuotaService(installation: .appManaged(accountID: "claude-test-account"))
}

@Test
func decodesClaudeUsageWindowsFromOAuthResponse() throws {
    let payload = try sharedFixtureData("claude", "usage.json")
    let updatedAt = Date(timeIntervalSince1970: 1_744_160_000)

    let snapshot = try testClaudeService().decodeUsageSnapshot(
        from: payload,
        accountLabel: "dev@example.com",
        planType: "Claude Max",
        updatedAt: updatedAt
    )

    #expect(snapshot.provider == .claude)
    #expect(snapshot.accountLabel == "dev@example.com")
    #expect(snapshot.planType == "Claude Max")
    #expect(snapshot.sourceSummary == "Claude usage API")
    #expect(snapshot.updatedAt == updatedAt)

    // The disabled `seven_day_sonnet` window is dropped, and the rest keep the
    // session-first ordering the menu bar relies on.
    #expect(snapshot.metrics.map(\.id) == [
        "claude-five_hour",
        "claude-seven_day",
        "claude-seven_day_opus"
    ])
    #expect(snapshot.metrics.map(\.title) == [
        "Session (5h)",
        "Weekly (all models)",
        "Weekly (Opus)"
    ])
    #expect(snapshot.metrics[0].usedLabel == "43% used")
    #expect(snapshot.metrics[0].remainingLabel == "58% left")
    #expect(snapshot.metrics[0].resetsAt == Date(timeIntervalSince1970: 1_785_348_000))
    #expect(snapshot.metrics[2].usedPercent == 7.25)
}

@Test
func claudeUsageAcceptsWindowsAddedByAnthropicLater() throws {
    let payload = """
    {
      "five_hour": { "utilization": 10, "resets_at": "2026-07-29T18:00:00Z" },
      "thirty_day_haiku": { "utilization": 55 },
      "notes": "unrelated",
      "rate_limit_tier": 3
    }
    """

    let snapshot = try testClaudeService().decodeUsageSnapshot(
        from: Data(payload.utf8),
        accountLabel: "dev@example.com",
        planType: nil,
        updatedAt: Date()
    )

    // Unknown window keys are humanized and sorted after the known ones; scalar
    // fields that are not windows are ignored.
    #expect(snapshot.metrics.map(\.id) == ["claude-five_hour", "claude-thirty_day_haiku"])
    #expect(snapshot.metrics[1].title == "Thirty Day Haiku")
    #expect(snapshot.metrics[1].resetsAt == nil)
}

@Test
func claudeProfileDecodesNestedAccountAndPlan() throws {
    let payload = """
    {
      "account": {
        "uuid": "acc-123",
        "email_address": "dev@example.com",
        "display_name": "Dev"
      },
      "organization": { "name": "Example Inc" },
      "subscription_type": "claude_max"
    }
    """

    let profile = try ClaudeOAuthProfile.decode(from: Data(payload.utf8))

    #expect(profile.accountID == "acc-123")
    #expect(profile.preferredAccountLabel == "dev@example.com")
    #expect(profile.planLabel == "Claude Max")
}

@Test
func claudeAccountWithoutStoredSessionIsUnavailable() {
    // A directory that AgentBar does not own can never resolve an account id, so
    // it reports unavailable instead of falling back to a local auth file.
    let service = ClaudeQuotaService(
        installation: ClaudeCLIInstallation(
            configDirectory: URL(fileURLWithPath: "/tmp/agentbar-claude-not-managed"),
            appManagedAccountID: nil
        )
    )

    #expect(service.isAvailable == false)
}
