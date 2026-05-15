import Foundation
import Security

public struct AgentProviderStoredAuthSession: Codable, Equatable, Sendable {
    public let provider: AgentProviderKind
    public let accountID: String
    public let accountLabel: String
    public let accessToken: String
    public let refreshToken: String?
    public let expiryDate: Date?
    public let scopes: [String]
    public let lastRefresh: Date

    public init(
        provider: AgentProviderKind,
        accountID: String,
        accountLabel: String,
        accessToken: String,
        refreshToken: String? = nil,
        expiryDate: Date? = nil,
        scopes: [String] = [],
        lastRefresh: Date
    ) {
        self.provider = provider
        self.accountID = accountID
        self.accountLabel = accountLabel
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryDate = expiryDate
        self.scopes = scopes
        self.lastRefresh = lastRefresh
    }
}

public enum AgentProviderAppAuthStore {
    public static func keychainService(for provider: AgentProviderKind) -> String {
        "AgentBar \(provider.title) Auth"
    }

    public static func accountsDirectory(for provider: AgentProviderKind) -> URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)

        return baseDirectory
            .appending(path: "AgentBar", directoryHint: .isDirectory)
            .appending(path: accountsDirectoryName(for: provider), directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static func accountDirectory(for provider: AgentProviderKind, accountID: String) -> URL {
        accountsDirectory(for: provider)
            .appending(path: "account-" + encodedAccountID(accountID), directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static func accountID(fromAccountDirectory directory: URL, provider: AgentProviderKind) -> String? {
        let normalizedDirectory = directory.standardizedFileURL.path
        let normalizedRoot = accountsDirectory(for: provider).standardizedFileURL.path
        let parent = directory.deletingLastPathComponent().standardizedFileURL.path

        guard parent == normalizedRoot else {
            return nil
        }

        let component = URL(fileURLWithPath: normalizedDirectory).lastPathComponent
        guard component.hasPrefix("account-") else {
            return nil
        }

        return decodedAccountID(String(component.dropFirst("account-".count)))
    }

    public static func isAppManagedAccountDirectory(
        _ directory: ConfiguredAccountDirectory,
        provider: AgentProviderKind
    ) -> Bool {
        accountID(fromAccountDirectory: directory.url, provider: provider) != nil
    }

    public static func ensureAccountDirectoryExists(for provider: AgentProviderKind, accountID: String) throws {
        try FileManager.default.createDirectory(
            at: accountDirectory(for: provider, accountID: accountID),
            withIntermediateDirectories: true
        )
    }

    public static func save(session: AgentProviderStoredAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let serialized = String(data: data, encoding: .utf8) else {
            throw AgentProviderAppAuthStoreError.encodingFailed
        }

        try KeychainAgentProviderAuthStore.write(
            serialized,
            service: keychainService(for: session.provider),
            account: session.accountID
        )
    }

    public static func loadSession(
        provider: AgentProviderKind,
        accountID: String
    ) throws -> AgentProviderStoredAuthSession? {
        guard let serialized = try KeychainAgentProviderAuthStore.read(
            service: keychainService(for: provider),
            account: accountID
        ) else {
            return nil
        }

        guard let data = serialized.data(using: .utf8) else {
            throw AgentProviderAppAuthStoreError.decodingFailed
        }

        return try JSONDecoder().decode(AgentProviderStoredAuthSession.self, from: data)
    }

    public static func hasSession(provider: AgentProviderKind, accountID: String) -> Bool {
        (try? loadSession(provider: provider, accountID: accountID)) != nil
    }

    @discardableResult
    public static func deleteSession(provider: AgentProviderKind, accountID: String) throws -> Bool {
        try KeychainAgentProviderAuthStore.delete(
            service: keychainService(for: provider),
            account: accountID
        )
    }

    public static func deleteAccountDirectory(provider: AgentProviderKind, accountID: String) throws {
        let directory = accountDirectory(for: provider, accountID: accountID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }

        try FileManager.default.removeItem(at: directory)
    }

    private static func accountsDirectoryName(for provider: AgentProviderKind) -> String {
        switch provider {
        case .codex:
            return "CodexAccounts"
        case .githubCopilot:
            return "GitHubCopilotAccounts"
        case .gemini:
            return "GeminiAccounts"
        case .claude:
            return "ClaudeAccounts"
        }
    }

    private static func encodedAccountID(_ accountID: String) -> String {
        Data(accountID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodedAccountID(_ encoded: String) -> String? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64) else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
}

public enum AgentProviderAppAuthStoreError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychainStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Credentials could not be encoded for storage."
        case .decodingFailed:
            return "Stored credentials could not be decoded."
        case let .keychainStatus(status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

private enum KeychainAgentProviderAuthStore {
    static func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return nil
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw AgentProviderAppAuthStoreError.keychainStatus(status)
        }
    }

    static func write(_ value: String, service: String, account: String) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            break
        default:
            throw AgentProviderAppAuthStoreError.keychainStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AgentProviderAppAuthStoreError.keychainStatus(addStatus)
        }
    }

    @discardableResult
    static func delete(service: String, account: String) throws -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw AgentProviderAppAuthStoreError.keychainStatus(status)
        }
    }
}
