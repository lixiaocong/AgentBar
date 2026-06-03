import AgentBarCore
import Foundation
import Testing

@Test
func decodesGitHubCopilotUsagePayload() throws {
    let payload = try sharedFixtureData("copilot", "premium.json")

    let updatedAt = Date(timeIntervalSince1970: 1_744_160_000)
    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: payload,
        updatedAt: updatedAt
    )

    #expect(snapshot.provider == .githubCopilot)
    #expect(snapshot.accountLabel == "@monalisa")
    #expect(snapshot.planType == "pro")
    #expect(snapshot.sourceSummary == "GitHub Copilot API")
    #expect(snapshot.metrics.count == 1)
    #expect(snapshot.metrics.first?.title == "Premium requests / month")
    #expect(snapshot.metrics.first?.usedPercent == 50)
    #expect(snapshot.metrics.first?.usedLabel == "150/300 used")
    #expect(snapshot.metrics.first?.remainingLabel == "150 left")
}

@Test
func copilotShowsUnlimitedWhenNoQuotaLimit() throws {
    let payload = """
    {
      "login": "monalisa",
      "copilot_plan": "business",
      "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
      "quota_snapshots": {
        "premium_interactions": {
          "remaining": 0,
          "entitlement": 0,
          "percent_remaining": 100.0,
          "unlimited": true,
          "overage_count": 0
        }
      }
    }
    """

    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.metrics.first?.usedPercent == 0)
    #expect(snapshot.metrics.first?.usedLabel == "Unlimited")
    #expect(snapshot.metrics.first?.remainingLabel == "Unlimited")
}

@Test
func copilotFreePlanUsesPositiveQuotaWhenUnlimitedFlagIsTrue() throws {
    let payload = """
    {
      "login": "free-user",
      "copilot_plan": "free",
      "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
      "quota_snapshots": {
        "premium_interactions": {
          "remaining": 37,
          "entitlement": 50,
          "percent_remaining": 74.0,
          "unlimited": true,
          "overage_count": 0
        }
      }
    }
    """

    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.planType == "free")
    #expect(snapshot.metrics.first?.usedPercent == 26)
    #expect(snapshot.metrics.first?.usedLabel == "13/50 used")
    #expect(snapshot.metrics.first?.remainingLabel == "37 left")
}

@Test
func copilotIndividualPlanUsesChatAndCompletionQuotas() throws {
    let payload = """
    {
      "login": "free-user",
      "copilot_plan": "individual",
      "quota_reset_date_utc": "2026-06-30T16:00:00.000Z",
      "quota_snapshots": {
        "chat": {
          "remaining": 189,
          "quota_remaining": 189.3,
          "entitlement": 200,
          "percent_remaining": 94.6,
          "unlimited": false
        },
        "completions": {
          "remaining": 2000,
          "quota_remaining": 2000.0,
          "entitlement": 2000,
          "percent_remaining": 100.0,
          "unlimited": false
        },
        "premium_interactions": {
          "remaining": 0,
          "quota_remaining": 0.0,
          "entitlement": 0,
          "percent_remaining": 0.0,
          "unlimited": false
        }
      }
    }
    """

    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.planType == "individual")
    #expect(snapshot.metrics.count == 2)
    #expect(snapshot.metrics[0].id == "github-copilot-chat")
    #expect(snapshot.metrics[0].usedPercent == 5.5)
    #expect(snapshot.metrics[0].usedLabel == "11/200 used")
    #expect(snapshot.metrics[0].remainingLabel == "189 left")
    #expect(snapshot.metrics[1].id == "github-copilot-completions")
    #expect(snapshot.metrics[1].usedPercent == 0)
    #expect(snapshot.metrics[1].usedLabel == "0/2000 used")
    #expect(snapshot.highlightMetric?.id == "github-copilot-chat")
}

@Test
func copilotDisplaysDynamicQuotaSnapshotBuckets() throws {
    let payload = """
    {
      "login": "dynamic-user",
      "copilot_plan": "individual",
      "quota_reset_date_utc": "2026-06-30T16:00:00.000Z",
      "quota_snapshots": {
        "chat": {
          "remaining": 189,
          "entitlement": 200,
          "percent_remaining": 94.5,
          "unlimited": false
        },
        "agent_sessions": {
          "remaining": 12,
          "entitlement": 20,
          "percent_remaining": 60,
          "unlimited": false
        },
        "premium_interactions": {
          "remaining": 0,
          "entitlement": 0,
          "percent_remaining": 0,
          "unlimited": false
        }
      }
    }
    """

    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.metrics.map(\.id) == [
        "github-copilot-chat",
        "github-copilot-agent-sessions"
    ])
    #expect(snapshot.metrics.map(\.title) == [
        "Chat messages / month",
        "Agent Sessions / month"
    ])
    #expect(snapshot.metrics[1].usedPercent == 40)
    #expect(snapshot.metrics[1].usedLabel == "8/20 used")
    #expect(snapshot.metrics[1].remainingLabel == "12 left")
}

@Test
func copilotPrefersDisplayNameOverLoginSlug() throws {
    let payload = """
    {
      "login": "xiaocong-li-nb",
      "name": "Xiaocong Li",
      "copilot_plan": "pro",
      "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
      "quota_snapshots": {
        "premium_interactions": {
          "remaining": 20,
          "entitlement": 100,
          "percent_remaining": 20.0,
          "unlimited": false,
          "overage_count": 0
        }
      }
    }
    """

    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.accountLabel == "Xiaocong Li")
}

@Test
func copilotPrefersEmailOverLoginSlug() throws {
    let payload = """
    {
      "login": "xiaocong-li-nb",
      "email": "xiaocong.li@newsbreak.com",
      "name": "Xiaocong Li",
      "copilot_plan": "pro",
      "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
      "quota_snapshots": {
        "premium_interactions": {
          "remaining": 20,
          "entitlement": 100,
          "percent_remaining": 20.0,
          "unlimited": false,
          "overage_count": 0
        }
      }
    }
    """

    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.accountLabel == "xiaocong.li@newsbreak.com")
}

@Test
func copilotAppManagedAccountDirectoryRoundTripsAccountID() {
    let directory = AgentProviderAppAuthStore.accountDirectory(
        for: .githubCopilot,
        accountID: "github/user+symbols"
    )

    #expect(
        AgentProviderAppAuthStore.accountID(
            fromAccountDirectory: directory,
            provider: .githubCopilot
        ) == "github/user+symbols"
    )
    #expect(
        AgentProviderAppAuthStore.isAppManagedAccountDirectory(
            ConfiguredAccountDirectory(path: directory.path),
            provider: .githubCopilot
        )
    )
}

@Test
func copilotUsageWhenFullyConsumed() throws {
    let payload = """
    {
      "login": "alice",
      "copilot_plan": "free",
      "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
      "quota_snapshots": {
        "premium_interactions": {
          "remaining": 0,
          "entitlement": 50,
          "percent_remaining": 0.0,
          "unlimited": false,
          "overage_count": 2
        }
      }
    }
    """

    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.metrics.first?.usedPercent == 100)
    #expect(snapshot.metrics.first?.usedLabel == "50/50 used")
    #expect(snapshot.metrics.first?.remainingLabel == "0 left")
}
