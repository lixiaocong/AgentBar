import Foundation

/// Public OAuth client metadata for Claude Code's sign-in flow.
///
/// Claude Code is a public OAuth client: it uses PKCE and has no client secret,
/// so the identifier below is safe to keep in source. Never pair it with a
/// secret, and never store issued tokens anywhere but the Keychain.
public enum ClaudeOAuthConfiguration {
    public static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    /// Sign-in is hosted by the Claude platform, while the account, profile and
    /// usage endpoints live on the Anthropic API host.
    public static let platformIssuer = URL(string: "https://platform.claude.com")!
    public static let apiIssuer = URL(string: "https://api.anthropic.com")!

    /// `user:profile` is required to resolve the signed-in account. `user:inference`
    /// is what the usage endpoint scopes its rate-limit windows to; without it the
    /// response omits the windows AgentBar renders.
    public static let scopes = ["user:profile", "user:inference"]

    /// Claude Code listens on 54545 during sign-in. AgentBar prefers a different
    /// port so a concurrent `claude login` cannot capture AgentBar's callback,
    /// and falls back only if the first port is taken.
    public static let callbackPorts: [UInt16] = [54546, 54547]
    public static let callbackPath = "/callback"

    /// Anthropic gates OAuth-token API access behind this beta flag; Claude Code
    /// sends it on every call made with an OAuth access token.
    public static let betaHeaderValue = "oauth-2025-04-20"

    public static var authorizationURL: URL {
        platformIssuer.appending(path: "oauth/authorize")
    }

    public static var tokenURL: URL {
        platformIssuer.appending(path: "v1/oauth/token")
    }

    public static var profileURL: URL {
        apiIssuer.appending(path: "api/oauth/profile")
    }

    public static var usageURL: URL {
        apiIssuer.appending(path: "api/oauth/usage")
    }

    public static func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)\(callbackPath)"
    }
}

// MARK: - Profile

/// Subset of `GET /api/oauth/profile` that AgentBar displays.
public struct ClaudeOAuthProfile: Sendable, Equatable {
    public let accountID: String?
    public let emailAddress: String?
    public let displayName: String?
    public let organizationName: String?
    public let subscriptionType: String?

    public init(
        accountID: String?,
        emailAddress: String?,
        displayName: String?,
        organizationName: String?,
        subscriptionType: String?
    ) {
        self.accountID = accountID
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
    }

    /// The profile payload nests account and organization objects and has used
    /// both snake_case and camelCase spellings across Claude Code releases, so
    /// decoding stays tolerant instead of relying on one fixed shape.
    public static func decode(from data: Data) throws -> ClaudeOAuthProfile {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeOAuthError.invalidProfileResponse
        }

        let account = root["account"] as? [String: Any]
        let organization = root["organization"] as? [String: Any]

        return ClaudeOAuthProfile(
            accountID: string(in: account, keys: ["uuid", "id"]) ?? string(in: root, keys: ["account_uuid", "accountUuid"]),
            emailAddress: string(in: account, keys: ["email_address", "emailAddress", "email"])
                ?? string(in: root, keys: ["email_address", "emailAddress", "email"]),
            displayName: string(in: account, keys: ["display_name", "displayName", "full_name", "name"])
                ?? string(in: root, keys: ["display_name", "displayName"]),
            organizationName: string(in: organization, keys: ["name", "organization_name", "organizationName"]),
            subscriptionType: string(in: root, keys: ["subscription_type", "subscriptionType"])
                ?? string(in: organization, keys: ["subscription_type", "subscriptionType"])
        )
    }

    /// Preferred label for the account row, mirroring how the other providers
    /// prefer an email address over a display name.
    public var preferredAccountLabel: String {
        emailAddress ?? displayName ?? organizationName ?? "Claude Account"
    }

    /// Turns `claude_max` into `Claude Max` so the plan reads like the other providers.
    public var planLabel: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else {
            return nil
        }

        return subscriptionType
            .split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func string(in object: [String: Any]?, keys: [String]) -> String? {
        guard let object else { return nil }

        for key in keys {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }
}

// MARK: - Usage windows

/// One rate-limit window from `GET /api/oauth/usage`.
public struct ClaudeUsageWindow: Sendable, Equatable {
    public let key: String
    public let utilization: Double
    public let resetsAt: Date?

    public init(key: String, utilization: Double, resetsAt: Date?) {
        self.key = key
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public enum ClaudeUsageResponse {
    /// Windows are returned as top-level objects keyed by window name
    /// (`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, …).
    /// Anthropic adds windows over time, so every top-level object carrying a
    /// `utilization` value is accepted rather than matching a fixed key list.
    public static func decodeWindows(from data: Data) throws -> [ClaudeUsageWindow] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeOAuthError.invalidUsageResponse
        }

        var windows: [ClaudeUsageWindow] = []

        for key in root.keys.sorted() {
            guard let object = root[key] as? [String: Any],
                  let utilization = number(in: object, keys: ["utilization"]) else {
                continue
            }

            // A window that the account is not entitled to reports itself disabled.
            if let isEnabled = object["is_enabled"] as? Bool, !isEnabled {
                continue
            }

            windows.append(
                ClaudeUsageWindow(
                    key: key,
                    utilization: min(max(utilization, 0), 100),
                    resetsAt: date(in: object, keys: ["resets_at", "resetsAt"])
                )
            )
        }

        return windows.sorted { sortRank(for: $0.key) < sortRank(for: $1.key) }
    }

    /// Human-readable window titles. Unknown keys are humanized so a newly added
    /// window still renders sensibly instead of being dropped.
    public static func title(for key: String) -> String {
        switch key {
        case "five_hour":
            return "Session (5h)"
        case "seven_day":
            return "Weekly (all models)"
        case "seven_day_opus":
            return "Weekly (Opus)"
        case "seven_day_sonnet":
            return "Weekly (Sonnet)"
        default:
            return key
                .split(separator: "_")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    private static func sortRank(for key: String) -> Int {
        switch key {
        case "five_hour":
            return 0
        case "seven_day":
            return 1
        case "seven_day_opus":
            return 2
        case "seven_day_sonnet":
            return 3
        default:
            return 4
        }
    }

    private static func number(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? Double {
                return value
            }
            if let value = object[key] as? Int {
                return Double(value)
            }
            if let value = object[key] as? String, let parsed = Double(value) {
                return parsed
            }
        }

        return nil
    }

    private static func date(in object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let seconds = object[key] as? Double {
                return Date(timeIntervalSince1970: seconds)
            }
            if let seconds = object[key] as? Int {
                return Date(timeIntervalSince1970: TimeInterval(seconds))
            }
            guard let raw = object[key] as? String else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if let parsed = date(fromISO8601: trimmed) {
                return parsed
            }
            if let seconds = Double(trimmed) {
                return Date(timeIntervalSince1970: seconds)
            }
        }

        return nil
    }

    private static func date(fromISO8601 value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let standardFormatter = ISO8601DateFormatter()
        standardFormatter.formatOptions = [.withInternetDateTime]
        return standardFormatter.date(from: value)
    }
}

// MARK: - Errors

public enum ClaudeOAuthError: LocalizedError, Equatable {
    case invalidProfileResponse
    case invalidUsageResponse
    case missingAccountID
    case refreshFailed(String)
    case tokenRevoked(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProfileResponse:
            return "Claude returned an unreadable account profile."
        case .invalidUsageResponse:
            return "Claude returned an unreadable usage response."
        case .missingAccountID:
            return "Claude sign-in did not return an account id."
        case let .refreshFailed(message):
            return "Claude token refresh failed: \(message)"
        case let .tokenRevoked(message):
            return message
        }
    }
}
