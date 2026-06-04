import AgentBarCore
import Foundation
import Testing

@Test func decodesGeminiQuotaPayload() throws {
    let codeAssistJSON = try sharedFixtureData("gemini", "code-assist-free.json")
    let quotaJSON = try sharedFixtureData("gemini", "quota-free.json")

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

    #expect(snapshot.metrics.count == 3)

    let flashMetric = snapshot.metrics.first(where: { $0.id == "gemini-2.5-flash" })!
    #expect(flashMetric.title == "Gemini 2.5 Flash")
    #expect(flashMetric.usedPercent == 25.0)
    #expect(flashMetric.usedLabel == "50/200 used")
    #expect(flashMetric.remainingLabel == "150 left")

    let liteMetric = snapshot.metrics.first(where: { $0.id == "gemini-2.5-flash-lite" })!
    #expect(liteMetric.title == "Gemini 2.5 Flash Lite")
    #expect(liteMetric.usedPercent == 0.0)
    #expect(liteMetric.usedLabel == "0/200 used")
    #expect(liteMetric.remainingLabel == "200 left")

    let proMetric = snapshot.metrics.first(where: { $0.id == "gemini-2.5-pro" })!
    #expect(proMetric.title == "Gemini 2.5 Pro")
    #expect(proMetric.usedPercent == 100.0)
    #expect(proMetric.usedLabel == "100% used")
    #expect(proMetric.remainingLabel == "0% left")
    #expect(proMetric.resetsAt == nil)
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

@Test func geminiKeepsReturnedZeroRemainingModels() throws {
    let codeAssistJSON = """
    {
        "cloudaicompanionProject": "test-project",
        "currentTier": {"id": "free-tier", "name": "Free tier"}
    }
    """.data(using: .utf8)!

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

    #expect(snapshot.metrics.map(\.id) == [
        "gemini-2.5-pro",
        "gemini-3-pro-preview",
        "gemini-2.5-flash"
    ])
    #expect(snapshot.metrics[0].title == "Gemini 2.5 Pro")
    #expect(snapshot.metrics[0].usedPercent == 100.0)
    #expect(snapshot.metrics[0].resetsAt == nil)
    #expect(snapshot.metrics[2].usedPercent == 50.0)
}

@Test func geminiDisplaysDynamicQuotaBuckets() throws {
    let codeAssistJSON = """
    {
        "cloudaicompanionProject": "test-project",
        "currentTier": {"id": "free-tier", "name": "Free tier"}
    }
    """.data(using: .utf8)!

    let quotaJSON = """
    {
        "buckets": [
            {
                "resetTime": "2026-06-04T07:19:14Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-2.5-flash",
                "remainingFraction": 1
            },
            {
                "resetTime": "2026-06-04T07:19:14Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-3-flash-preview",
                "remainingFraction": 0.75
            },
            {
                "resetTime": "2026-06-04T07:19:14Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-2.5-flash-lite",
                "remainingFraction": 0.9
            },
            {
                "resetTime": "2026-06-04T07:19:14Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-3.1-flash-lite",
                "remainingFraction": 1
            },
            {
                "resetTime": "1970-01-01T00:00:00Z",
                "tokenType": "REQUESTS",
                "modelId": "gemini-3.1-pro-preview",
                "remainingFraction": 0
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

    #expect(snapshot.metrics.map(\.id) == [
        "gemini-2.5-flash",
        "gemini-3-flash-preview",
        "gemini-2.5-flash-lite",
        "gemini-3.1-flash-lite",
        "gemini-3.1-pro-preview"
    ])
    #expect(snapshot.metrics.map(\.title) == [
        "Gemini 2.5 Flash",
        "Gemini 3 Flash Preview",
        "Gemini 2.5 Flash Lite",
        "Gemini 3.1 Flash Lite",
        "Gemini 3.1 Pro Preview"
    ])
    #expect(snapshot.metrics[1].usedPercent == 25.0)
    #expect(abs(snapshot.metrics[2].usedPercent - 10.0) < 0.0001)
    #expect(snapshot.metrics[4].usedPercent == 100.0)
    #expect(snapshot.metrics[4].resetsAt == nil)
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
