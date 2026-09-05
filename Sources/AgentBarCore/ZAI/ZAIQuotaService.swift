import Foundation
import os

// MARK: - Installation

public struct ZAIInstallation: Sendable {
    public let configDirectory: URL
    public let appManagedAccountID: String?

    public static let `default` = ZAIInstallation(
        configDirectory: AgentProviderAppAuthStore.accountsDirectory(for: .zai),
        appManagedAccountID: nil
    )

    public init(
        configDirectory: URL,
        appManagedAccountID: String? = nil
    ) {
        self.configDirectory = configDirectory
        self.appManagedAccountID = appManagedAccountID
    }

    public static func appManaged(accountID: String) -> ZAIInstallation {
        ZAIInstallation(
            configDirectory: AgentProviderAppAuthStore.accountDirectory(
                for: .zai,
                accountID: accountID
            ),
            appManagedAccountID: accountID
        )
    }
}

// MARK: - Service

public struct ZAIQuotaService: Sendable {
    public static let defaultMonitorBaseURL = URL(string: "https://api.z.ai")!
    public static let defaultAnthropicBaseURL = URL(string: "https://api.z.ai/api/anthropic")!
    public static let codingPlanUsagePageURL = URL(string: "https://z.ai/manage-apikey/coding-plan/personal/usage")!
    public static let baseURLScopePrefix = "baseURL="

    public let installation: ZAIInstallation

    public init(installation: ZAIInstallation = .default) {
        self.installation = installation
    }

    public var isAvailable: Bool {
        guard let accountID = installation.appManagedAccountID,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return AgentProviderAppAuthStore.hasSession(provider: .zai, accountID: accountID)
    }

    public func loadSnapshot() async throws -> AgentQuotaSnapshot {
        let installation = installation
        let session = try await Task.detached(priority: .userInitiated) {
            try loadSessionSynchronously(for: installation)
        }.value

        return try await fetchSnapshot(session: session)
    }

    /// Exposed for unit tests — skips Keychain reading and network access.
    public func decodeSnapshot(
        from data: Data,
        accountLabelFallback: String = "Z.ai Coding Plan",
        updatedAt: Date
    ) throws -> AgentQuotaSnapshot {
        try buildSnapshot(
            response: try decodeQuotaResponse(from: data),
            accountLabelFallback: accountLabelFallback,
            updatedAt: updatedAt
        )
    }

    public static func normalizedMonitorBaseURL(from rawValue: String?) throws -> URL {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            return defaultMonitorBaseURL
        }

        let valueWithScheme: String
        if trimmed.localizedCaseInsensitiveContains("://") {
            valueWithScheme = trimmed
        } else {
            valueWithScheme = "https://\(trimmed)"
        }

        guard let components = URLComponents(string: valueWithScheme),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              Self.isSupportedMonitorHost(host),
              let url = URL(string: "\(scheme)://\(host)") else {
            throw ZAIQuotaError.invalidBaseURL
        }

        return url
    }

    public static func baseURLScopeValue(from baseURL: URL) -> String {
        "\(baseURLScopePrefix)\(baseURL.absoluteString)"
    }

    public static func monitorBaseURL(from session: AgentProviderStoredAuthSession) -> URL {
        for scope in session.scopes {
            guard scope.hasPrefix(baseURLScopePrefix) else {
                continue
            }

            let value = String(scope.dropFirst(baseURLScopePrefix.count))
            if let url = try? normalizedMonitorBaseURL(from: value) {
                return url
            }
        }

        return defaultMonitorBaseURL
    }

    private func fetchSnapshot(session: AgentProviderStoredAuthSession) async throws -> AgentQuotaSnapshot {
        let token = session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ZAIQuotaError.missingCredentials
        }

        let baseURL = Self.monitorBaseURL(from: session)
        let url = baseURL.appending(path: "api/monitor/usage/quota/limit")
        var lastUnauthorizedBody: String?

        for authorizationHeader in authorizationHeaderCandidates(for: token) {
            var request = URLRequest(url: url)
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("en-US,en", forHTTPHeaderField: "Accept-Language")
            request.setValue("agent-bar", forHTTPHeaderField: "User-Agent")

            logInfo("Z.ai → GET \(url.absoluteString)", log: networkLog)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ZAIQuotaError.invalidResponse
            }

            logInfo("Z.ai ← HTTP \(httpResponse.statusCode)", log: networkLog)

            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "Request failed."
                logError("Z.ai API error \(httpResponse.statusCode): \(body)", log: networkLog)
                if httpResponse.statusCode == 401 {
                    lastUnauthorizedBody = body
                    continue
                }
                throw ZAIQuotaError.httpStatus(httpResponse.statusCode, message: body)
            }

            return try buildSnapshot(
                response: try decodeQuotaResponse(from: data),
                accountLabelFallback: session.accountLabel,
                updatedAt: Date()
            )
        }

        throw ZAIQuotaError.httpStatus(401, message: lastUnauthorizedBody ?? "Unauthorized.")
    }

    private func decodeQuotaResponse(from data: Data) throws -> ZAIQuotaEnvelope {
        do {
            return try JSONDecoder().decode(ZAIQuotaEnvelope.self, from: data)
        } catch {
            logError("Z.ai JSON decode failed: \(error) — body: \(String(data: data, encoding: .utf8) ?? "<non-UTF8>")", log: networkLog)
            throw error
        }
    }

    private func buildSnapshot(
        response: ZAIQuotaEnvelope,
        accountLabelFallback: String,
        updatedAt: Date
    ) throws -> AgentQuotaSnapshot {
        guard let data = response.data ?? response.asData,
              let limits = data.limits,
              !limits.isEmpty else {
            throw ZAIQuotaError.noQuotaInResponse
        }

        let metrics = limits.enumerated().compactMap { index, limit in
            metric(from: limit, index: index)
        }

        guard !metrics.isEmpty else {
            throw ZAIQuotaError.noQuotaInResponse
        }

        return AgentQuotaSnapshot(
            provider: .zai,
            accountLabel: cleanDisplayValue(data.accountLabel) ?? accountLabelFallback,
            planType: planLabel(from: data),
            modelName: nil,
            sourceSummary: "Z.ai Coding Plan API",
            metrics: metrics,
            updatedAt: updatedAt
        )
    }

    private func metric(from limit: ZAIQuotaLimit, index: Int) -> AgentQuotaMetric? {
        guard let rawType = cleanDisplayValue(limit.type) else {
            return nil
        }

        let usedPercent = min(max(limit.percentage ?? inferredUsedPercent(from: limit) ?? 0, 0), 100)
        let total = limit.totalValue
        let used = limit.usedValue(total: total)
        let remaining = limit.remainingValue(total: total, used: used)

        let usedLabel: String
        let remainingLabel: String
        if let total, total > 0 {
            if let used {
                usedLabel = "\(formatAmount(max(0, used)))/\(formatAmount(total)) used"
            } else {
                usedLabel = "\(formatPercent(usedPercent)) used"
            }

            if let remaining {
                remainingLabel = "\(formatAmount(max(0, remaining)))/\(formatAmount(total)) left"
            } else {
                remainingLabel = "\(formatPercent(max(0, 100 - usedPercent)) ) left"
            }
        } else {
            usedLabel = "\(formatPercent(usedPercent)) used"
            if let remaining {
                remainingLabel = "\(formatAmount(max(0, remaining))) left"
            } else {
                remainingLabel = "\(formatPercent(max(0, 100 - usedPercent))) left"
            }
        }

        return AgentQuotaMetric(
            id: metricID(type: rawType, unit: limit.unitNumber, number: limit.windowNumber, index: index),
            title: metricTitle(type: rawType, unit: limit.unitNumber, number: limit.windowNumber),
            usedPercent: usedPercent,
            usedLabel: usedLabel,
            remainingLabel: remainingLabel,
            resetsAt: resetDate(from: limit.nextResetTime)
        )
    }

    private func inferredUsedPercent(from limit: ZAIQuotaLimit) -> Double? {
        guard let total = limit.totalValue, total > 0 else {
            return nil
        }

        if let used = limit.usedValue(total: total) {
            return min(max((used / total) * 100, 0), 100)
        }

        if let remaining = limit.remaining {
            return min(max(((total - remaining) / total) * 100, 0), 100)
        }

        return nil
    }

    private func metricTitle(type: String, unit: Int?, number: Int?) -> String {
        let window = windowTitle(unit: unit, number: number)
        switch type.uppercased() {
        case "TOKENS_LIMIT":
            return ["Token usage", window].compactMap { $0 }.joined(separator: " ")
        case "TIME_LIMIT":
            return ["MCP usage", window].compactMap { $0 }.joined(separator: " ")
        default:
            return [formatDisplayToken(type), window].compactMap { $0 }.joined(separator: " ")
        }
    }

    private func windowTitle(unit: Int?, number: Int?) -> String? {
        guard let unit, let number else {
            return nil
        }

        switch unit {
        case 1:
            return "\(number) second window"
        case 2:
            return "\(number) minute window"
        case 3:
            return "\(number) hour window"
        case 4:
            return "\(number) day window"
        case 5:
            return "\(number) month window"
        case 6:
            let dayCount = number == 1 ? 7 : number
            return "\(dayCount) day window"
        default:
            return "\(number) unit \(unit) window"
        }
    }

    private func resetDate(from value: Double?) -> Date? {
        guard let value, value > 0 else {
            return nil
        }

        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private func metricID(type: String, unit: Int?, number: Int?, index: Int) -> String {
        let parts = [
            "zai",
            idComponent(type),
            unit.map { "u\($0)" },
            number.map { "n\($0)" },
            "i\(index)"
        ].compactMap { $0 }

        return parts.joined(separator: "-")
    }

    private func idComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1-$2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    private func planLabel(from data: ZAIQuotaData) -> String? {
        let raw = cleanDisplayValue(data.planName)
            ?? cleanDisplayValue(data.plan)
            ?? cleanDisplayValue(data.planType)
            ?? cleanDisplayValue(data.packageName)
            ?? cleanDisplayValue(data.level)

        return raw.map(formatDisplayToken)
    }

    private func formatAmount(_ value: Double) -> String {
        guard value.isFinite else {
            return "0"
        }

        let absValue = abs(value)
        if absValue >= 1_000_000_000 {
            return compactDecimal(value / 1_000_000_000, suffix: "B")
        }

        if absValue >= 1_000_000 {
            return compactDecimal(value / 1_000_000, suffix: "M")
        }

        if absValue >= 10_000 {
            return compactDecimal(value / 1_000, suffix: "K")
        }

        if value.rounded() == value {
            return String(Int(value))
        }

        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func compactDecimal(_ value: Double, suffix: String) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return "\(Int(rounded))\(suffix)"
        }

        return String(format: "%.1f%@", rounded, suffix)
    }

    private func formatPercent(_ value: Double) -> String {
        if value.rounded() == value {
            return "\(Int(value))%"
        }

        return String(format: "%.1f%%", value)
    }

    private func formatDisplayToken(_ value: String) -> String {
        let spaced = value
            .replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        return spaced
            .split(separator: " ")
            .map { word in
                let lowercased = word.lowercased()
                if ["api", "ai", "mcp", "glm"].contains(lowercased) {
                    return lowercased.uppercased()
                }

                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")
    }

    private func cleanDisplayValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }

        return trimmed
    }

    private func authorizationHeaderCandidates(for token: String) -> [String] {
        if token.range(of: "Bearer ", options: [.anchored, .caseInsensitive]) != nil {
            return [token]
        }

        return ["Bearer \(token)", token]
    }

    private func loadSessionSynchronously(for installation: ZAIInstallation) throws -> AgentProviderStoredAuthSession {
        guard let accountID = installation.appManagedAccountID else {
            throw ZAIQuotaError.missingAppLogin
        }

        guard let session = try AgentProviderAppAuthStore.loadSession(provider: .zai, accountID: accountID) else {
            throw ZAIQuotaError.missingAppLogin
        }

        return session
    }

    private static func isSupportedMonitorHost(_ host: String) -> Bool {
        host == "api.z.ai"
    }
}

// MARK: - Errors

enum ZAIQuotaError: LocalizedError, Equatable {
    case missingAppLogin
    case missingCredentials
    case invalidBaseURL
    case invalidResponse
    case httpStatus(Int, message: String)
    case noQuotaInResponse

    var errorDescription: String? {
        switch self {
        case .missingAppLogin:
            return "No AgentBar Z.ai Coding Plan credential was found. Add it from AgentBar settings."
        case .missingCredentials:
            return "The saved Z.ai Coding Plan credential is empty. Add the account again from AgentBar settings."
        case .invalidBaseURL:
            return "Only the international Z.ai host https://api.z.ai is supported."
        case .invalidResponse:
            return "Z.ai returned an invalid response."
        case let .httpStatus(status, message):
            return "Z.ai request failed with HTTP \(status): \(message)"
        case .noQuotaInResponse:
            return "Z.ai did not return any Coding Plan quota limits."
        }
    }
}

// MARK: - Decodable types

private struct ZAIQuotaEnvelope: Decodable {
    let data: ZAIQuotaData?
    let success: Bool?
    let code: FlexibleString?
    let msg: String?
    let limits: [ZAIQuotaLimit]?
    let level: String?
    let planName: String?

    var asData: ZAIQuotaData? {
        guard data == nil, limits != nil || level != nil || planName != nil else {
            return nil
        }

        return ZAIQuotaData(
            limits: limits,
            level: level,
            planName: planName,
            plan: nil,
            planType: nil,
            packageName: nil,
            email: nil,
            username: nil,
            account: nil,
            accountName: nil,
            userName: nil
        )
    }
}

private struct ZAIQuotaData: Decodable {
    let limits: [ZAIQuotaLimit]?
    let level: String?
    let planName: String?
    let plan: String?
    let planType: String?
    let packageName: String?
    let email: String?
    let username: String?
    let account: String?
    let accountName: String?
    let userName: String?

    var accountLabel: String? {
        email ?? username ?? userName ?? accountName ?? account
    }
}

private struct ZAIQuotaLimit: Decodable {
    let type: String?
    let unitNumber: Int?
    let windowNumber: Int?
    let usage: Double?
    let currentValue: Double?
    let remaining: Double?
    let percentage: Double?
    let nextResetTime: Double?
    let used: Double?
    let total: Double?
    let maximum: Double?
    let limit: Double?

    private enum CodingKeys: String, CodingKey {
        case type
        case unit
        case number
        case usage
        case currentValue
        case current_value
        case remaining
        case percentage
        case nextResetTime
        case next_reset_time
        case used
        case total
        case maximum
        case max
        case limit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        unitNumber = Self.decodeFlexibleInt(from: container, keys: [.unit])
        windowNumber = Self.decodeFlexibleInt(from: container, keys: [.number])
        usage = Self.decodeFlexibleDouble(from: container, keys: [.usage])
        currentValue = Self.decodeFlexibleDouble(from: container, keys: [.currentValue, .current_value])
        remaining = Self.decodeFlexibleDouble(from: container, keys: [.remaining])
        percentage = Self.decodeFlexibleDouble(from: container, keys: [.percentage])
        nextResetTime = Self.decodeFlexibleDouble(from: container, keys: [.nextResetTime, .next_reset_time])
        used = Self.decodeFlexibleDouble(from: container, keys: [.used])
        total = Self.decodeFlexibleDouble(from: container, keys: [.total])
        maximum = Self.decodeFlexibleDouble(from: container, keys: [.maximum, .max])
        limit = Self.decodeFlexibleDouble(from: container, keys: [.limit])
    }

    var totalValue: Double? {
        usage ?? total ?? maximum ?? limit
    }

    func usedValue(total: Double?) -> Double? {
        if let currentValue {
            return currentValue
        }

        if let used {
            return used
        }

        if let total, let remaining {
            return max(0, total - remaining)
        }

        return nil
    }

    func remainingValue(total: Double?, used: Double?) -> Double? {
        if let remaining {
            return remaining
        }

        if let total, let used {
            return max(0, total - used)
        }

        return nil
    }

    private static func decodeFlexibleInt(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        decodeFlexibleDouble(from: container, keys: keys).map { Int($0.rounded()) }
    }

    private static func decodeFlexibleDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Double? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }

            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }

            if let value = try? container.decodeIfPresent(String.self, forKey: key),
               let parsed = FlexibleString.parseDouble(value) {
                return parsed
            }
        }

        return nil
    }
}

private struct FlexibleString: Decodable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected string-like value.")
        }
    }

    static func parseDouble(_ value: String) -> Double? {
        let normalized = value
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(normalized)
    }
}
