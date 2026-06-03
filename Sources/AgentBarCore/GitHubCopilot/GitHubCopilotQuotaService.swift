import Foundation
import os

// MARK: - CLI Installation

public struct GitHubCopilotCLIInstallation: Sendable {
    public let configDirectory: URL
    public let appManagedAccountID: String?

    public static let `default` = GitHubCopilotCLIInstallation(
        configDirectory: AgentProviderAppAuthStore.accountsDirectory(for: .githubCopilot),
        appManagedAccountID: nil
    )

    public init(
        configDirectory: URL,
        appManagedAccountID: String? = nil
    ) {
        self.configDirectory = configDirectory
        self.appManagedAccountID = appManagedAccountID
    }

    public static func appManaged(accountID: String) -> GitHubCopilotCLIInstallation {
        GitHubCopilotCLIInstallation(
            configDirectory: AgentProviderAppAuthStore.accountDirectory(
                for: .githubCopilot,
                accountID: accountID
            ),
            appManagedAccountID: accountID
        )
    }
}

// MARK: - Service

public struct GitHubCopilotQuotaService: Sendable {
    public let installation: GitHubCopilotCLIInstallation

    public init(installation: GitHubCopilotCLIInstallation = .default) {
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
        let credentials = try await Task.detached(priority: .userInitiated) {
            try loadCredentialsSynchronously(for: installation)
        }.value

        return try await fetchSnapshot(oauthToken: credentials.oauthToken)
    }

    /// Exposed for unit tests — skips credential file reading.
    public func decodeSnapshot(from data: Data, updatedAt: Date) throws -> AgentQuotaSnapshot {
        try decodeSnapshot(from: data, profile: nil, updatedAt: updatedAt)
    }

    private func decodeSnapshot(
        from data: Data,
        profile: GitHubUserProfileResponse?,
        updatedAt: Date
    ) throws -> AgentQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let response = try decoder.decode(GitHubCopilotUserResponse.self, from: data)
            return buildSnapshot(from: response, profile: profile, updatedAt: updatedAt)
        } catch {
            logError("GitHub Copilot JSON decode failed: \(error) — body: \(String(data: data, encoding: .utf8) ?? "<non-UTF8>")", log: networkLog)
            throw error
        }
    }

    // MARK: Private

    private func fetchSnapshot(oauthToken: String) async throws -> AgentQuotaSnapshot {
        let url = URL(string: "https://api.github.com/copilot_internal/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("agent-bar", forHTTPHeaderField: "User-Agent")

        logInfo("GitHub Copilot → GET \(url.absoluteString)", log: networkLog)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubCopilotQuotaError.invalidResponse
        }

        logInfo("GitHub Copilot ← HTTP \(httpResponse.statusCode)", log: networkLog)
        logInfo("GitHub Copilot raw response: \(String(data: data, encoding: .utf8) ?? "<non-UTF8>")", log: networkLog)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Request failed."
            logError("GitHub Copilot API error \(httpResponse.statusCode): \(body)", log: networkLog)
            throw GitHubCopilotQuotaError.httpStatus(httpResponse.statusCode, message: body)
        }

        let profile = await loadGitHubUserProfile(oauthToken: oauthToken)
        return try decodeSnapshot(from: data, profile: profile, updatedAt: Date())
    }

    private func loadGitHubUserProfile(oauthToken: String) async -> GitHubUserProfileResponse? {
        do {
            let profile = try await fetchGitHubUserProfile(oauthToken: oauthToken)
            let primaryEmail = try? await fetchPrimaryGitHubEmail(oauthToken: oauthToken)
            return GitHubUserProfileResponse(
                login: profile.login,
                email: primaryEmail ?? profile.email,
                name: profile.name
            )
        } catch {
            logDebug("[Copilot] GitHub profile lookup skipped: \(error)")
            return nil
        }
    }

    private func fetchGitHubUserProfile(oauthToken: String) async throws -> GitHubUserProfileResponse {
        let url = URL(string: "https://api.github.com/user")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("agent-bar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw GitHubCopilotQuotaError.invalidResponse
        }

        return try JSONDecoder().decode(GitHubUserProfileResponse.self, from: data)
    }

    private func fetchPrimaryGitHubEmail(oauthToken: String) async throws -> String? {
        let url = URL(string: "https://api.github.com/user/emails")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(oauthToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("agent-bar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw GitHubCopilotQuotaError.invalidResponse
        }

        let emails = try JSONDecoder().decode([GitHubEmailResponse].self, from: data)
        return emails
            .filter { $0.verified == true }
            .sorted { lhs, rhs in
                (lhs.primary == true ? 0 : 1) < (rhs.primary == true ? 0 : 1)
            }
            .compactMap { Self.cleanDisplayValue($0.email) }
            .first
    }

    private func buildSnapshot(
        from response: GitHubCopilotUserResponse,
        profile: GitHubUserProfileResponse?,
        updatedAt: Date
    ) -> AgentQuotaSnapshot {
        let resetsAt = parseResetDate(response.quotaResetDateUtc, fallback: updatedAt)

        let metrics = response.quotaSnapshots?.metrics(resetsAt: resetsAt) ?? []
        let visibleMetrics: [AgentQuotaMetric]
        if metrics.isEmpty {
            // Unlimited or no quota data — show unlimited
            visibleMetrics = [AgentQuotaMetric(
                id: "github-copilot-premium-interactions",
                title: "Premium requests / month",
                usedPercent: 0,
                usedLabel: "Unlimited",
                remainingLabel: "Unlimited",
                resetsAt: resetsAt
            )]
        } else {
            visibleMetrics = metrics
        }

        return AgentQuotaSnapshot(
            provider: .githubCopilot,
            accountLabel: Self.preferredAccountLabel(
                email: profile?.email ?? response.email,
                name: profile?.name ?? response.name,
                login: profile?.login ?? response.login
            ),
            planType: response.copilotPlan,
            modelName: nil,
            sourceSummary: "GitHub Copilot API",
            metrics: visibleMetrics,
            updatedAt: updatedAt
        )
    }

    private func loadCredentialsSynchronously(for installation: GitHubCopilotCLIInstallation) throws -> GitHubCopilotCLICredentials {
        if let accountID = installation.appManagedAccountID {
            guard let session = try AgentProviderAppAuthStore.loadSession(
                provider: .githubCopilot,
                accountID: accountID
            ) else {
                throw GitHubCopilotQuotaError.missingAppLogin
            }

            let token = session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw GitHubCopilotQuotaError.missingCredentials
            }

            logDebug("[Copilot] AgentBar credentials loaded for \(session.accountLabel)")
            return GitHubCopilotCLICredentials(oauthToken: token)
        }

        throw GitHubCopilotQuotaError.missingAppLogin
    }

    private func parseResetDate(_ dateString: String?, fallback: Date) -> Date {
        guard let dateString else { return nextUTCMonthBoundary(from: fallback) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString)
            ?? ISO8601DateFormatter().date(from: dateString)
            ?? nextUTCMonthBoundary(from: fallback)
    }

    private static func preferredAccountLabel(email: String?, name: String?, login: String?) -> String {
        if let email = cleanDisplayValue(email) {
            return email
        }

        if let name = cleanDisplayValue(name) {
            return name
        }

        if let login = cleanDisplayValue(login) {
            return "@\(login)"
        }

        return "GitHub Account"
    }

    private static func cleanDisplayValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private func nextUTCMonthBoundary(from date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents([.year, .month], from: date)
        var next = DateComponents()
        next.timeZone = .gmt
        next.year = components.year
        next.month = (components.month ?? 1) + 1
        next.day = 1
        return calendar.date(from: next) ?? date
    }
}

// MARK: - Errors

enum GitHubCopilotQuotaError: LocalizedError {
    case missingAppLogin
    case missingCredentials
    case invalidResponse
    case httpStatus(Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAppLogin:
            return "No AgentBar GitHub Copilot browser login was found. Sign in from AgentBar settings."
        case .missingCredentials:
            return "No valid GitHub Copilot OAuth token was found. Sign in from AgentBar settings."
        case .invalidResponse:
            return "The GitHub Copilot API returned an invalid response."
        case let .httpStatus(code, message):
            return "GitHub Copilot API request failed with HTTP \(code): \(message)"
        }
    }
}

// MARK: - Private types

struct GitHubCopilotCLICredentials: Sendable {
    let oauthToken: String
}

private struct GitHubCopilotUserResponse: Decodable {
    let login: String?
    let email: String?
    let name: String?
    let copilotPlan: String?
    let quotaResetDateUtc: String?
    let quotaSnapshots: GitHubCopilotQuotaSnapshots?
}

private struct GitHubUserProfileResponse: Decodable {
    let login: String?
    let email: String?
    let name: String?
}

private struct GitHubEmailResponse: Decodable {
    let email: String?
    let primary: Bool?
    let verified: Bool?
}

private struct GitHubCopilotQuotaSnapshots: Decodable {
    let entries: [(key: String, value: GitHubCopilotQuotaEntry)]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        entries = try container.allKeys.map { key in
            (key.stringValue, try container.decode(GitHubCopilotQuotaEntry.self, forKey: key))
        }
        .sorted { lhs, rhs in
            let leftOrder = Self.displayOrder(for: lhs.key)
            let rightOrder = Self.displayOrder(for: rhs.key)
            if leftOrder != rightOrder {
                return leftOrder < rightOrder
            }

            return lhs.key < rhs.key
        }
    }

    func metrics(resetsAt: Date) -> [AgentQuotaMetric] {
        entries.compactMap { key, entry in
            metric(
                id: "github-copilot-\(Self.idSuffix(for: key))",
                title: Self.title(for: key),
                from: entry,
                resetsAt: resetsAt
            )
        }
    }

    private func metric(
        id: String,
        title: String,
        from entry: GitHubCopilotQuotaEntry,
        resetsAt: Date
    ) -> AgentQuotaMetric? {
        guard let entitlement = entry.entitlement, entitlement > 0 else {
            return nil
        }

        let remaining = normalizedRemaining(from: entry, entitlement: entitlement)
        let used = max(0, entitlement - remaining)
        return AgentQuotaMetric.cappedUsage(
            id: id,
            title: title,
            used: used,
            limit: entitlement,
            resetsAt: resetsAt
        )
    }

    private func normalizedRemaining(
        from entry: GitHubCopilotQuotaEntry,
        entitlement: Int
    ) -> Int {
        if let remaining = entry.remaining {
            return min(max(remaining, 0), entitlement)
        }

        if let quotaRemaining = entry.quotaRemaining {
            return min(max(Int(quotaRemaining.rounded()), 0), entitlement)
        }

        if let percentRemaining = entry.percentRemaining {
            let clampedPercent = min(max(percentRemaining, 0), 100)
            let estimated = (Double(entitlement) * clampedPercent / 100).rounded()
            return min(max(Int(estimated), 0), entitlement)
        }

        return 0
    }

    private static func displayOrder(for key: String) -> Int {
        switch key {
        case "chat":
            return 0
        case "completions":
            return 1
        case "premium_interactions", "premiumInteractions":
            return 2
        default:
            return 100
        }
    }

    private static func title(for key: String) -> String {
        switch key {
        case "chat":
            return "Chat messages / month"
        case "completions":
            return "Code completions / month"
        case "premium_interactions", "premiumInteractions":
            return "Premium requests / month"
        default:
            return "\(formatDisplayToken(key)) / month"
        }
    }

    private static func idSuffix(for key: String) -> String {
        key
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1-$2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
    }

    private static func formatDisplayToken(_ value: String) -> String {
        let spaced = value
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        return spaced
            .split(separator: " ")
            .map { word in
                let lowercased = word.lowercased()
                if ["api", "cli", "ide"].contains(lowercased) {
                    return lowercased.uppercased()
                }

                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct GitHubCopilotQuotaEntry: Decodable {
    let remaining: Int?
    let entitlement: Int?
    let quotaRemaining: Double?
    let percentRemaining: Double?
    let unlimited: Bool?
    let overageCount: Int?
}
