import Foundation
import os

// MARK: - CLI Installation

struct GitHubCopilotCLIInstallation: Sendable {
    let configDirectory: URL

    static let `default` = GitHubCopilotCLIInstallation(
        configDirectory: URL(fileURLWithPath: NSString(string: "~/.config/github-copilot").expandingTildeInPath)
    )

    var appsFile: URL {
        configDirectory.appending(path: "apps.json")
    }
}

// MARK: - Service

struct GitHubCopilotQuotaService: Sendable {
    let installation: GitHubCopilotCLIInstallation

    init(installation: GitHubCopilotCLIInstallation = .default) {
        self.installation = installation
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: installation.appsFile.path)
    }

    func loadSnapshot() async throws -> AgentQuotaSnapshot {
        let installation = installation
        let credentials = try await Task.detached(priority: .userInitiated) {
            try loadCredentialsSynchronously(for: installation)
        }.value

        return try await fetchSnapshot(oauthToken: credentials.oauthToken)
    }

    /// Exposed for unit tests — skips credential file reading.
    func decodeSnapshot(from data: Data, updatedAt: Date) throws -> AgentQuotaSnapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let response = try decoder.decode(GitHubCopilotUserResponse.self, from: data)
            return buildSnapshot(from: response, updatedAt: updatedAt)
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

        return try decodeSnapshot(from: data, updatedAt: Date())
    }

    private func buildSnapshot(from response: GitHubCopilotUserResponse, updatedAt: Date) -> AgentQuotaSnapshot {
        let pi = response.quotaSnapshots?.premiumInteractions
        let resetsAt = parseResetDate(response.quotaResetDateUtc, fallback: updatedAt)

        let metric: AgentQuotaMetric
        if let pi, pi.unlimited == false, let entitlement = pi.entitlement, entitlement > 0 {
            let remaining = pi.remaining ?? 0
            let used = max(0, entitlement - remaining)
            metric = AgentQuotaMetric.cappedUsage(
                id: "github-copilot-premium-interactions",
                title: "Premium requests / month",
                used: used,
                limit: entitlement,
                resetsAt: resetsAt
            )
        } else {
            // Unlimited or no quota data — show unlimited
            metric = AgentQuotaMetric(
                id: "github-copilot-premium-interactions",
                title: "Premium requests / month",
                usedPercent: 0,
                usedLabel: "Unlimited",
                remainingLabel: "Unlimited",
                resetsAt: resetsAt
            )
        }

        return AgentQuotaSnapshot(
            provider: .githubCopilot,
            accountLabel: "@\(response.login ?? "unknown")",
            planType: response.copilotPlan,
            modelName: nil,
            sourceSummary: "GitHub Copilot API",
            metrics: [metric],
            updatedAt: updatedAt
        )
    }

    private func loadCredentialsSynchronously(for installation: GitHubCopilotCLIInstallation) throws -> GitHubCopilotCLICredentials {
        let appsFile = installation.appsFile
        guard FileManager.default.fileExists(atPath: appsFile.path) else {
            let msg = "GitHub Copilot apps.json not found at \(appsFile.path) — log in with a Copilot IDE extension first"
            logError(msg)
            throw GitHubCopilotQuotaError.missingCredentialsFile(appsFile.path)
        }

        let data: Data
        do {
            data = try Data(contentsOf: appsFile)
        } catch {
            logError("[Copilot] Cannot read apps.json: \(error)")
            throw error
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let entries: [String: GitHubCopilotCLIAppEntry]
        do {
            entries = try decoder.decode([String: GitHubCopilotCLIAppEntry].self, from: data)
        } catch {
            logError("[Copilot] apps.json decode failed: \(error)")
            throw error
        }

        guard let token = entries.values
            .compactMap({ $0.oauthToken?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else {
            logError("[Copilot] No valid oauth_token found in apps.json — try re-logging in to your Copilot IDE extension")
            throw GitHubCopilotQuotaError.missingCredentials
        }

        logDebug("[Copilot] Credentials loaded from \(appsFile.path)")
        return GitHubCopilotCLICredentials(oauthToken: token)
    }

    private func parseResetDate(_ dateString: String?, fallback: Date) -> Date {
        guard let dateString else { return nextUTCMonthBoundary(from: fallback) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: dateString)
            ?? ISO8601DateFormatter().date(from: dateString)
            ?? nextUTCMonthBoundary(from: fallback)
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
    case missingCredentialsFile(String)
    case missingCredentials
    case invalidResponse
    case httpStatus(Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .missingCredentialsFile(path):
            return "GitHub Copilot credentials not found at \(path). Log in via a Copilot IDE extension (e.g. VS Code, JetBrains)."
        case .missingCredentials:
            return "No valid OAuth token in ~/.config/github-copilot/apps.json. Re-log in via a Copilot IDE extension."
        case .invalidResponse:
            return "The GitHub Copilot API returned an invalid response."
        case let .httpStatus(code, message):
            return "GitHub Copilot API request failed with HTTP \(code): \(message)"
        }
    }
}

// MARK: - Private types

private struct GitHubCopilotCLIAppEntry: Decodable {
    let user: String?
    let oauthToken: String?
}

struct GitHubCopilotCLICredentials: Sendable {
    let oauthToken: String
}

private struct GitHubCopilotUserResponse: Decodable {
    let login: String?
    let copilotPlan: String?
    let quotaResetDateUtc: String?
    let quotaSnapshots: GitHubCopilotQuotaSnapshots?
}

private struct GitHubCopilotQuotaSnapshots: Decodable {
    let premiumInteractions: GitHubCopilotQuotaEntry?
}

private struct GitHubCopilotQuotaEntry: Decodable {
    let remaining: Int?
    let entitlement: Int?
    let percentRemaining: Double?
    let unlimited: Bool?
    let overageCount: Int?
}
