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
    var OAUTH_CLIENT_ID = 'test-client-id.apps.googleusercontent.com';
    var OAUTH_CLIENT_SECRET = 'test-client-secret';
    """

    let metadata = try GeminiQuotaService.parseOAuthClientConfiguration(source: source)

    #expect(metadata.clientID == "test-client-id.apps.googleusercontent.com")
    #expect(metadata.clientSecret == "test-client-secret")
}

@Test func geminiLoadsOAuthMetadataFromBundledCLIChunks() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appending(path: "AgentBarGeminiBundle-\(UUID().uuidString)", directoryHint: .isDirectory)
    let bundle = root
        .appending(path: "lib/node_modules/@google/gemini-cli/bundle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    let executable = bundle.appending(path: "gemini.js")
    let chunk = bundle.appending(path: "chunk-test.js")
    try "#!/usr/bin/env node\n".data(using: .utf8)!.write(to: executable)
    try """
    var OAUTH_CLIENT_ID = "bundle-client-id.apps.googleusercontent.com";
    var OAUTH_CLIENT_SECRET = "bundle-client-secret";
    """.data(using: .utf8)!.write(to: chunk)

    let installation = GeminiCLIInstallation(
        configDirectory: root,
        executableLocations: [executable]
    )
    let metadata = try GeminiOAuthConfiguration.loadClient(from: installation)

    #expect(metadata.clientID == "bundle-client-id.apps.googleusercontent.com")
    #expect(metadata.clientSecret == "bundle-client-secret")
}

@Test func geminiRefreshErrorsIdentifyInvalidStoredLogins() {
    #expect(GeminiQuotaError.missingAccessToken.invalidatesStoredLogin)
    #expect(GeminiQuotaError.missingRefreshToken.invalidatesStoredLogin)
    #expect(GeminiQuotaError.missingOAuthClientMetadata.invalidatesStoredLogin)
    #expect(GeminiQuotaError.tokenRefreshFailed(400, message: #"{"error":"invalid_grant"}"#).invalidatesStoredLogin)
    #expect(!GeminiQuotaError.tokenRefreshFailed(500, message: "temporary backend error").invalidatesStoredLogin)
    #expect(!GeminiQuotaError.httpStatus(401, message: "quota API unauthorized").invalidatesStoredLogin)
}
