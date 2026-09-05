import Foundation
import os

public struct ClaudeCLIInstallation: Sendable {
    public let configDirectory: URL
    /// Identifies the AgentBar browser sign-in whose credentials live in the
    /// Keychain. Claude accounts are always AgentBar-managed.
    public let appManagedAccountID: String?

    public init(configDirectory: URL, appManagedAccountID: String? = nil) {
        self.configDirectory = configDirectory
        self.appManagedAccountID = appManagedAccountID
    }

    public static func appManaged(accountID: String) -> ClaudeCLIInstallation {
        ClaudeCLIInstallation(
            configDirectory: AgentProviderAppAuthStore.accountDirectory(
                for: .claude,
                accountID: accountID
            ),
            appManagedAccountID: accountID
        )
    }
}

public struct ClaudeQuotaService: Sendable {
    public let installation: ClaudeCLIInstallation

    public init(installation: ClaudeCLIInstallation) {
        self.installation = installation
    }

    public var isAvailable: Bool {
        guard let accountID = installation.appManagedAccountID else {
            return false
        }

        return AgentProviderAppAuthStore.hasSession(provider: .claude, accountID: accountID)
    }

    public func loadSnapshot() async throws -> AgentQuotaSnapshot {
        guard let accountID = installation.appManagedAccountID else {
            throw ClaudeQuotaError.missingStoredCredentials(installation.configDirectory.path)
        }

        let session = try await Task.detached(priority: .userInitiated) {
            try loadSessionSynchronously(accountID: accountID)
        }.value

        return try await fetchOAuthSnapshot(session: session)
    }

    /// Exposed for unit tests — skips Keychain reading and network access.
    public func decodeUsageSnapshot(
        from data: Data,
        accountLabel: String,
        planType: String?,
        updatedAt: Date
    ) throws -> AgentQuotaSnapshot {
        let windows = try ClaudeUsageResponse.decodeWindows(from: data)

        return AgentQuotaSnapshot(
            provider: .claude,
            accountLabel: accountLabel,
            planType: planType,
            modelName: nil,
            sourceSummary: "Claude usage API",
            metrics: windows.map(Self.metric(for:)),
            updatedAt: updatedAt
        )
    }

    private static func metric(for window: ClaudeUsageWindow) -> AgentQuotaMetric {
        let usedPercent = min(max(window.utilization, 0), 100)

        return AgentQuotaMetric(
            id: "claude-\(window.key)",
            title: ClaudeUsageResponse.title(for: window.key),
            usedPercent: usedPercent,
            usedLabel: "\(Int(usedPercent.rounded()))% used",
            remainingLabel: "\(Int(max(0, 100 - usedPercent).rounded()))% left",
            resetsAt: window.resetsAt
        )
    }

    // MARK: - OAuth path

    private func loadSessionSynchronously(accountID: String) throws -> AgentProviderStoredAuthSession {
        guard let session = try AgentProviderAppAuthStore.loadSession(
            provider: .claude,
            accountID: accountID
        ) else {
            throw ClaudeQuotaError.missingStoredCredentials(accountID)
        }

        return session
    }

    private func fetchOAuthSnapshot(session: AgentProviderStoredAuthSession) async throws -> AgentQuotaSnapshot {
        let activeSession = try await refreshedSessionIfNeeded(session)
        let profile = try? await fetchProfile(accessToken: activeSession.accessToken)
        let data = try await fetchUsage(accessToken: activeSession.accessToken)

        return try decodeUsageSnapshot(
            from: data,
            accountLabel: profile?.preferredAccountLabel ?? activeSession.accountLabel,
            planType: profile?.planLabel,
            updatedAt: Date()
        )
    }

    private func fetchUsage(accessToken: String) async throws -> Data {
        var request = URLRequest(url: ClaudeOAuthConfiguration.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClaudeOAuthConfiguration.betaHeaderValue, forHTTPHeaderField: "anthropic-beta")

        logInfo("Claude → GET \(ClaudeOAuthConfiguration.usageURL.absoluteString)", log: networkLog)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeQuotaError.invalidResponse
        }

        logInfo("Claude ← HTTP \(httpResponse.statusCode)", log: networkLog)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Request failed."
            logError("Claude usage API error \(httpResponse.statusCode): \(body)", log: networkLog)
            if httpResponse.statusCode == 401 {
                throw ClaudeQuotaError.tokenRevoked(
                    "The Claude sign-in expired or was revoked. Sign in again from AgentBar settings."
                )
            }
            // Anthropic can disallow OAuth reads for a whole organization. Say so
            // plainly instead of surfacing the raw error envelope.
            if body.contains("oauth_not_allowed_for_organization") {
                throw ClaudeQuotaError.oauthNotAllowedForOrganization
            }
            throw ClaudeQuotaError.httpStatus(httpResponse.statusCode, message: body)
        }

        return data
    }

    private func fetchProfile(accessToken: String) async throws -> ClaudeOAuthProfile {
        var request = URLRequest(url: ClaudeOAuthConfiguration.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClaudeOAuthConfiguration.betaHeaderValue, forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw ClaudeQuotaError.invalidResponse
        }

        return try ClaudeOAuthProfile.decode(from: data)
    }

    /// Refreshes shortly before expiry so a long-lived menu bar session does not
    /// start failing between refresh ticks.
    private func refreshedSessionIfNeeded(
        _ session: AgentProviderStoredAuthSession
    ) async throws -> AgentProviderStoredAuthSession {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            return session
        }

        guard let expiryDate = session.expiryDate,
              expiryDate.timeIntervalSinceNow < 300 else {
            return session
        }

        let refreshed = try await requestTokenRefresh(refreshToken: refreshToken)
        let updatedSession = AgentProviderStoredAuthSession(
            provider: .claude,
            accountID: session.accountID,
            accountLabel: session.accountLabel,
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            expiryDate: refreshed.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            scopes: session.scopes,
            lastRefresh: Date()
        )

        try AgentProviderAppAuthStore.save(session: updatedSession)
        return updatedSession
    }

    private func requestTokenRefresh(refreshToken: String) async throws -> ClaudeRefreshResponse {
        var request = URLRequest(url: ClaudeOAuthConfiguration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": ClaudeOAuthConfiguration.clientID
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClaudeQuotaError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Request failed."
            if body.localizedCaseInsensitiveContains("invalid_grant") {
                throw ClaudeQuotaError.tokenRevoked(
                    "The Claude sign-in was revoked. Sign in again from AgentBar settings."
                )
            }
            throw ClaudeQuotaError.refreshFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        return try JSONDecoder().decode(ClaudeRefreshResponse.self, from: data)
    }
}

public enum ClaudeQuotaError: LocalizedError, Equatable {
    case missingStoredCredentials(String)
    case invalidResponse
    case httpStatus(Int, message: String)
    case refreshFailed(String)
    case tokenRevoked(String)
    case oauthNotAllowedForOrganization

    public var errorDescription: String? {
        switch self {
        case .oauthNotAllowedForOrganization:
            return "Anthropic does not allow OAuth usage reads for this account's organization. Usage windows are available to Claude Pro and Max subscriptions; API/Console-only organizations are not supported."
        case let .missingStoredCredentials(accountID):
            return "No stored Claude credentials for \(accountID). Sign in again from AgentBar settings."
        case .invalidResponse:
            return "Claude returned an unreadable response."
        case let .httpStatus(status, message):
            return "Claude usage request failed with HTTP \(status): \(message)"
        case let .refreshFailed(message):
            return "Claude token refresh failed: \(message)"
        case let .tokenRevoked(message):
            return message
        }
    }
}

private struct ClaudeRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}
