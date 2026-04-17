import Foundation
import os

public struct CodexInstallation: Sendable {
    public let rootDirectory: URL

    public static let `default` = CodexInstallation(
        rootDirectory: URL(fileURLWithPath: NSString(string: "~/.codex").expandingTildeInPath)
    )

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var authFile: URL {
        rootDirectory.appending(path: "auth.json")
    }
}

public struct CodexQuotaService: Sendable {
    public let installation: CodexInstallation

    public init(installation: CodexInstallation = .default) {
        self.installation = installation
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: installation.authFile.path)
    }

    public func loadSnapshot() async throws -> AgentQuotaSnapshot {
        let installation = installation
        let credentials = try await Task.detached(priority: .userInitiated) {
            try loadCredentialsSynchronously(for: installation)
        }.value

        return try await loadSnapshot(credentials: credentials)
    }

    private func loadSnapshot(credentials: CodexAuthCredentials) async throws -> AgentQuotaSnapshot {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        logInfo("Codex → GET https://chatgpt.com/backend-api/wham/usage (account: \(masked(credentials.accountID)))", log: networkLog)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexQuotaError.invalidResponse
        }

        logInfo("Codex ← HTTP \(httpResponse.statusCode)", log: networkLog)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Request failed."
            logError("Codex API error \(httpResponse.statusCode): \(body)", log: networkLog)
            throw CodexQuotaError.httpStatus(httpResponse.statusCode, message: body)
        }

        logDebug("Codex response body: \(String(data: data, encoding: .utf8) ?? "<non-UTF8>")", log: networkLog)

        return try decodeSnapshot(
            from: data,
            accountLabel: credentials.accountLabel,
            updatedAt: Date()
        )
    }

    public func decodeSnapshot(
        from data: Data,
        accountLabel: String,
        updatedAt: Date
    ) throws -> AgentQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(CodexUsagePayload.self, from: data)

        guard let rateLimit = payload.rateLimit else {
            throw CodexQuotaError.noQuotaInResponse
        }

        let metrics = [rateLimit.primaryWindow?.asMetric, rateLimit.secondaryWindow?.asMetric].compactMap { $0 }
        guard !metrics.isEmpty else {
            throw CodexQuotaError.noQuotaInResponse
        }

        return AgentQuotaSnapshot(
            provider: .codex,
            accountLabel: accountLabel,
            planType: payload.planType,
            modelName: nil,
            sourceSummary: "ChatGPT Codex API",
            metrics: metrics,
            updatedAt: updatedAt
        )
    }

    private func loadCredentialsSynchronously(for installation: CodexInstallation) throws -> CodexAuthCredentials {
        let rootDirectory = installation.rootDirectory
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootDirectory.path) else {
            let err = CodexQuotaError.missingCodexDirectory(rootDirectory.path)
            logError("[Codex] \(err.errorDescription ?? "\(err)")")
            throw err
        }

        let authFile = installation.authFile
        let data: Data
        do {
            data = try Data(contentsOf: authFile)
        } catch {
            logError("[Codex] Cannot read auth.json: \(error)")
            throw error
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let auth: CodexStoredAuth
        do {
            auth = try decoder.decode(CodexStoredAuth.self, from: data)
        } catch {
            logError("[Codex] auth.json decode failed: \(error)")
            throw error
        }

        if let authMode = auth.authMode?.lowercased(), authMode.contains("api_key") {
            logError("[Codex] \(CodexQuotaError.unsupportedAuthMode.errorDescription!)")
            throw CodexQuotaError.unsupportedAuthMode
        }

        guard let accessToken = auth.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            logError("[Codex] \(CodexQuotaError.missingAccessToken.errorDescription!)")
            throw CodexQuotaError.missingAccessToken
        }

        guard let accountID = auth.tokens?.accountId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else {
            logError("[Codex] \(CodexQuotaError.missingAccountID.errorDescription!)")
            throw CodexQuotaError.missingAccountID
        }

        let accountLabel = preferredAccountLabel(idToken: auth.tokens?.idToken, fallbackAccountID: accountID)
        logDebug("[Codex] Credentials loaded for account \(masked(accountID))")
        return CodexAuthCredentials(accessToken: accessToken, accountID: accountID, accountLabel: accountLabel)
    }

    public func preferredAccountLabel(idToken: String?, fallbackAccountID: String) -> String {
        if let claims = decodeIDTokenClaims(from: idToken) {
            if let email = claims.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                return email
            }

            if let name = claims.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }

        return "Account \(masked(fallbackAccountID))"
    }

    private func decodeIDTokenClaims(from idToken: String?) -> CodexIDTokenClaims? {
        guard let idToken, !idToken.isEmpty else {
            return nil
        }

        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else {
            return nil
        }

        var payload = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let remainder = payload.count % 4
        if remainder != 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard let payloadData = Data(base64Encoded: payload) else {
            return nil
        }

        let decoder = JSONDecoder()
        return try? decoder.decode(CodexIDTokenClaims.self, from: payloadData)
    }

    private func masked(_ value: String) -> String {
        guard value.count > 8 else {
            return value
        }

        return "\(value.prefix(4))...\(value.suffix(4))"
    }
}

public enum CodexQuotaError: LocalizedError, Equatable {
    case missingCodexDirectory(String)
    case unsupportedAuthMode
    case missingAccessToken
    case missingAccountID
    case invalidResponse
    case httpStatus(Int, message: String)
    case noQuotaInResponse

    public var errorDescription: String? {
        switch self {
        case let .missingCodexDirectory(path):
            return "Codex root not found at \(path)."
        case .unsupportedAuthMode:
            return "Codex cloud quota requires ChatGPT login credentials, not an API-key-only login."
        case .missingAccessToken:
            return "No Codex access token was found. Run `codex` and sign in again."
        case .missingAccountID:
            return "No ChatGPT account id was found for Codex. Run `codex` and sign in again."
        case .invalidResponse:
            return "The Codex usage API returned an invalid response."
        case let .httpStatus(code, message):
            return "The Codex usage API failed with HTTP \(code): \(message)"
        case .noQuotaInResponse:
            return "The Codex usage API response did not include 5-hour or weekly quota windows."
        }
    }
}

private struct CodexStoredAuth: Decodable {
    let authMode: String?
    let tokens: CodexStoredTokens?
}

private struct CodexStoredTokens: Decodable {
    let idToken: String?
    let accessToken: String?
    let accountId: String?
}

private struct CodexAuthCredentials: Sendable {
    let accessToken: String
    let accountID: String
    let accountLabel: String
}

private struct CodexIDTokenClaims: Decodable {
    let email: String?
    let name: String?
}

private struct CodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: CodexUsageRateLimit?
}

private struct CodexUsageRateLimit: Decodable {
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?
}

private struct CodexUsageWindow: Decodable {
    let usedPercent: Double
    let limitWindowSeconds: Int
    let resetAt: TimeInterval

    var asMetric: AgentQuotaMetric {
        AgentQuotaMetric.usageWindow(
            windowMinutes: max(1, (limitWindowSeconds + 59) / 60),
            usedPercent: usedPercent,
            resetsAt: Date(timeIntervalSince1970: resetAt)
        )
    }
}
