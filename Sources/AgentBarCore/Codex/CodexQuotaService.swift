import Foundation
import os

public struct CodexInstallation: Sendable {
    public let rootDirectory: URL
    public let appManagedAccountID: String?

    public static let `default` = CodexInstallation(
        rootDirectory: CodexAppAuthStore.accountsDirectory
    )

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        self.appManagedAccountID = nil
    }

    private init(rootDirectory: URL, appManagedAccountID: String) {
        self.rootDirectory = rootDirectory
        self.appManagedAccountID = appManagedAccountID
    }

    public static func appManaged(accountID: String) -> CodexInstallation {
        CodexInstallation(
            rootDirectory: CodexAppAuthStore.accountDirectory(for: accountID),
            appManagedAccountID: accountID
        )
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
        if let accountID = installation.appManagedAccountID {
            return CodexAppAuthStore.hasSession(accountID: accountID)
        }

        return FileManager.default.fileExists(atPath: installation.authFile.path)
    }

    public func loadSnapshot() async throws -> AgentQuotaSnapshot {
        let installation = installation
        var credentials = try await Task.detached(priority: .userInitiated) {
            try loadCredentialsSynchronously(for: installation)
        }.value

        credentials = try await refreshAppManagedCredentialsIfNeeded(credentials)

        do {
            return try await loadSnapshot(credentials: credentials)
        } catch let error as CodexQuotaError where error.isAuthenticationFailure && credentials.appManagedAccountID != nil {
            let refreshedCredentials = try await refreshAppManagedCredentialsIfNeeded(credentials, force: true)
            guard refreshedCredentials.accessToken != credentials.accessToken else {
                throw error
            }

            logInfo("[Codex] Retrying usage request with refreshed AgentBar credentials")
            return try await loadSnapshot(credentials: refreshedCredentials)
        }
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
        if let accountID = installation.appManagedAccountID {
            guard let session = try CodexAppAuthStore.loadSession(accountID: accountID) else {
                let error = CodexQuotaError.missingStoredCredentials(accountID)
                logError("[Codex] \(error.errorDescription ?? "\(error)")")
                throw error
            }

            let accessToken = session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accessToken.isEmpty else {
                logError("[Codex] \(CodexQuotaError.missingAccessToken.errorDescription!)")
                throw CodexQuotaError.missingAccessToken
            }

            let accountLabel = preferredAccountLabel(
                idToken: session.idToken,
                fallbackAccountID: session.accountID
            )
            logDebug("[Codex] AgentBar credentials loaded for account \(masked(session.accountID))")
            return CodexAuthCredentials(
                accessToken: accessToken,
                refreshToken: session.refreshToken,
                idToken: session.idToken,
                accountID: session.accountID,
                accountLabel: accountLabel,
                appManagedAccountID: accountID
            )
        }

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
        return CodexAuthCredentials(
            accessToken: accessToken,
            refreshToken: auth.tokens?.refreshToken,
            idToken: auth.tokens?.idToken,
            accountID: accountID,
            accountLabel: accountLabel,
            appManagedAccountID: nil
        )
    }

    public func preferredAccountLabel(idToken: String?, fallbackAccountID: String) -> String {
        if let idToken, let identity = CodexAppAuthStore.identity(from: idToken) {
            if let email = identity.email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
                return email
            }

            if let name = identity.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }

        return "Account \(masked(fallbackAccountID))"
    }

    private func masked(_ value: String) -> String {
        guard value.count > 8 else {
            return value
        }

        return "\(value.prefix(4))...\(value.suffix(4))"
    }

    private func refreshAppManagedCredentialsIfNeeded(
        _ credentials: CodexAuthCredentials,
        force: Bool = false
    ) async throws -> CodexAuthCredentials {
        guard let appManagedAccountID = credentials.appManagedAccountID else {
            return credentials
        }

        guard force || shouldRefresh(accessToken: credentials.accessToken) else {
            return credentials
        }

        guard let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return credentials
        }

        let response = try await requestTokenRefresh(refreshToken: refreshToken)
        let updatedIDToken = response.idToken ?? credentials.idToken ?? ""
        let updatedAccessToken = response.accessToken ?? credentials.accessToken
        let updatedRefreshToken = response.refreshToken ?? refreshToken
        let returnedAccountID = CodexAppAuthStore.identity(from: updatedIDToken)?.accountID ?? credentials.accountID

        guard returnedAccountID == credentials.accountID else {
            throw CodexQuotaError.refreshFailed("Token refresh returned a different Codex account.")
        }

        let session = CodexStoredAuthSession(
            idToken: updatedIDToken,
            accessToken: updatedAccessToken,
            refreshToken: updatedRefreshToken,
            accountID: credentials.accountID,
            localAccountID: appManagedAccountID,
            lastRefresh: Date()
        )
        try CodexAppAuthStore.save(session: session)
        try? CodexAppAuthStore.ensureAccountDirectoryExists(for: appManagedAccountID)

        let accountLabel = preferredAccountLabel(
            idToken: updatedIDToken,
            fallbackAccountID: credentials.accountID
        )
        logInfo("[Codex] AgentBar credentials refreshed for account \(masked(credentials.accountID))")

        return CodexAuthCredentials(
            accessToken: updatedAccessToken,
            refreshToken: updatedRefreshToken,
            idToken: updatedIDToken,
            accountID: credentials.accountID,
            accountLabel: accountLabel,
            appManagedAccountID: appManagedAccountID
        )
    }

    private func shouldRefresh(accessToken: String) -> Bool {
        guard let expiresAt = jwtExpirationDate(accessToken) else {
            return false
        }

        return expiresAt <= Date().addingTimeInterval(60)
    }

    private func jwtExpirationDate(_ jwt: String) -> Date? {
        let segments = jwt.split(separator: ".")
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

        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiration = object["exp"] as? TimeInterval else {
            return nil
        }

        return Date(timeIntervalSince1970: expiration)
    }

    private func requestTokenRefresh(refreshToken: String) async throws -> CodexRefreshResponse {
        var request = URLRequest(url: CodexOAuthConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formURLEncoded([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", CodexOAuthConfiguration.clientID)
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexQuotaError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Request failed."
            throw CodexQuotaError.refreshFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        return try JSONDecoder().decode(CodexRefreshResponse.self, from: data)
    }

    private func formURLEncoded(_ items: [(String, String)]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(
            CharacterSet(charactersIn: ":#[]@!$&'()*+,;=")
        )
        let body = items.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        .joined(separator: "&")

        return Data(body.utf8)
    }
}

public enum CodexQuotaError: LocalizedError, Equatable {
    case missingCodexDirectory(String)
    case missingStoredCredentials(String)
    case unsupportedAuthMode
    case missingAccessToken
    case missingAccountID
    case invalidResponse
    case httpStatus(Int, message: String)
    case noQuotaInResponse
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .missingCodexDirectory(path):
            return "Codex root not found at \(path)."
        case .missingStoredCredentials:
            return "No AgentBar Codex browser login was found. Sign in from AgentBar settings."
        case .unsupportedAuthMode:
            return "Codex cloud quota requires ChatGPT login credentials, not an API-key-only login."
        case .missingAccessToken:
            return "No Codex access token was found. Sign in from AgentBar settings."
        case .missingAccountID:
            return "No ChatGPT account id was found for Codex. Sign in from AgentBar settings."
        case .invalidResponse:
            return "The Codex usage API returned an invalid response."
        case let .httpStatus(code, message):
            return "The Codex usage API failed with HTTP \(code): \(message)"
        case .noQuotaInResponse:
            return "The Codex usage API response did not include 5-hour or weekly quota windows."
        case let .refreshFailed(message):
            return "Codex browser login refresh failed: \(message)"
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
    let refreshToken: String?
    let accountId: String?
}

private struct CodexAuthCredentials: Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountID: String
    let accountLabel: String
    let appManagedAccountID: String?
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

private struct CodexRefreshResponse: Decodable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

private extension CodexQuotaError {
    var isAuthenticationFailure: Bool {
        guard case let .httpStatus(code, _) = self else {
            return false
        }

        return code == 401 || code == 403
    }
}
