import AgentBarCore
import Foundation
import Testing

@Test
func decodesZAIQuotaLimitPayload() throws {
    let payload = try sharedFixtureData("zai", "quota-limit.json")
    let updatedAt = Date(timeIntervalSince1970: 1_776_240_000)

    let snapshot = try ZAIQuotaService().decodeSnapshot(
        from: payload,
        accountLabelFallback: "Z.ai Coding Plan",
        updatedAt: updatedAt
    )

    #expect(snapshot.provider == .zai)
    #expect(snapshot.accountLabel == "Z.ai Coding Plan")
    #expect(snapshot.planType == "Pro")
    #expect(snapshot.sourceSummary == "Z.ai Coding Plan API")
    #expect(snapshot.updatedAt == updatedAt)
    #expect(snapshot.metrics.count == 3)

    let mcpMetric = snapshot.metrics[0]
    #expect(mcpMetric.title == "MCP usage 1 month window")
    #expect(mcpMetric.usedPercent == 8)
    #expect(mcpMetric.usedLabel == "82/1000 used")
    #expect(mcpMetric.remainingLabel == "918/1000 left")
    #expect(mcpMetric.resetsAt == Date(timeIntervalSince1970: 1_781_661_646.979))

    let fiveHourMetric = snapshot.metrics[1]
    #expect(fiveHourMetric.title == "Token usage 5 hour window")
    #expect(fiveHourMetric.usedPercent == 37)
    #expect(fiveHourMetric.usedLabel == "37% used")
    #expect(fiveHourMetric.remainingLabel == "63% left")
    #expect(fiveHourMetric.resetsAt == Date(timeIntervalSince1970: 1_780_602_733.798))

    let weeklyMetric = snapshot.metrics[2]
    #expect(weeklyMetric.title == "Token usage 7 day window")
    #expect(weeklyMetric.usedPercent == 25)
    #expect(weeklyMetric.remainingLabel == "75% left")
    #expect(weeklyMetric.resetsAt == Date(timeIntervalSince1970: 1_780_970_446.997))
}

@Test
func zaiInfersPercentFromUsageAndRemaining() throws {
    let payload = """
    {
      "data": {
        "planName": "Max",
        "limits": [
          {
            "type": "TOKENS_LIMIT",
            "unit": 3,
            "number": 5,
            "usage": "800000000",
            "currentValue": "200000000",
            "remaining": "600000000",
            "nextResetTime": 1780602733798
          }
        ]
      }
    }
    """

    let snapshot = try ZAIQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        updatedAt: Date()
    )

    #expect(snapshot.planType == "Max")
    let metric = try #require(snapshot.metrics.first)
    #expect(metric.usedPercent == 25)
    #expect(metric.usedLabel == "200M/800M used")
    #expect(metric.remainingLabel == "600M/800M left")
}

@Test
func zaiNormalizesInternationalMonitorHost() throws {
    #expect(
        try ZAIQuotaService.normalizedMonitorBaseURL(
            from: "https://api.z.ai/api/anthropic"
        ).absoluteString == "https://api.z.ai"
    )
}

@Test
func zaiRejectsDomesticMonitorHosts() {
    do {
        _ = try ZAIQuotaService.normalizedMonitorBaseURL(
            from: "open.bigmodel.cn/api/anthropic"
        )
        #expect(Bool(false))
    } catch {
        #expect(Bool(true))
    }
}

@Test
func zaiAppManagedAccountDirectoryRoundTripsAccountID() {
    let directory = AgentProviderAppAuthStore.accountDirectory(
        for: .zai,
        accountID: "zai/account+symbols"
    )

    #expect(
        AgentProviderAppAuthStore.accountID(
            fromAccountDirectory: directory,
            provider: .zai
        ) == "zai/account+symbols"
    )
    #expect(
        AgentProviderAppAuthStore.isAppManagedAccountDirectory(
            ConfiguredAccountDirectory(path: directory.path),
            provider: .zai
        )
    )
}
