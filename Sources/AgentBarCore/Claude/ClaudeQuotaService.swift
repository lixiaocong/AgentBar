import Foundation
import os

public struct ClaudeCLIInstallation: Sendable {
    public let configDirectory: URL

    public static let `default` = ClaudeCLIInstallation(
        configDirectory: URL(fileURLWithPath: NSString(string: "~/.config/claude-code").expandingTildeInPath)
    )

    public init(configDirectory: URL) {
        self.configDirectory = configDirectory
    }

    public var authFile: URL {
        configDirectory.appending(path: "auth.json")
    }
}

public struct ClaudeQuotaService: Sendable {
    public let installation: ClaudeCLIInstallation

    public init(installation: ClaudeCLIInstallation = .default) {
        self.installation = installation
    }

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: installation.authFile.path)
    }

    public func loadSnapshot() async throws -> AgentQuotaSnapshot {
        let installation = installation
        let data = try await Task.detached(priority: .userInitiated) {
            try loadAuthDataSynchronously(for: installation)
        }.value

        return try decodeSnapshot(from: data, updatedAt: Date())
    }

    public func decodeSnapshot(from data: Data, updatedAt: Date) throws -> AgentQuotaSnapshot {
        let payload = try decodeAuthPayload(from: data)
        return buildSnapshot(from: payload, updatedAt: updatedAt)
    }

    private func loadAuthDataSynchronously(for installation: ClaudeCLIInstallation) throws -> Data {
        let authFile = installation.authFile
        guard FileManager.default.fileExists(atPath: authFile.path) else {
            let error = ClaudeQuotaError.missingCredentialsFile(authFile.path)
            logError("[Claude] \(error.errorDescription ?? "\(error)")")
            throw error
        }

        let data: Data
        do {
            data = try Data(contentsOf: authFile)
        } catch {
            logError("[Claude] Cannot read auth.json: \(error)")
            throw error
        }

        return data
    }

    private func decodeAuthPayload(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            logError("[Claude] auth.json decode failed: \(error)")
            throw ClaudeQuotaError.invalidCredentialsFile
        }
    }

    private func buildSnapshot(from payload: Any, updatedAt: Date) -> AgentQuotaSnapshot {
        AgentQuotaSnapshot(
            provider: .claude,
            accountLabel: preferredAccountLabel(from: payload),
            planType: preferredPlanType(from: payload),
            modelName: nil,
            sourceSummary: "Claude Code local auth",
            metrics: [],
            updatedAt: updatedAt
        )
    }

    private func preferredAccountLabel(from payload: Any) -> String {
        if let email = findString(
            in: payload,
            matchingKeys: ["email", "accountemail", "useremail", "primaryemail"]
        ) {
            return email
        }

        if let displayName = findString(
            in: payload,
            matchingKeys: ["displayname", "fullname", "username"],
            pathMustContainOneOf: ["user", "account", "profile", "workspace"]
        ) {
            return displayName
        }

        if let name = findString(
            in: payload,
            matchingKeys: ["name"],
            pathMustContainOneOf: ["user", "account", "profile", "workspace"]
        ) {
            return name
        }

        if let workspaceName = findString(
            in: payload,
            matchingKeys: ["workspacename", "organizationname", "teamname"]
        ) {
            return workspaceName
        }

        if isConsoleAuth(payload) {
            return "Anthropic Console"
        }

        return "Claude Code"
    }

    private func preferredPlanType(from payload: Any) -> String? {
        if let plan = findString(
            in: payload,
            matchingKeys: ["plan", "plantype", "subscriptionplan", "subscriptiontype", "tier", "planname"]
        ) {
            return plan
        }

        if isConsoleAuth(payload) {
            return "Anthropic Console"
        }

        if isClaudeSubscriptionAuth(payload) {
            return "Claude subscription"
        }

        return nil
    }

    private func isClaudeSubscriptionAuth(_ payload: Any) -> Bool {
        containsKey(in: payload, matchingKeys: ["accesstoken", "refreshtoken", "expiresat", "expirydate"])
            || containsString(in: payload, containing: ["claude.ai"])
    }

    private func isConsoleAuth(_ payload: Any) -> Bool {
        containsKey(in: payload, matchingKeys: ["apikey", "anthropicapikey", "customapikey", "apiKeyResponses".normalizedJSONKey])
            || containsString(in: payload, containing: ["console.anthropic.com"])
    }

    private func findString(
        in value: Any,
        matchingKeys: Set<String>,
        path: [String] = [],
        pathMustContainOneOf requiredPathComponents: Set<String> = []
    ) -> String? {
        if let dictionary = value as? [String: Any] {
            for rawKey in dictionary.keys.sorted() {
                let normalizedKey = rawKey.normalizedJSONKey
                let nextPath = path + [normalizedKey]
                let pathMatches = requiredPathComponents.isEmpty || !requiredPathComponents.isDisjoint(with: Set(nextPath))

                if matchingKeys.contains(normalizedKey),
                   pathMatches,
                   let string = sanitizedString(from: dictionary[rawKey]),
                   !string.isEmpty {
                    return string
                }
            }

            for rawKey in dictionary.keys.sorted() {
                let nextPath = path + [rawKey.normalizedJSONKey]
                if let found = findString(
                    in: dictionary[rawKey] as Any,
                    matchingKeys: matchingKeys,
                    path: nextPath,
                    pathMustContainOneOf: requiredPathComponents
                ) {
                    return found
                }
            }
        }

        if let array = value as? [Any] {
            for element in array {
                if let found = findString(
                    in: element,
                    matchingKeys: matchingKeys,
                    path: path,
                    pathMustContainOneOf: requiredPathComponents
                ) {
                    return found
                }
            }
        }

        return nil
    }

    private func containsKey(
        in value: Any,
        matchingKeys: Set<String>
    ) -> Bool {
        if let dictionary = value as? [String: Any] {
            for rawKey in dictionary.keys {
                let normalizedKey = rawKey.normalizedJSONKey
                if matchingKeys.contains(normalizedKey) {
                    return true
                }
            }

            for nestedValue in dictionary.values {
                if containsKey(in: nestedValue, matchingKeys: matchingKeys) {
                    return true
                }
            }
        }

        if let array = value as? [Any] {
            return array.contains { containsKey(in: $0, matchingKeys: matchingKeys) }
        }

        return false
    }

    private func containsString(
        in value: Any,
        containing needles: [String]
    ) -> Bool {
        if let string = value as? String {
            let lowercased = string.lowercased()
            return needles.contains { lowercased.contains($0) }
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { containsString(in: $0, containing: needles) }
        }

        if let array = value as? [Any] {
            return array.contains { containsString(in: $0, containing: needles) }
        }

        return false
    }

    private func sanitizedString(from value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ClaudeQuotaError: LocalizedError, Equatable {
    case missingCredentialsFile(String)
    case invalidCredentialsFile

    var errorDescription: String? {
        switch self {
        case let .missingCredentialsFile(path):
            return "Claude Code credentials not found at \(path). Run `claude` and sign in first."
        case .invalidCredentialsFile:
            return "Claude Code auth.json could not be parsed."
        }
    }
}

private extension String {
    var normalizedJSONKey: String {
        let scalars = lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}
