import Foundation
import Testing
@testable import AgentBar

@Test
func decodesGitHubCopilotUsagePayload() throws {
    let payload = """
    {
      "login": "monalisa",
      "copilot_plan": "pro",
      "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
      "quota_snapshots": {
        "premium_interactions": {
          "remaining": 150,
          "entitlement": 300,
          "percent_remaining": 50.0,
          "unlimited": false,
          "overage_count": 0
        }
      }
    }
    """

    let updatedAt = Date(timeIntervalSince1970: 1_744_160_000)
    let snapshot = try GitHubCopilotQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
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

