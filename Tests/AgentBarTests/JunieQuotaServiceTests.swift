import AgentBarCore
import Foundation
import Testing

@Test
func decodesJunieAuthInfoPayload() throws {
    let payload = """
    {
      "username": "dev@example.com",
      "active": true,
      "balanceLeft": 120.5,
      "licenseType": "junie_pro",
      "balanceUnit": "credits",
      "authType": "api_key"
    }
    """
    let quotaPayload = """
    {
      "current": {
        "current": { "amount": "120.50" },
        "maximum": { "amount": "200.00" }
      }
    }
    """

    let updatedAt = Date(timeIntervalSince1970: 1_776_240_000)
    let snapshot = try JunieQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        quotaData: Data(quotaPayload.utf8),
        accountLabelFallback: "Fallback Junie",
        updatedAt: updatedAt
    )

    #expect(snapshot.provider == .junie)
    #expect(snapshot.accountLabel == "dev@example.com")
    #expect(snapshot.planType == "Pro")
    #expect(snapshot.sourceSummary == "Active · $120.50 / $200 left")
    let metric = try #require(snapshot.metrics.first)
    #expect(metric.title == "Subscription quota")
    #expect(abs(metric.usedPercent - 39.75) < 0.001)
    #expect(metric.usedLabel == "$79.50 used")
    #expect(metric.remainingLabel == "$120.50 / $200 left")
    #expect(snapshot.updatedAt == updatedAt)
}

@Test
func junieFallsBackWhenAccountMetadataIsSparse() throws {
    let payload = """
    {
      "active": false,
      "balanceLeft": 0
    }
    """

    let snapshot = try JunieQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabelFallback: "Junie API Key",
        updatedAt: Date()
    )

    #expect(snapshot.accountLabel == "Junie API Key")
    #expect(snapshot.planType == nil)
    #expect(snapshot.sourceSummary == "Inactive · 0 left")
}

@Test
func decodesJunieDirectQuotaPayload() throws {
    let payload = """
    {
      "username": "dev@example.com",
      "active": true
    }
    """
    let quotaPayload = """
    {
      "current": 10,
      "maximum": 50
    }
    """

    let snapshot = try JunieQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        quotaData: Data(quotaPayload.utf8),
        accountLabelFallback: "Fallback Junie",
        updatedAt: Date()
    )

    #expect(snapshot.planType == nil)
    #expect(snapshot.sourceSummary == "Active · $10 / $50 left")
    let metric = try #require(snapshot.metrics.first)
    #expect(metric.usedPercent == 80)
    #expect(metric.usedLabel == "$40 used")
    #expect(metric.remainingLabel == "$10 / $50 left")
}

@Test
func normalizesJunieApiKeyBalanceAndInfersSubscriptionQuota() throws {
    let payload = """
    {
      "username": "dev@example.com",
      "active": true,
      "balanceLeft": 647454,
      "licenseType": "junie",
      "balanceUnit": "credits",
      "authType": "api_key"
    }
    """

    let snapshot = try JunieQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabelFallback: "Fallback Junie",
        updatedAt: Date()
    )

    #expect(snapshot.planType == "Junie")
    #expect(snapshot.sourceSummary == "Active · $6.47 / $10 left")
    let metric = try #require(snapshot.metrics.first)
    #expect(metric.title == "Subscription quota")
    #expect(abs(metric.usedPercent - 35.2546) < 0.001)
    #expect(metric.usedLabel == "$3.53 used")
    #expect(metric.remainingLabel == "$6.47 / $10 left")
}

@Test
func infersJunieApiKeySubscriptionQuotaWithoutLicenseType() throws {
    let payload = """
    {
      "username": "dev@example.com",
      "active": true,
      "balanceLeft": 647454,
      "balanceUnit": "credits",
      "authType": "api_key"
    }
    """

    let snapshot = try JunieQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        accountLabelFallback: "Fallback Junie",
        updatedAt: Date()
    )

    #expect(snapshot.planType == nil)
    #expect(snapshot.sourceSummary == "Active · $6.47 / $10 left")
    let metric = try #require(snapshot.metrics.first)
    #expect(abs(metric.usedPercent - 35.2546) < 0.001)
    #expect(metric.usedLabel == "$3.53 used")
    #expect(metric.remainingLabel == "$6.47 / $10 left")
}

@Test
func usesJetBrainsAIAssistantQuotaCacheForAIPMonthlyCredits() throws {
    let payload = """
    {
      "active": true,
      "balanceLeft": 640078,
      "balanceUnit": "CREDITS",
      "licenseType": "AIP",
      "authType": ""
    }
    """
    let cacheXML = """
    <application>
      <component name="AIAssistantQuotaManager2">
        <option name="nextRefill" value="{&quot;type&quot;:&quot;Known&quot;,&quot;next&quot;:&quot;2026-06-16T05:53:53.825Z&quot;,&quot;tariff&quot;:{&quot;amount&quot;:&quot;1000000&quot;,&quot;duration&quot;:&quot;PT720H&quot;}}" />
        <option name="quotaInfo" value="{&quot;type&quot;:&quot;Available&quot;,&quot;current&quot;:&quot;352545.82&quot;,&quot;maximum&quot;:&quot;1000000&quot;,&quot;tariffQuota&quot;:{&quot;current&quot;:&quot;352545.82&quot;,&quot;maximum&quot;:&quot;1000000&quot;,&quot;available&quot;:&quot;647454.18&quot;},&quot;topUpQuota&quot;:{&quot;current&quot;:&quot;0&quot;,&quot;maximum&quot;:&quot;0&quot;,&quot;available&quot;:&quot;0&quot;}}" />
      </component>
    </application>
    """
    let cacheURL = FileManager.default.temporaryDirectory
        .appending(path: "AgentBar-JunieQuota-\(UUID().uuidString).xml")
    try cacheXML.write(to: cacheURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: cacheURL) }

    let snapshot = try JunieQuotaService(quotaCacheFiles: [cacheURL]).decodeSnapshot(
        from: Data(payload.utf8),
        accountLabelFallback: "Junie API Key",
        updatedAt: Date()
    )

    #expect(snapshot.accountLabel == "Junie API Key")
    #expect(snapshot.planType == "Pro")
    #expect(snapshot.sourceSummary == "Active · 6.47 / 10.00 monthly credits left")
    let metric = try #require(snapshot.metrics.first)
    #expect(metric.title == "Monthly credits")
    #expect(abs(metric.usedPercent - 35.254582) < 0.001)
    #expect(metric.usedLabel == "3.53 used")
    #expect(metric.remainingLabel == "6.47 / 10.00 monthly credits left")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    #expect(metric.resetsAt == formatter.date(from: "2026-06-16T05:53:53.825Z"))
}

@Test
func normalizesJunieRawMinorUnitQuotaPayload() throws {
    let payload = """
    {
      "username": "dev@example.com",
      "active": true,
      "licenseType": "junie"
    }
    """
    let quotaPayload = """
    {
      "current": 647454,
      "maximum": 1000000
    }
    """

    let snapshot = try JunieQuotaService().decodeSnapshot(
        from: Data(payload.utf8),
        quotaData: Data(quotaPayload.utf8),
        accountLabelFallback: "Fallback Junie",
        updatedAt: Date()
    )

    #expect(snapshot.planType == "Junie")
    let metric = try #require(snapshot.metrics.first)
    #expect(abs(metric.usedPercent - 35.2546) < 0.001)
    #expect(metric.usedLabel == "$3.53 used")
    #expect(metric.remainingLabel == "$6.47 / $10 left")
}

@Test
func junieAppManagedAccountDirectoryRoundTripsAccountID() {
    let directory = AgentProviderAppAuthStore.accountDirectory(
        for: .junie,
        accountID: "junie/account+symbols"
    )

    #expect(
        AgentProviderAppAuthStore.accountID(
            fromAccountDirectory: directory,
            provider: .junie
        ) == "junie/account+symbols"
    )
    #expect(
        AgentProviderAppAuthStore.isAppManagedAccountDirectory(
            ConfiguredAccountDirectory(path: directory.path),
            provider: .junie
        )
    )
}
