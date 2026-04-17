import Foundation
import os

// MARK: - Installation

public struct GeminiCLIInstallation: Sendable {
    public let configDirectory: URL
    public let executableLocations: [URL]

    public static let defaultExecutableLocations = [
        URL(fileURLWithPath: "/opt/homebrew/bin/gemini"),
        URL(fileURLWithPath: "/usr/local/bin/gemini"),
    ]

    public static let `default` = GeminiCLIInstallation(
        configDirectory: URL(fileURLWithPath: NSString(string: "~/.gemini").expandingTildeInPath),
        executableLocations: Self.defaultExecutableLocations
    )

    public init(configDirectory: URL, executableLocations: [URL]) {
        self.configDirectory = configDirectory
        self.executableLocations = executableLocations
    }

    public var oauthCredsFile: URL { configDirectory.appending(path: "oauth_creds.json") }
    public var googleAccountsFile: URL { configDirectory.appending(path: "google_accounts.json") }

    public var oauthClientSourceCandidates: [URL] {
        var candidates: [URL] = []

        for executable in executableLocations {
            let resolved = executable.resolvingSymlinksInPath().standardizedFileURL
            appendUnique(
                Self.oauthClientSourceCandidates(derivedFrom: resolved),
                to: &candidates
            )
        }

        return candidates
    }

    private static func oauthClientSourceCandidates(derivedFrom executable: URL) -> [URL] {
        let suffixes = [
            "libexec/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "dist/src/code_assist/oauth2.js",
        ]

        var directories: [URL] = []
        var current = executable.deletingLastPathComponent()

        for _ in 0 ..< 8 {
            directories.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return directories.flatMap { directory in
            suffixes.map { suffix in
                directory.appending(path: suffix)
            }
        }
    }

    private func appendUnique(_ urls: [URL], to existing: inout [URL]) {
        for url in urls where !existing.contains(url) {
            existing.append(url)
        }
    }
}

// MARK: - Service

public struct GeminiQuotaService: Sendable {
    public let installation: GeminiCLIInstallation

    public init(installation: GeminiCLIInstallation = .default) {
        self.installation = installation
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: installation.oauthCredsFile.path)
    }

    public func loadSnapshot() async throws -> AgentQuotaSnapshot {
        let installation = installation
        let credentials = try await Task.detached(priority: .userInitiated) {
            try loadCredentialsSynchronously(for: installation)
        }.value

        let accessToken = try await resolveAccessToken(credentials)
        let codeAssist = try await loadCodeAssist(accessToken: accessToken)
        let quota = try await retrieveUserQuota(accessToken: accessToken, projectID: codeAssist.projectID)

        return buildSnapshot(
            codeAssist: codeAssist,
            quota: quota,
            accountLabel: credentials.accountLabel,
            updatedAt: Date()
        )
    }

    /// Exposed for unit tests — decodes loadCodeAssist + retrieveUserQuota payloads directly.
    public func decodeSnapshot(
        codeAssistData: Data,
        quotaData: Data,
        accountLabel: String,
        updatedAt: Date
    ) throws -> AgentQuotaSnapshot {
        let decoder = JSONDecoder()
        let caResponse = try decoder.decode(GeminiCodeAssistResponse.self, from: codeAssistData)
        let quotaResponse = try decoder.decode(GeminiQuotaResponse.self, from: quotaData)

        let codeAssist = GeminiCodeAssistInfo(
            projectID: caResponse.cloudaicompanionProject ?? "",
            tierID: caResponse.currentTier?.id,
            tierName: caResponse.currentTier?.name
        )

        return buildSnapshot(
            codeAssist: codeAssist,
            quota: quotaResponse,
            accountLabel: accountLabel,
            updatedAt: updatedAt
        )
    }

    // MARK: - Private

    private func resolveAccessToken(_ credentials: GeminiCredentials) async throws -> String {
        // Check if existing token is still valid (with 60s buffer)
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let expiry = credentials.expiryDate, expiry > nowMs + 60_000 {
            return credentials.accessToken
        }

        // Refresh the token
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            logError("[Gemini] Access token expired and no refresh token available")
            throw GeminiQuotaError.missingRefreshToken
        }

        logInfo("Gemini → refreshing access token", log: networkLog)
        let oauthClient = try loadOAuthClientConfiguration()

        var components = URLComponents(string: "https://oauth2.googleapis.com/token")!
        components.queryItems = nil
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: oauthClient.clientID),
            URLQueryItem(name: "client_secret", value: oauthClient.clientSecret),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "grant_type", value: "refresh_token"),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let msg = String(data: data, encoding: .utf8) ?? "Token refresh failed"
            logError("Gemini token refresh failed: HTTP \(statusCode): \(msg)", log: networkLog)
            throw GeminiQuotaError.tokenRefreshFailed(statusCode, message: msg)
        }

        let tokenResponse = try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
        logInfo("Gemini ← token refreshed successfully", log: networkLog)
        return tokenResponse.accessToken
    }

    private func loadCodeAssist(accessToken: String) async throws -> GeminiCodeAssistInfo {
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "cloudaicompanionProject": NSNull(),
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logInfo("Gemini → POST \(url.absoluteString)", log: networkLog)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiQuotaError.invalidResponse
        }

        logInfo("Gemini ← loadCodeAssist HTTP \(httpResponse.statusCode)", log: networkLog)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Request failed"
            logError("Gemini loadCodeAssist error \(httpResponse.statusCode): \(msg)", log: networkLog)
            throw GeminiQuotaError.httpStatus(httpResponse.statusCode, message: msg)
        }

        logDebug("Gemini loadCodeAssist body: \(String(data: data, encoding: .utf8) ?? "<non-UTF8>")", log: networkLog)

        let decoded = try JSONDecoder().decode(GeminiCodeAssistResponse.self, from: data)
        return GeminiCodeAssistInfo(
            projectID: decoded.cloudaicompanionProject ?? "",
            tierID: decoded.currentTier?.id,
            tierName: decoded.currentTier?.name
        )
    }

    private func retrieveUserQuota(accessToken: String, projectID: String) async throws -> GeminiQuotaResponse {
        let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["project": projectID]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logInfo("Gemini → POST \(url.absoluteString) (project: \(projectID))", log: networkLog)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiQuotaError.invalidResponse
        }

        logInfo("Gemini ← retrieveUserQuota HTTP \(httpResponse.statusCode)", log: networkLog)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "Request failed"
            logError("Gemini retrieveUserQuota error \(httpResponse.statusCode): \(msg)", log: networkLog)
            throw GeminiQuotaError.httpStatus(httpResponse.statusCode, message: msg)
        }

        logDebug("Gemini retrieveUserQuota body: \(String(data: data, encoding: .utf8) ?? "<non-UTF8>")", log: networkLog)

        return try JSONDecoder().decode(GeminiQuotaResponse.self, from: data)
    }

    private func buildSnapshot(
        codeAssist: GeminiCodeAssistInfo,
        quota: GeminiQuotaResponse,
        accountLabel: String,
        updatedAt: Date
    ) -> AgentQuotaSnapshot {
        let buckets = (quota.buckets ?? []).filter { $0.tokenType == "REQUESTS" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()

        let metrics: [AgentQuotaMetric] = buckets.compactMap { bucket in
            let modelId = bucket.modelId ?? "unknown"
            let remainingFraction = bucket.remainingFraction ?? 0

            // Skip models with epoch reset time and 0 remaining — not available on this tier
            if remainingFraction <= 0 {
                if let resetStr = bucket.resetTime,
                   let resetDate = formatter.date(from: resetStr) ?? fallbackFormatter.date(from: resetStr),
                   resetDate.timeIntervalSince1970 < 100 {
                    return nil
                }
            }

            let usedPercent = (1.0 - min(max(remainingFraction, 0), 1.0)) * 100.0

            let resetsAt: Date? = {
                guard let resetStr = bucket.resetTime else { return nil }
                let d = formatter.date(from: resetStr) ?? fallbackFormatter.date(from: resetStr)
                // Ignore epoch dates (1970)
                if let d, d.timeIntervalSince1970 < 100 { return nil }
                return d
            }()

            let remainingAmount = bucket.remainingAmount.flatMap { Int($0) }

            let usedLabel: String
            let remainingLabel: String
            if let remaining = remainingAmount, remainingFraction > 0 {
                let limit = Int(Double(remaining) / remainingFraction)
                let used = max(0, limit - remaining)
                usedLabel = "\(used)/\(limit) used"
                remainingLabel = "\(remaining) left"
            } else if let remaining = remainingAmount {
                usedLabel = "\(Int(usedPercent.rounded()))% used"
                remainingLabel = "\(remaining) left"
            } else {
                usedLabel = "\(Int(usedPercent.rounded()))% used"
                remainingLabel = "\(Int(max(0, 100 - usedPercent).rounded()))% left"
            }

            return AgentQuotaMetric(
                id: "gemini-\(modelId)",
                title: formatModelName(modelId),
                usedPercent: usedPercent,
                usedLabel: usedLabel,
                remainingLabel: remainingLabel,
                resetsAt: resetsAt
            )
        }

        let tierName: String? = {
            guard let id = codeAssist.tierID else { return nil }
            switch id {
            case "free-tier": return "Free"
            case "legacy-tier": return "Legacy"
            case "standard-tier": return "Standard"
            default: return codeAssist.tierName ?? id
            }
        }()

        return AgentQuotaSnapshot(
            provider: .gemini,
            accountLabel: accountLabel,
            planType: tierName,
            modelName: nil,
            sourceSummary: "Google Cloud Code Assist API",
            metrics: metrics,
            updatedAt: updatedAt
        )
    }

    private func loadOAuthClientConfiguration() throws -> GeminiOAuthClientConfiguration {
        for sourceFile in installation.oauthClientSourceCandidates {
            guard FileManager.default.fileExists(atPath: sourceFile.path) else {
                continue
            }

            do {
                let source = try String(contentsOf: sourceFile, encoding: .utf8)
                let config = try Self.parseOAuthClientConfiguration(source: source)
                logDebug("[Gemini] OAuth client metadata loaded from \(sourceFile.path)", log: networkLog)
                return config
            } catch {
                logDebug("[Gemini] Failed to parse OAuth client metadata at \(sourceFile.path): \(error)", log: networkLog)
            }
        }

        logError("[Gemini] Could not locate Gemini CLI OAuth client metadata for token refresh")
        throw GeminiQuotaError.missingOAuthClientMetadata
    }

    public static func parseOAuthClientConfiguration(source: String) throws -> GeminiOAuthClientConfiguration {
        guard
            let clientID = extractJavaScriptConstant(named: "OAUTH_CLIENT_ID", from: source),
            let clientSecret = extractJavaScriptConstant(named: "OAUTH_CLIENT_SECRET", from: source)
        else {
            throw GeminiQuotaError.missingOAuthClientMetadata
        }

        return GeminiOAuthClientConfiguration(
            clientID: clientID,
            clientSecret: clientSecret
        )
    }

    private func loadCredentialsSynchronously(for installation: GeminiCLIInstallation) throws -> GeminiCredentials {
        let oauthFile = installation.oauthCredsFile
        guard FileManager.default.fileExists(atPath: oauthFile.path) else {
            let msg = "Gemini credentials not found at \(oauthFile.path) — run `gemini` and sign in first"
            logError(msg)
            throw GeminiQuotaError.missingCredentialsFile(oauthFile.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: oauthFile)
        } catch {
            logError("[Gemini] Cannot read oauth_creds.json: \(error)")
            throw error
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let creds: GeminiOAuthCreds
        do {
            creds = try decoder.decode(GeminiOAuthCreds.self, from: data)
        } catch {
            logError("[Gemini] oauth_creds.json decode failed: \(error)")
            throw error
        }

        guard let accessToken = creds.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            logError("[Gemini] No access token found in oauth_creds.json — run `gemini` and sign in")
            throw GeminiQuotaError.missingAccessToken
        }

        // Read account label from google_accounts.json
        let accountLabel = readAccountLabel(for: installation) ?? "Google Account"

        logDebug("[Gemini] Credentials loaded for \(accountLabel)")
        return GeminiCredentials(
            accessToken: accessToken,
            refreshToken: creds.refreshToken,
            expiryDate: creds.expiryDate,
            accountLabel: accountLabel
        )
    }

    private func readAccountLabel(for installation: GeminiCLIInstallation) -> String? {
        let file = installation.googleAccountsFile
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoded = try? JSONDecoder().decode(GeminiGoogleAccounts.self, from: data)
        return decoded?.active
    }

    private func formatModelName(_ modelId: String) -> String {
        // "gemini-2.5-flash" → "Gemini 2.5 Flash"
        modelId
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func extractJavaScriptConstant(named name: String, from source: String) -> String? {
        for delimiter in ["'", "\""] {
            let prefix = "const \(name) = \(delimiter)"
            guard let start = source.range(of: prefix)?.upperBound else {
                continue
            }

            guard let end = source[start...].firstIndex(of: delimiter.first!) else {
                continue
            }

            return String(source[start ..< end])
        }

        return nil
    }
}

// MARK: - Errors

public enum GeminiQuotaError: LocalizedError, Equatable {
    case missingCredentialsFile(String)
    case missingAccessToken
    case missingRefreshToken
    case missingOAuthClientMetadata
    case tokenRefreshFailed(Int, message: String)
    case invalidResponse
    case httpStatus(Int, message: String)

    public var errorDescription: String? {
        switch self {
        case let .missingCredentialsFile(path):
            return "Gemini credentials not found at \(path). Run `gemini` and sign in first."
        case .missingAccessToken:
            return "No Gemini access token found. Run `gemini` and sign in."
        case .missingRefreshToken:
            return "Gemini access token expired and no refresh token available. Run `gemini` and sign in again."
        case .missingOAuthClientMetadata:
            return "Gemini access token expired and AgentBar could not find OAuth client metadata in the local Gemini CLI installation."
        case let .tokenRefreshFailed(code, message):
            return "Gemini token refresh failed with HTTP \(code): \(message)"
        case .invalidResponse:
            return "The Gemini quota API returned an invalid response."
        case let .httpStatus(code, message):
            return "Gemini API request failed with HTTP \(code): \(message)"
        }
    }
}

// MARK: - Decodable types

private struct GeminiOAuthCreds: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiryDate: Double?
}

private struct GeminiGoogleAccounts: Decodable {
    let active: String?
}

private struct GoogleTokenResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

public struct GeminiOAuthClientConfiguration: Equatable, Sendable {
    public let clientID: String
    public let clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

struct GeminiCredentials: Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiryDate: Double?
    let accountLabel: String
}

struct GeminiCodeAssistInfo: Sendable {
    let projectID: String
    let tierID: String?
    let tierName: String?
}

// Exposed for test decoding
struct GeminiCodeAssistResponse: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: GeminiTier?
    let paidTier: GeminiTier?
}

struct GeminiTier: Decodable {
    let id: String?
    let name: String?
}

struct GeminiQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]?
}

struct GeminiQuotaBucket: Decodable {
    let remainingAmount: String?
    let remainingFraction: Double?
    let resetTime: String?
    let tokenType: String?
    let modelId: String?
}
