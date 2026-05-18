import Foundation
import os

public struct JunieInstallation: Sendable {
    public let configDirectory: URL
    public let appManagedAccountID: String?

    public static let `default` = JunieInstallation(
        configDirectory: AgentProviderAppAuthStore.accountsDirectory(for: .junie),
        appManagedAccountID: nil
    )

    public init(
        configDirectory: URL,
        appManagedAccountID: String? = nil
    ) {
        self.configDirectory = configDirectory
        self.appManagedAccountID = appManagedAccountID
    }

    public static func appManaged(accountID: String) -> JunieInstallation {
        JunieInstallation(
            configDirectory: AgentProviderAppAuthStore.accountDirectory(
                for: .junie,
                accountID: accountID
            ),
            appManagedAccountID: accountID
        )
    }
}

public struct JunieQuotaService: Sendable {
    public let installation: JunieInstallation
    private let endpointURL: URL
    private let quotaEndpointURL: URL?
    private let quotaCacheFiles: [URL]

    public init(
        installation: JunieInstallation = .default,
        endpointURL: URL = URL(string: "https://ingrazzio-cloud-prod.labs.jb.gg/auth/test")!,
        quotaEndpointURL: URL? = nil,
        quotaCacheFiles: [URL]? = nil
    ) {
        self.installation = installation
        self.endpointURL = endpointURL
        self.quotaEndpointURL = quotaEndpointURL
        self.quotaCacheFiles = quotaCacheFiles ?? Self.defaultAIAssistantQuotaCacheFiles()
    }

    public var isAvailable: Bool {
        guard let accountID = installation.appManagedAccountID,
              !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return AgentProviderAppAuthStore.hasSession(provider: .junie, accountID: accountID)
    }

    public func loadSnapshot() async throws -> AgentQuotaSnapshot {
        let installation = installation
        let session = try await Task.detached(priority: .userInitiated) {
            try loadSessionSynchronously(for: installation)
        }.value

        return try await fetchSnapshot(session: session)
    }

    public func decodeSnapshot(
        from data: Data,
        quotaData: Data? = nil,
        accountLabelFallback: String = "Junie",
        updatedAt: Date
    ) throws -> AgentQuotaSnapshot {
        let response = try JSONDecoder().decode(JunieAuthInfoResponse.self, from: data)
        let quotaDetails = try quotaData.flatMap { try decodeQuotaDetails(from: $0) }
            ?? cachedQuotaDetails(for: response)
        return buildSnapshot(
            from: response,
            quotaDetails: quotaDetails,
            accountLabelFallback: accountLabelFallback,
            updatedAt: updatedAt
        )
    }

    private func fetchSnapshot(session: AgentProviderStoredAuthSession) async throws -> AgentQuotaSnapshot {
        let token = session.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw JunieQuotaError.missingCredentials
        }

        let request = makeAuthorizedRequest(url: endpointURL, method: "GET", token: token)

        logInfo("Junie → GET \(endpointURL.absoluteString)", log: networkLog)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JunieQuotaError.invalidResponse
        }

        logInfo("Junie ← HTTP \(httpResponse.statusCode)", log: networkLog)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "Request failed."
            logError("Junie API error \(httpResponse.statusCode): \(body)", log: networkLog)
            throw JunieQuotaError.httpStatus(httpResponse.statusCode, message: body)
        }

        let authInfo = try JSONDecoder().decode(JunieAuthInfoResponse.self, from: data)
        let quotaDetails = await fetchQuota(token: token) ?? cachedQuotaDetails(for: authInfo)

        return buildSnapshot(
            from: authInfo,
            quotaDetails: quotaDetails,
            accountLabelFallback: session.accountLabel,
            updatedAt: Date()
        )
    }

    private func fetchQuota(token: String) async -> JunieQuotaDetails? {
        guard let quotaEndpointURL else {
            return nil
        }

        var request = makeAuthorizedRequest(url: quotaEndpointURL, method: "POST", token: token)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        do {
            logInfo("Junie → POST \(quotaEndpointURL.absoluteString)", log: networkLog)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                logError("Junie quota response was invalid.", log: networkLog)
                return nil
            }

            logInfo("Junie quota ← HTTP \(httpResponse.statusCode)", log: networkLog)
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "Request failed."
                logError("Junie quota API error \(httpResponse.statusCode): \(body)", log: networkLog)
                return nil
            }

            return try decodeQuotaDetails(from: data)
        } catch {
            logError("Junie quota unavailable: \(error.localizedDescription)", log: networkLog)
            return nil
        }
    }

    private func makeAuthorizedRequest(url: URL, method: String, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(authorizationHeaderValue(for: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("true", forHTTPHeaderField: "X-Accept-EAP-License")
        request.setValue("true", forHTTPHeaderField: "X-Accept-Release-License")
        request.setValue("agent-bar", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func buildSnapshot(
        from response: JunieAuthInfoResponse,
        quotaDetails: JunieQuotaDetails?,
        accountLabelFallback: String,
        updatedAt: Date
    ) -> AgentQuotaSnapshot {
        let accountLabel = cleanDisplayValue(response.username) ?? accountLabelFallback
        let planType = planLabel(from: response, quotaDetails: quotaDetails)
        let balance = balanceLabel(from: response, quotaDetails: quotaDetails)
        let metrics = subscriptionMetrics(from: response, quotaDetails: quotaDetails)

        return AgentQuotaSnapshot(
            provider: .junie,
            accountLabel: accountLabel,
            planType: planType,
            modelName: nil,
            sourceSummary: sourceSummary(
                active: response.active,
                planType: planType,
                balance: balance
            ),
            metrics: metrics,
            updatedAt: updatedAt
        )
    }

    private func sourceSummary(active: Bool?, planType: String?, balance: String?) -> String {
        var parts: [String] = []
        if active == false {
            parts.append("Inactive")
        } else {
            parts.append("Active")
        }

        if let balance {
            parts.append(balance)
        } else if let planType {
            parts.append(planType)
        }

        return parts.joined(separator: " · ")
    }

    private func planLabel(from response: JunieAuthInfoResponse, quotaDetails: JunieQuotaDetails?) -> String? {
        guard let licenseType = cleanDisplayValue(response.licenseType) else {
            return nil
        }

        return planTierLabel(from: licenseType)
    }

    private func balanceLabel(from response: JunieAuthInfoResponse, quotaDetails: JunieQuotaDetails?) -> String? {
        guard let balanceLeft = normalizedBalanceLeft(from: response, quotaDetails: quotaDetails) else {
            return nil
        }
        let total = normalizedQuotaTotal(from: response, quotaDetails: quotaDetails, normalizedLeft: balanceLeft)

        if isMonthlyCreditsPlan(response: response, quotaDetails: quotaDetails) {
            return remainingMonthlyCreditsLabel(left: balanceLeft, total: total)
        }

        if quotaDetails?.quota != nil || total != nil || isDollarLikeUnit(response.balanceUnit) {
            return remainingCurrencyLabel(left: balanceLeft, total: total)
        }

        let unit = cleanDisplayValue(response.balanceUnit).map(formatDisplayToken)
        if let unit {
            return "\(formatNumber(balanceLeft)) \(unit) left"
        }

        return "\(formatNumber(balanceLeft)) left"
    }

    private func subscriptionMetrics(from response: JunieAuthInfoResponse, quotaDetails: JunieQuotaDetails?) -> [AgentQuotaMetric] {
        guard let metric = subscriptionMetric(from: response, quotaDetails: quotaDetails) else {
            return []
        }

        return [metric]
    }

    private func subscriptionMetric(from response: JunieAuthInfoResponse, quotaDetails: JunieQuotaDetails?) -> AgentQuotaMetric? {
        guard let left = normalizedBalanceLeft(from: response, quotaDetails: quotaDetails),
              let total = normalizedQuotaTotal(from: response, quotaDetails: quotaDetails, normalizedLeft: left),
              total > 0 else {
            return nil
        }

        let cappedLeft = min(max(left, 0), total)
        let used = max(0, total - cappedLeft)
        let usedPercent = min(max((used / total) * 100, 0), 100)
        let isMonthlyCredits = isMonthlyCreditsPlan(response: response, quotaDetails: quotaDetails)

        return AgentQuotaMetric(
            id: "junie-subscription-quota",
            title: isMonthlyCredits ? "Monthly credits" : "Subscription quota",
            usedPercent: usedPercent,
            usedLabel: isMonthlyCredits ? "\(formatCreditAmount(used)) used" : "\(formatCurrency(used)) used",
            remainingLabel: isMonthlyCredits
                ? remainingMonthlyCreditsLabel(left: max(left, 0), total: total)
                : remainingCurrencyLabel(left: max(left, 0), total: total),
            resetsAt: quotaDetails?.resetsAt
        )
    }

    private func normalizedBalanceLeft(from response: JunieAuthInfoResponse, quotaDetails: JunieQuotaDetails?) -> Double? {
        (quotaDetails?.quota.current?.value ?? response.balanceLeft).map(normalizedCurrencyAmount)
    }

    private func normalizedQuotaTotal(
        from response: JunieAuthInfoResponse,
        quotaDetails: JunieQuotaDetails?,
        normalizedLeft: Double
    ) -> Double? {
        if let quotaTotal = quotaDetails?.quota.maximum?.value {
            return normalizedCurrencyAmount(quotaTotal)
        }

        if let responseTotal = response.totalQuota {
            return normalizedCurrencyAmount(responseTotal)
        }

        return inferredSubscriptionTotal(from: response, normalizedLeft: normalizedLeft)
    }

    private func normalizedCurrencyAmount(_ value: Double) -> Double {
        guard value.isFinite else {
            return value
        }

        // Junie API-key auth returns balances in 1/100000 dollar units.
        // Example: 647454 means $6.47454, not $647454.
        if abs(value) >= 10_000 {
            return value / 100_000
        }

        return value
    }

    private func inferredSubscriptionTotal(from response: JunieAuthInfoResponse, normalizedLeft: Double) -> Double? {
        if let licenseType = cleanDisplayValue(response.licenseType)?.lowercased() {
            guard licenseType.contains("junie") || licenseType == "aip",
                  !licenseType.contains("enterprise"),
                  !licenseType.contains("business"),
                  !licenseType.contains("team") else {
                return nil
            }

            return max(10, normalizedLeft)
        }

        if let authType = cleanDisplayValue(response.authType)?.lowercased(),
           authType.contains("api") {
            return max(10, normalizedLeft)
        }

        return nil
    }

    private func remainingCurrencyLabel(left: Double, total: Double?) -> String {
        guard let total, total > 0 else {
            return "\(formatCurrency(max(left, 0))) left"
        }

        return "\(formatCurrency(max(left, 0))) / \(formatCurrency(total)) left"
    }

    private func remainingMonthlyCreditsLabel(left: Double, total: Double?) -> String {
        guard let total, total > 0 else {
            return "\(formatCreditAmount(max(left, 0))) monthly credits left"
        }

        return "\(formatCreditAmount(max(left, 0))) / \(formatCreditAmount(total)) monthly credits left"
    }

    private func isMonthlyCreditsPlan(response: JunieAuthInfoResponse, quotaDetails: JunieQuotaDetails?) -> Bool {
        if quotaDetails?.source == .aiAssistantCache {
            return true
        }

        guard let licenseType = cleanDisplayValue(response.licenseType)?.lowercased() else {
            return false
        }

        return licenseType == "aip" || licenseType.contains("ai pro")
    }

    private func isDollarLikeUnit(_ value: String?) -> Bool {
        guard let unit = cleanDisplayValue(value)?.lowercased() else {
            return false
        }

        return ["credit", "credits", "usd", "dollar", "dollars"].contains(unit)
    }

    private func formatCurrency(_ value: Double) -> String {
        if value.rounded() == value {
            return "$\(Int(value))"
        }

        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    private func formatCreditAmount(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func formatNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }

        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func formatDisplayToken(_ value: String) -> String {
        if value.caseInsensitiveCompare("aip") == .orderedSame {
            return "Pro"
        }

        return value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                let lowercased = word.lowercased()
                if ["api", "byok", "jba"].contains(lowercased) {
                    return lowercased.uppercased()
                }
                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined(separator: " ")
    }

    private func planTierLabel(from licenseType: String) -> String {
        let formatted = formatDisplayToken(licenseType)
        let prefix = "Junie "
        if formatted.lowercased().hasPrefix(prefix.lowercased()) {
            let start = formatted.index(formatted.startIndex, offsetBy: prefix.count)
            return String(formatted[start...])
        }

        return formatted
    }

    private func cleanDisplayValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame else {
            return nil
        }

        return trimmed
    }

    private func authorizationHeaderValue(for token: String) -> String {
        token.range(of: "Bearer ", options: [.anchored, .caseInsensitive]) == nil
            ? "Bearer \(token)"
            : token
    }

    private func loadSessionSynchronously(for installation: JunieInstallation) throws -> AgentProviderStoredAuthSession {
        guard let accountID = installation.appManagedAccountID else {
            throw JunieQuotaError.missingAppLogin
        }

        guard let session = try AgentProviderAppAuthStore.loadSession(provider: .junie, accountID: accountID) else {
            throw JunieQuotaError.missingAppLogin
        }

        return session
    }

    private func decodeQuotaDetails(from data: Data) throws -> JunieQuotaDetails? {
        let response = try JSONDecoder().decode(JunieQuotaGetResponse.self, from: data)
        return response.current.map { JunieQuotaDetails(quota: $0, resetsAt: nil, source: .quotaEndpoint) }
    }

    private func cachedQuotaDetails(for response: JunieAuthInfoResponse) -> JunieQuotaDetails? {
        guard isAIPLicense(response.licenseType) else {
            return nil
        }

        return Self.loadCachedAIAssistantQuotaDetails(from: quotaCacheFiles)
    }

    private func isAIPLicense(_ value: String?) -> Bool {
        guard let licenseType = cleanDisplayValue(value)?.lowercased() else {
            return false
        }

        return licenseType == "aip" || licenseType.contains("ai pro")
    }

    private static func defaultAIAssistantQuotaCacheFiles() -> [URL] {
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return []
        }

        let jetBrainsDirectory = applicationSupportDirectory
            .appending(path: "JetBrains", directoryHint: .isDirectory)

        guard let productDirectories = try? FileManager.default.contentsOfDirectory(
            at: jetBrainsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return productDirectories.compactMap { directory in
            let resourceValues = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else {
                return nil
            }

            let cacheFile = directory
                .appending(path: "options", directoryHint: .isDirectory)
                .appending(path: "AIAssistantQuotaManager2.xml")

            return FileManager.default.fileExists(atPath: cacheFile.path) ? cacheFile : nil
        }
        .sorted { lhs, rhs in
            modificationDate(for: lhs) > modificationDate(for: rhs)
        }
    }

    private static func loadCachedAIAssistantQuotaDetails(from files: [URL]) -> JunieQuotaDetails? {
        let sortedFiles = files.sorted { lhs, rhs in
            modificationDate(for: lhs) > modificationDate(for: rhs)
        }

        for file in sortedFiles {
            if let details = parseAIAssistantQuotaCache(at: file) {
                return details
            }
        }

        return nil
    }

    private static func parseAIAssistantQuotaCache(at file: URL) -> JunieQuotaDetails? {
        guard let data = try? Data(contentsOf: file),
              let document = try? XMLDocument(data: data) else {
            return nil
        }

        guard let optionNodes = try? document.nodes(forXPath: "//component[@name='AIAssistantQuotaManager2']/option") else {
            return nil
        }

        var quotaInfo: JunieAIAssistantQuotaInfo?
        var nextRefill: JunieAIAssistantNextRefill?
        let decoder = JSONDecoder()

        for node in optionNodes {
            guard let element = node as? XMLElement,
                  let name = element.attribute(forName: "name")?.stringValue,
                  let value = element.attribute(forName: "value")?.stringValue,
                  let jsonData = value.data(using: .utf8) else {
                continue
            }

            switch name {
            case "quotaInfo":
                quotaInfo = try? decoder.decode(JunieAIAssistantQuotaInfo.self, from: jsonData)
            case "nextRefill":
                nextRefill = try? decoder.decode(JunieAIAssistantNextRefill.self, from: jsonData)
            default:
                continue
            }
        }

        guard let quota = quotaInfo?.monthlyCreditsQuota(maximumFallback: nextRefill?.tariff?.amount) else {
            return nil
        }

        return JunieQuotaDetails(
            quota: quota,
            resetsAt: parseISO8601Date(nextRefill?.next),
            source: .aiAssistantCache
        )
    }

    private static func parseISO8601Date(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func modificationDate(for file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

private struct JunieQuotaDetails: Sendable {
    let quota: JunieQuota
    let resetsAt: Date?
    let source: Source

    enum Source: Sendable {
        case quotaEndpoint
        case aiAssistantCache
    }
}

private struct JunieAuthInfoResponse: Decodable, Sendable {
    let username: String?
    let active: Bool?
    let balanceLeft: Double?
    let balanceTotal: Double?
    let balanceMaximum: Double?
    let quotaTotal: Double?
    let quotaMaximum: Double?
    let subscriptionTotal: Double?
    let licenseType: String?
    let balanceUnit: String?
    let authType: String?

    var totalQuota: Double? {
        balanceTotal ?? balanceMaximum ?? quotaTotal ?? quotaMaximum ?? subscriptionTotal
    }
}

private struct JunieAIAssistantQuotaInfo: Decodable, Sendable {
    let type: String?
    let current: JunieMoneyAmount?
    let maximum: JunieMoneyAmount?
    let available: JunieMoneyAmount?
    let tariffQuota: JunieAIAssistantQuotaBucket?
    let topUpQuota: JunieAIAssistantQuotaBucket?

    func monthlyCreditsQuota(maximumFallback: JunieMoneyAmount?) -> JunieQuota? {
        guard type?.localizedCaseInsensitiveCompare("Available") != .orderedSame || tariffQuota != nil || available != nil else {
            return nil
        }

        let maximumValue = tariffQuota?.maximum ?? maximum ?? maximumFallback
        let availableValue = tariffQuota?.available
            ?? available
            ?? Self.availableFromSpent(current: tariffQuota?.current, maximum: tariffQuota?.maximum)
            ?? Self.availableFromSpent(current: current, maximum: maximumValue)

        guard availableValue != nil || maximumValue != nil else {
            return nil
        }

        return JunieQuota(current: availableValue, maximum: maximumValue)
    }

    private static func availableFromSpent(current: JunieMoneyAmount?, maximum: JunieMoneyAmount?) -> JunieMoneyAmount? {
        guard let current, let maximum else {
            return nil
        }

        return JunieMoneyAmount(value: max(0, maximum.value - current.value))
    }
}

private struct JunieAIAssistantQuotaBucket: Decodable, Sendable {
    let current: JunieMoneyAmount?
    let maximum: JunieMoneyAmount?
    let available: JunieMoneyAmount?
}

private struct JunieAIAssistantNextRefill: Decodable, Sendable {
    let type: String?
    let next: String?
    let tariff: JunieAIAssistantTariff?
}

private struct JunieAIAssistantTariff: Decodable, Sendable {
    let amount: JunieMoneyAmount?
    let duration: String?
}

private struct JunieQuotaGetResponse: Decodable, Sendable {
    let current: JunieQuota?

    private enum CodingKeys: String, CodingKey {
        case current
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = (try? container.decodeIfPresent(JunieQuota.self, forKey: .current)) ?? nil,
           nested.hasQuotaValue {
            current = nested
            return
        }

        let direct = try? JunieQuota(from: decoder)
        current = direct?.hasQuotaValue == true ? direct : nil
    }
}

private struct JunieQuota: Decodable, Sendable {
    let current: JunieMoneyAmount?
    let maximum: JunieMoneyAmount?

    var hasQuotaValue: Bool {
        current != nil || maximum != nil
    }

    private enum CodingKeys: String, CodingKey {
        case current
        case remaining
        case left
        case maximum
        case max
        case limit
        case total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        current = Self.decodeAmount(from: container, keys: [.current, .remaining, .left])
        maximum = Self.decodeAmount(from: container, keys: [.maximum, .max, .limit, .total])
    }

    init(current: JunieMoneyAmount?, maximum: JunieMoneyAmount?) {
        self.current = current
        self.maximum = maximum
    }

    private static func decodeAmount(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> JunieMoneyAmount? {
        for key in keys {
            if let value = try? container.decodeIfPresent(JunieMoneyAmount.self, forKey: key) {
                return value
            }
        }

        return nil
    }
}

private struct JunieMoneyAmount: Decodable, Sendable {
    let value: Double

    private enum CodingKeys: String, CodingKey {
        case amount
    }

    init(from decoder: Decoder) throws {
        let singleValue = try? decoder.singleValueContainer()
        if let value = try? singleValue?.decode(Double.self) {
            self.value = value
            return
        }
        if let value = try? singleValue?.decode(Int.self) {
            self.value = Double(value)
            return
        }
        if let value = try? singleValue?.decode(String.self),
           let parsed = Self.parseAmount(value) {
            self.value = parsed
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Double.self, forKey: .amount) {
            self.value = value
            return
        }
        if let value = try? container.decode(Int.self, forKey: .amount) {
            self.value = Double(value)
            return
        }
        if let value = try? container.decode(String.self, forKey: .amount),
           let parsed = Self.parseAmount(value) {
            self.value = parsed
            return
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Junie quota amount was not numeric.")
        )
    }

    init(value: Double) {
        self.value = value
    }

    private static func parseAmount(_ value: String) -> Double? {
        Double(value.replacingOccurrences(of: "_", with: "").trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum JunieQuotaError: LocalizedError, Equatable {
    case missingAppLogin
    case missingCredentials
    case invalidResponse
    case httpStatus(Int, message: String)

    var errorDescription: String? {
        switch self {
        case .missingAppLogin:
            return "No AgentBar Junie API token was found. Add a Junie API token from AgentBar settings."
        case .missingCredentials:
            return "The saved Junie API token is empty. Add the account again from AgentBar settings."
        case .invalidResponse:
            return "Junie returned an invalid response."
        case let .httpStatus(status, message):
            return "Junie request failed with HTTP \(status): \(message)"
        }
    }
}
