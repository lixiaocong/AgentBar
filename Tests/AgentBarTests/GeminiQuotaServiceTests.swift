import AgentBarCore
import Foundation
import Testing

@Test func decodesGeminiQuotaPayload() throws {
    let codeAssistJSON = """
    {
        "cloudaicompanionProject": "smart-pipe-wbjcj",
        "currentTier": {"id": "free-tier", "name": "Gemini Code Assist for individuals"}
    }
    """.data(using: .utf8)!

    let quotaJSON = """
    {
        "buckets": [
            {
                "resetTime": "2026-04-10T06:44:29Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-2.5-flash",
                "remainingFraction": 0.75,
                "remainingAmount": "150"
            },
            {
                "resetTime": "2026-04-10T06:44:29Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-2.5-flash-lite",
                "remainingFraction": 1.0,
                "remainingAmount": "200"
            },
            {
                "resetTime": "1970-01-01T00:00:00Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-2.5-pro",
                "remainingFraction": 0
            }
        ]
    }
    """.data(using: .utf8)!

    let service = GeminiQuotaService()
    let snapshot = try service.decodeSnapshot(
        codeAssistData: codeAssistJSON,
        quotaData: quotaJSON,
        accountLabel: "test@example.com",
        updatedAt: Date()
    )

    #expect(snapshot.provider == .gemini)
    #expect(snapshot.accountLabel == "test@example.com")
    #expect(snapshot.planType == "Free")
    #expect(snapshot.sourceSummary == "Google Cloud Code Assist API")

    // gemini-2.5-pro has remainingFraction 0 and epoch resetTime → filtered out
    #expect(snapshot.metrics.count == 2)

    let flashMetric = snapshot.metrics.first(where: { $0.id == "gemini-gemini-2.5-flash" })!
    #expect(flashMetric.usedPercent == 25.0)
    #expect(flashMetric.usedLabel == "50/200 used")
    #expect(flashMetric.remainingLabel == "150 left")

    let liteMetric = snapshot.metrics.first(where: { $0.id == "gemini-gemini-2.5-flash-lite" })!
    #expect(liteMetric.usedPercent == 0.0)
    #expect(liteMetric.usedLabel == "0/200 used")
    #expect(liteMetric.remainingLabel == "200 left")
}

@Test func geminiQuotaDefaultsToEmptyWhenNoBuckets() throws {
    let codeAssistJSON = """
    {
        "cloudaicompanionProject": "test-project",
        "currentTier": {"id": "standard-tier", "name": "Standard"}
    }
    """.data(using: .utf8)!

    let quotaJSON = """
    {
        "buckets": []
    }
    """.data(using: .utf8)!

    let service = GeminiQuotaService()
    let snapshot = try service.decodeSnapshot(
        codeAssistData: codeAssistJSON,
        quotaData: quotaJSON,
        accountLabel: "user@example.com",
        updatedAt: Date()
    )

    #expect(snapshot.provider == .gemini)
    #expect(snapshot.planType == "Standard")
    #expect(snapshot.metrics.isEmpty)
}

@Test func geminiFiltersOutUnavailableModels() throws {
    let codeAssistJSON = """
    {
        "cloudaicompanionProject": "test-project",
        "currentTier": {"id": "free-tier", "name": "Free tier"}
    }
    """.data(using: .utf8)!

    // Both models have remainingFraction 0 and epoch reset → unavailable on this tier
    let quotaJSON = """
    {
        "buckets": [
            {
                "resetTime": "1970-01-01T00:00:00Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-2.5-pro",
                "remainingFraction": 0
            },
            {
                "resetTime": "1970-01-01T00:00:00Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-3-pro-preview",
                "remainingFraction": 0
            },
            {
                "resetTime": "2026-04-10T06:44:29Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-2.5-flash",
                "remainingFraction": 0.5
            }
        ]
    }
    """.data(using: .utf8)!

    let service = GeminiQuotaService()
    let snapshot = try service.decodeSnapshot(
        codeAssistData: codeAssistJSON,
        quotaData: quotaJSON,
        accountLabel: "user@example.com",
        updatedAt: Date()
    )

    // Pro models filtered out (epoch reset + 0 remaining)
    #expect(snapshot.metrics.count == 1)
    #expect(snapshot.metrics[0].id == "gemini-gemini-2.5-flash")
    #expect(snapshot.metrics[0].usedPercent == 50.0)
}

@Test func geminiParsesOAuthClientMetadataFromCLIJavaScript() throws {
    let source = """
    const OAUTH_CLIENT_ID = 'test-client-id.apps.googleusercontent.com';
    const OAUTH_CLIENT_SECRET = 'test-client-secret';
    """

    let metadata = try GeminiQuotaService.parseOAuthClientConfiguration(source: source)

    #expect(metadata.clientID == "test-client-id.apps.googleusercontent.com")
    #expect(metadata.clientSecret == "test-client-secret")
}
