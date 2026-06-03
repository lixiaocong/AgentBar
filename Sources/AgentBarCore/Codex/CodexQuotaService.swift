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

}

public struct CodexQuotaService: Sendable {
    public let installation: CodexInstallation

    public init(installation: CodexInstallation = .default) {
        self.installation = installation
    }

    public var isAvailable: Bool {
        if let accountID = installation.appManagedAccountID {
            return !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return false
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
            if Self.isTokenRevokedResponse(body) {
                throw CodexQuotaError.tokenRevoked("The Codex OAuth token was revoked by another OpenAI app session.")
            }
            throw CodexQuotaError.httpStatus(httpResponse.statusCode, message: body)
        }

        logDebug("Codex response body: \(String(data: data, encoding: .utf8) ?? "<non-UTF8>")", log: networkLog)

        let apiWorkspaceLabel = try? await loadWorkspaceDisplayName(credentials: credentials)

        return try decodeSnapshot(
            from: data,
            accountLabel: credentials.accountLabel,
            spaceLabel: apiWorkspaceLabel ?? credentials.spaceLabel,
            updatedAt: Date()
        )
    }

    public func decodeSnapshot(
        from data: Data,
        accountLabel: String,
        spaceLabel: String? = nil,
        updatedAt: Date
    ) throws -> AgentQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(CodexUsagePayload.self, from: data)

        var metrics: [AgentQuotaMetric] = []
        if let rateLimit = payload.rateLimit {
            metrics.append(contentsOf: rateLimit.metrics())
        }

        if let codeReviewRateLimit = payload.codeReviewRateLimit {
            metrics.append(contentsOf: codeReviewRateLimit.metrics(
                idPrefix: "code-review",
                titlePrefix: "Code review"
            ))
        }

        for (index, additionalRateLimit) in (payload.additionalRateLimits ?? []).enumerated() {
            guard let rateLimit = additionalRateLimit.rateLimit else {
                continue
            }

            metrics.append(contentsOf: rateLimit.metrics(
                idPrefix: "additional-\(index + 1)",
                titlePrefix: additionalRateLimit.displayLabel ?? "Additional limit \(index + 1)"
            ))
        }

        metrics = uniqueMetrics(metrics)
        let rateLimits = ([payload.rateLimit, payload.codeReviewRateLimit] + (payload.additionalRateLimits ?? []).map(\.rateLimit)).compactMap { $0 }
        let hasQuotaState = rateLimits.contains(where: \.hasQuotaState) || payload.credits?.hasQuotaState == true

        guard !metrics.isEmpty || hasQuotaState else {
            throw CodexQuotaError.noQuotaInResponse
        }

        return AgentQuotaSnapshot(
            provider: .codex,
            accountLabel: accountLabel,
            spaceLabel: displaySpaceLabel(
                rawSpaceLabel: spaceLabel,
                planType: payload.planType
            ),
            planType: payload.planType,
            modelName: nil,
            sourceSummary: metrics.isEmpty ? "No active Codex quota windows" : "ChatGPT Codex API",
            metrics: metrics,
            updatedAt: updatedAt
        )
    }

    private func uniqueMetrics(_ metrics: [AgentQuotaMetric]) -> [AgentQuotaMetric] {
        var seen = Set<String>()
        return metrics.filter { metric in
            seen.insert(metric.id).inserted
        }
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

            logDebug("[Codex] AgentBar credentials loaded for account \(masked(session.accountID))")
            return appManagedCredentials(from: session, storageAccountID: accountID)
        }

        let error = CodexQuotaError.missingStoredCredentials("app-managed")
        logError("[Codex] \(error.errorDescription ?? "\(error)")")
        throw error
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

    private func preferredSpaceLabel(idToken: String?) -> String? {
        guard let idToken,
              let label = CodexAppAuthStore.identity(from: idToken)?.spaceLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }

        return label
    }

    private func displaySpaceLabel(
        rawSpaceLabel: String?,
        planType: String?
    ) -> String? {
        let normalizedPlan = planType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        if isBusinessPlan(normalizedPlan) {
            if let workspaceLabel = trimmedLabel(rawSpaceLabel),
               !isGenericPersonalSpaceLabel(workspaceLabel) {
                return "\(workspaceDisplayName(from: workspaceLabel)) · \(businessPlanFallbackLabel(normalizedPlan))"
            }

            return businessPlanFallbackLabel(normalizedPlan)
        }

        if normalizedPlan.contains("pro") {
            return "Personal Pro"
        }

        if normalizedPlan.contains("plus") {
            return "Personal Plus"
        }

        if normalizedPlan == "free" {
            return "Personal Free"
        }

        return trimmedLabel(rawSpaceLabel)
    }

    private func isGenericPersonalSpaceLabel(_ label: String) -> Bool {
        let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "personal" ||
            normalized == "personal workspace" ||
            normalized == "personal org"
    }

    private func workspaceDisplayName(from label: String) -> String {
        label.replacingOccurrences(
            of: #"(?i)\s+workspace\s+#(\d+)$"#,
            with: "",
            options: .regularExpression
        )
    }

    private func businessPlanFallbackLabel(_ normalizedPlan: String) -> String {
        if normalizedPlan.contains("enterprise") {
            return "Enterprise"
        }

        if normalizedPlan.contains("edu") {
            return "Education"
        }

        if normalizedPlan.contains("team") {
            return "Team"
        }

        return "Business"
    }

    private func isBusinessPlan(_ normalizedPlan: String) -> Bool {
        normalizedPlan.contains("team") ||
            normalizedPlan.contains("business") ||
            normalizedPlan.contains("enterprise") ||
            normalizedPlan.contains("workspace") ||
            normalizedPlan.contains("edu")
    }

    private func trimmedLabel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func loadWorkspaceDisplayName(credentials: CodexAuthCredentials) async throws -> String? {
        let encodedAccountID = percentEncodedPathSegment(credentials.accountID)
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/accounts/\(encodedAccountID)/settings")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")

        logInfo("Codex → GET /backend-api/accounts/<account>/settings (account: \(masked(credentials.accountID)))", log: networkLog)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexQuotaError.invalidResponse
        }

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            logDebug("Codex workspace settings unavailable: HTTP \(httpResponse.statusCode)", log: networkLog)
            return nil
        }

        return try decodeWorkspaceDisplayName(from: data)
    }

    func decodeWorkspaceDisplayName(from data: Data) throws -> String? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = try decoder.decode(CodexWorkspaceSettingsPayload.self, from: data)
        return trimmedLabel(payload.workspaceName) ??
            trimmedLabel(payload.displayName) ??
            trimmedLabel(payload.name) ??
            trimmedLabel(payload.publicDisplayName)
    }

    private func percentEncodedPathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.unicodeScalars
            .map { scalar in
                if allowed.contains(scalar) {
                    return String(scalar)
                }

                return String(scalar.utf8.map { String(format: "%%%02X", $0) }.joined())
            }
            .joined()
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

        let credentials = try latestAppManagedCredentialsIfAvailable(
            storageAccountID: appManagedAccountID,
            fallback: credentials
        )

        guard force || shouldRefresh(accessToken: credentials.accessToken) else {
            return credentials
        }

        guard let refreshToken = credentials.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return credentials
        }

        let response: CodexRefreshResponse
        do {
            response = try await requestTokenRefresh(refreshToken: refreshToken)
        } catch let error as CodexQuotaError where error.isRefreshTokenReuse {
            let latestCredentials = try latestAppManagedCredentialsIfAvailable(
                storageAccountID: appManagedAccountID,
                fallback: credentials
            )

            if latestCredentials.accessToken != credentials.accessToken ||
                latestCredentials.refreshToken != credentials.refreshToken {
                logInfo("[Codex] Recovered from reused refresh token using newer AgentBar credentials")
                return try await refreshAppManagedCredentialsIfNeeded(latestCredentials, force: force)
            }

            logInfo("[Codex] Refresh token was already used; trying the existing access token before requiring sign-in")
            return credentials
        }

        let updatedIDToken = response.idToken ?? credentials.idToken ?? ""
        let updatedAccessToken = response.accessToken ?? credentials.accessToken
        let updatedRefreshToken = response.refreshToken ?? refreshToken
        let updatedIdentity = CodexAppAuthStore.identity(from: updatedIDToken)
        let returnedAccountID = updatedIdentity?.accountID ?? credentials.accountID

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
        let spaceLabel = updatedIdentity?.spaceLabel ?? credentials.spaceLabel
        logInfo("[Codex] AgentBar credentials refreshed for account \(masked(credentials.accountID))")

        return CodexAuthCredentials(
            accessToken: updatedAccessToken,
            refreshToken: updatedRefreshToken,
            idToken: updatedIDToken,
            accountID: credentials.accountID,
            accountLabel: accountLabel,
            spaceLabel: spaceLabel,
            appManagedAccountID: appManagedAccountID
        )
    }

    private func shouldRefresh(accessToken: String) -> Bool {
        guard let expiresAt = jwtExpirationDate(accessToken) else {
            return false
        }

        return expiresAt <= Date().addingTimeInterval(60)
    }

    private func latestAppManagedCredentialsIfAvailable(
        storageAccountID: String,
        fallback: CodexAuthCredentials
    ) throws -> CodexAuthCredentials {
        guard let session = try CodexAppAuthStore.loadSession(accountID: storageAccountID) else {
            return fallback
        }

        let accessToken = session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            return fallback
        }

        return appManagedCredentials(from: session, storageAccountID: storageAccountID)
    }

    private func appManagedCredentials(
        from session: CodexStoredAuthSession,
        storageAccountID: String
    ) -> CodexAuthCredentials {
        let accountLabel = preferredAccountLabel(
            idToken: session.idToken,
            fallbackAccountID: session.accountID
        )
        let spaceLabel = preferredSpaceLabel(idToken: session.idToken)

        return CodexAuthCredentials(
            accessToken: session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
            refreshToken: session.refreshToken,
            idToken: session.idToken,
            accountID: session.accountID,
            accountLabel: accountLabel,
            spaceLabel: spaceLabel,
            appManagedAccountID: storageAccountID
        )
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
            if Self.isTokenRevokedResponse(body) {
                throw CodexQuotaError.tokenRevoked("The Codex OAuth token was revoked by another OpenAI app session.")
            }
            throw CodexQuotaError.refreshFailed("HTTP \(httpResponse.statusCode): \(body)")
        }

        return try JSONDecoder().decode(CodexRefreshResponse.self, from: data)
    }

    private static func isTokenRevokedResponse(_ body: String) -> Bool {
        body.localizedCaseInsensitiveContains("token_revoked") ||
            body.localizedCaseInsensitiveContains("token_invalidated") ||
            body.localizedCaseInsensitiveContains("invalidated oauth token") ||
            body.localizedCaseInsensitiveContains("authentication token has been invalidated")
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
    case missingStoredCredentials(String)
    case missingAccessToken
    case invalidResponse
    case httpStatus(Int, message: String)
    case noQuotaInResponse
    case refreshFailed(String)
    case tokenRevoked(String)

    public var errorDescription: String? {
        switch self {
        case .missingStoredCredentials:
            return "No AgentBar Codex browser login was found. Sign in from AgentBar settings."
        case .missingAccessToken:
            return "No Codex access token was found. Sign in from AgentBar settings."
        case .invalidResponse:
            return "The Codex usage API returned an invalid response."
        case let .httpStatus(code, message):
            return "The Codex usage API failed with HTTP \(code): \(message)"
        case .noQuotaInResponse:
            return "The Codex usage API response did not include 5-hour or weekly quota windows."
        case let .refreshFailed(message):
            return "Codex browser login refresh failed: \(message)"
        case .tokenRevoked:
            return "Codex login was revoked. Reconnect this account from AgentBar settings."
        }
    }
}

private struct CodexAuthCredentials: Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountID: String
    let accountLabel: String
    let spaceLabel: String?
    let appManagedAccountID: String?
}

private struct CodexWorkspaceSettingsPayload: Decodable {
    let workspaceName: String?
    let displayName: String?
    let name: String?
    let publicDisplayName: String?
}

private struct CodexUsagePayload: Decodable {
    let planType: String?
    let rateLimit: CodexUsageRateLimit?
    let codeReviewRateLimit: CodexUsageRateLimit?
    let additionalRateLimits: [CodexAdditionalRateLimit]?
    let credits: CodexCreditsSnapshot?
}

private struct CodexAdditionalRateLimit: Decodable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexUsageRateLimit?

    var displayLabel: String? {
        Self.clean(limitName) ?? Self.clean(meteredFeature).map(Self.formatDisplayToken)
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private static func formatDisplayToken(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                let lowercased = word.lowercased()
                if lowercased == "gpt" {
                    return lowercased.uppercased()
                }

                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")
    }
}

private struct CodexCreditsSnapshot: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?

    var hasQuotaState: Bool {
        hasCredits != nil || unlimited != nil || balance != nil
    }
}

private struct CodexUsageRateLimit: Decodable {
    let allowed: Bool?
    let limitReached: Bool?
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    func metrics(idPrefix: String? = nil, titlePrefix: String? = nil) -> [AgentQuotaMetric] {
        [
            primaryWindow?.metric(idPrefix: idPrefix, titlePrefix: titlePrefix),
            secondaryWindow?.metric(idPrefix: idPrefix, titlePrefix: titlePrefix)
        ].compactMap { $0 }
    }

    var hasQuotaState: Bool {
        allowed != nil || limitReached != nil || primaryWindow != nil || secondaryWindow != nil
    }
}

private struct CodexUsageWindow: Decodable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let windowDurationMins: Int?
    let resetAt: TimeInterval?
    let resetsAt: TimeInterval?

    func metric(idPrefix: String?, titlePrefix: String?) -> AgentQuotaMetric? {
        guard let usedPercent,
              let windowMinutes,
              let resetAt = resetAt ?? resetsAt,
              resetAt > 0 else {
            return nil
        }

        let windowTitle = Self.windowTitle(for: windowMinutes)
        let title = titlePrefix.map { "\($0) \(windowTitle)" } ?? windowTitle
        let id = idPrefix.map { "\($0)-window-\(windowMinutes)" } ?? "window-\(windowMinutes)"
        return AgentQuotaMetric(
            id: id,
            title: title,
            usedPercent: usedPercent,
            usedLabel: "\(Int(usedPercent.rounded()))% used",
            remainingLabel: "\(Int(max(0, 100 - usedPercent).rounded()))% left",
            resetsAt: Date(timeIntervalSince1970: resetAt)
        )
    }

    private var windowMinutes: Int? {
        if let limitWindowSeconds, limitWindowSeconds > 0 {
            return max(1, (limitWindowSeconds + 59) / 60)
        }

        if let windowDurationMins, windowDurationMins > 0 {
            return windowDurationMins
        }

        return nil
    }

    private static func windowTitle(for windowMinutes: Int) -> String {
        switch windowMinutes {
        case 60:
            return "1 hour window"
        case 300:
            return "5 hour window"
        case 1_440:
            return "24 hour window"
        case 10_080:
            return "7 day window"
        default:
            if windowMinutes % 1_440 == 0 {
                return "\(windowMinutes / 1_440) day window"
            }

            return "\(windowMinutes) minute window"
        }
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
        if case .tokenRevoked = self {
            return true
        }

        guard case let .httpStatus(code, _) = self else {
            return false
        }

        return code == 401 || code == 403
    }

    var isRefreshTokenReuse: Bool {
        guard case let .refreshFailed(message) = self else {
            return false
        }

        return message.contains("refresh_token_reused") ||
            message.localizedCaseInsensitiveContains("refresh token has already been used")
    }
}
