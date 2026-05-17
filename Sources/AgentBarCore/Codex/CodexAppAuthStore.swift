import CryptoKit
import Foundation
import LocalAuthentication
import Security

public enum CodexOAuthConfiguration {
    public static let issuer = URL(string: "https://auth.openai.com")!
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public static let originator = "agentbar"
    public static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"

    public static var authorizationURL: URL {
        issuer.appending(path: "oauth/authorize")
    }

    public static var tokenURL: URL {
        issuer.appending(path: "oauth/token")
    }
}

public struct CodexStoredAuthSession: Codable, Equatable, Sendable {
    public let idToken: String
    public let accessToken: String
    public let refreshToken: String
    public let accountID: String
    public let localAccountID: String?
    public let lastRefresh: Date

    public init(
        idToken: String,
        accessToken: String,
        refreshToken: String,
        accountID: String,
        localAccountID: String? = nil,
        lastRefresh: Date
    ) {
        self.idToken = idToken
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.localAccountID = localAccountID
        self.lastRefresh = lastRefresh
    }

    public var storageAccountID: String {
        localAccountID ?? accountID
    }
}

public struct CodexTokenIdentity: Equatable, Sendable {
    public let subject: String?
    public let accountID: String?
    public let email: String?
    public let name: String?
    public let spaceID: String?
    public let spaceName: String?

    public init(
        subject: String?,
        accountID: String?,
        email: String?,
        name: String?,
        spaceID: String? = nil,
        spaceName: String? = nil
    ) {
        self.subject = subject
        self.accountID = accountID
        self.email = email
        self.name = name
        self.spaceID = spaceID
        self.spaceName = spaceName
    }

    public var spaceLabel: String? {
        spaceName ?? spaceID
    }
}

public enum CodexAppAuthStore {
    public static let keychainService = "AgentBar Codex Browser Auth"

    private static let accountsDirectoryName = "CodexAccounts"
    private static let accountDirectoryPrefix = "account-"

    public static var accountsDirectory: URL {
        let baseDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSString(string: "~/Library/Application Support").expandingTildeInPath)

        return baseDirectory
            .appending(path: "AgentBar", directoryHint: .isDirectory)
            .appending(path: accountsDirectoryName, directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static func accountDirectory(for accountID: String) -> URL {
        accountsDirectory
            .appending(path: accountDirectoryPrefix + encodedAccountID(accountID), directoryHint: .isDirectory)
            .standardizedFileURL
    }

    public static func accountID(fromAccountDirectory directory: URL) -> String? {
        let normalizedDirectory = directory.standardizedFileURL.path
        let normalizedRoot = accountsDirectory.standardizedFileURL.path
        let parent = directory.deletingLastPathComponent().standardizedFileURL.path

        guard parent == normalizedRoot else {
            return nil
        }

        let component = URL(fileURLWithPath: normalizedDirectory).lastPathComponent
        guard component.hasPrefix(accountDirectoryPrefix) else {
            return nil
        }

        return decodedAccountID(String(component.dropFirst(accountDirectoryPrefix.count)))
    }

    public static func isAppManagedAccountDirectory(_ directory: ConfiguredAccountDirectory) -> Bool {
        accountID(fromAccountDirectory: directory.url) != nil
    }

    public static func ensureAccountDirectoryExists(for accountID: String) throws {
        try FileManager.default.createDirectory(
            at: accountDirectory(for: accountID),
            withIntermediateDirectories: true
        )
    }

    public static func save(session: CodexStoredAuthSession) throws {
        let data = try JSONEncoder().encode(session)
        guard let serialized = String(data: data, encoding: .utf8) else {
            throw CodexAppAuthStoreError.encodingFailed
        }

        try KeychainCodexAuthStore.write(
            serialized,
            service: keychainService,
            account: session.storageAccountID
        )
    }

    public static func loadSession(accountID: String) throws -> CodexStoredAuthSession? {
        guard let serialized = try KeychainCodexAuthStore.read(
            service: keychainService,
            account: accountID
        ) else {
            return nil
        }

        guard let data = serialized.data(using: .utf8) else {
            throw CodexAppAuthStoreError.decodingFailed
        }

        return try JSONDecoder().decode(CodexStoredAuthSession.self, from: data)
    }

    public static func hasSession(accountID: String) -> Bool {
        (try? loadSession(accountID: accountID)) != nil
    }

    public static func storedSessionAccountIDs(fileManager: FileManager = .default) -> [String] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: accountsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .compactMap(accountID(fromAccountDirectory:))
            .sorted()
    }

    @discardableResult
    public static func deleteSession(accountID: String) throws -> Bool {
        try KeychainCodexAuthStore.delete(service: keychainService, account: accountID)
    }

    public static func deleteAccountDirectory(accountID: String) throws {
        let directory = accountDirectory(for: accountID)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return
        }

        try FileManager.default.removeItem(at: directory)
    }

    public static func identity(from idToken: String) -> CodexTokenIdentity? {
        guard let payload = decodeJWTPayload(idToken) else {
            return nil
        }

        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        let organization = selectedOrganization(from: auth)

        return CodexTokenIdentity(
            subject: payload["sub"] as? String,
            accountID: auth?["chatgpt_account_id"] as? String,
            email: (payload["email"] as? String) ?? (profile?["email"] as? String),
            name: (payload["name"] as? String) ?? (profile?["name"] as? String),
            spaceID: firstNonEmptyString([
                organization?["id"],
                organization?["organization_id"],
                organization?["workspace_id"]
            ]),
            spaceName: firstNonEmptyString([
                organization?["title"],
                organization?["name"],
                organization?["display_name"],
                organization?["workspace_name"]
            ])
        )
    }

    public static func localAccountID(
        for session: CodexStoredAuthSession,
        existingLocalAccountIDs: [String]
    ) -> String {
        localAccountID(
            for: session,
            existingLocalAccountIDs: existingLocalAccountIDs,
            loadExistingSession: { try? loadSession(accountID: $0) }
        )
    }

    static func localAccountID(
        for session: CodexStoredAuthSession,
        existingLocalAccountIDs: [String],
        loadExistingSession: (String) -> CodexStoredAuthSession?
    ) -> String {
        let existingIDs = unique(existingLocalAccountIDs)
        if let matchingID = existingIDs.first(where: { existingID in
            guard let existingSession = loadExistingSession(existingID) else {
                return false
            }

            return representsSameAccount(existingSession, session)
        }) {
            return matchingID
        }

        guard existingIDs.contains(session.accountID) else {
            return session.accountID
        }

        let baseCandidate = "\(session.accountID)#\(localAccountIDSuffix(for: session))"
        guard existingIDs.contains(baseCandidate) else {
            return baseCandidate
        }

        var index = 2
        while true {
            let candidate = "\(baseCandidate)-\(index)"
            if !existingIDs.contains(candidate) {
                return candidate
            }
            index += 1
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

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func representsSameAccount(
        _ lhs: CodexStoredAuthSession,
        _ rhs: CodexStoredAuthSession
    ) -> Bool {
        guard lhs.accountID == rhs.accountID else {
            return false
        }

        let lhsIdentity = identity(from: lhs.idToken)
        let rhsIdentity = identity(from: rhs.idToken)

        if let lhsSpace = spaceIdentityKey(for: lhsIdentity),
           let rhsSpace = spaceIdentityKey(for: rhsIdentity),
           lhsSpace != rhsSpace {
            return false
        }

        if let lhsSubject = nonEmpty(lhsIdentity?.subject),
           let rhsSubject = nonEmpty(rhsIdentity?.subject) {
            return lhsSubject == rhsSubject
        }

        if let lhsEmail = nonEmpty(lhsIdentity?.email)?.lowercased(),
           let rhsEmail = nonEmpty(rhsIdentity?.email)?.lowercased() {
            return lhsEmail == rhsEmail
        }

        return true
    }

    private static func localAccountIDSuffix(for session: CodexStoredAuthSession) -> String {
        let fingerprint = identityFingerprint(for: session)
        let digest = SHA256.hash(data: Data(fingerprint.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func identityFingerprint(for session: CodexStoredAuthSession) -> String {
        let tokenIdentity = identity(from: session.idToken)
        return [
            session.accountID,
            nonEmpty(tokenIdentity?.subject) ?? "",
            nonEmpty(tokenIdentity?.email)?.lowercased() ?? "",
            nonEmpty(tokenIdentity?.name)?.lowercased() ?? "",
            nonEmpty(tokenIdentity?.spaceID)?.lowercased() ?? "",
            nonEmpty(tokenIdentity?.spaceName)?.lowercased() ?? ""
        ].joined(separator: "|")
    }

    private static func selectedOrganization(from auth: [String: Any]?) -> [String: Any]? {
        guard let auth,
              let organizations = auth["organizations"] as? [[String: Any]],
              !organizations.isEmpty else {
            return nil
        }

        if let selectedID = firstNonEmptyString([
            auth["current_organization_id"],
            auth["default_organization_id"],
            auth["organization_id"],
            auth["workspace_id"]
        ]),
            let selected = organizations.first(where: {
                selectedID == firstNonEmptyString([$0["id"], $0["organization_id"], $0["workspace_id"]])
            }) {
            return selected
        }

        return organizations.first(where: { boolValue($0["is_default"]) }) ??
            organizations.first(where: { boolValue($0["is_personal"]) }) ??
            organizations.first
    }

    private static func spaceIdentityKey(for identity: CodexTokenIdentity?) -> String? {
        if let spaceID = nonEmpty(identity?.spaceID)?.lowercased() {
            return "id:\(spaceID)"
        }

        if let spaceName = nonEmpty(identity?.spaceName)?.lowercased() {
            return "name:\(spaceName)"
        }

        return nil
    }

    private static func firstNonEmptyString(_ values: [Any?]) -> String? {
        values.lazy
            .compactMap { $0 as? String }
            .compactMap(nonEmpty)
            .first
    }

    private static func boolValue(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes"
        default:
            return false
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
    }

    private static func decodeJWTPayload(_ jwt: String) -> [String: Any]? {
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
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return object
    }
}

public enum CodexAppAuthStoreError: LocalizedError {
    case encodingFailed
    case decodingFailed
    case keychainStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Codex credentials could not be encoded for storage."
        case .decodingFailed:
            return "Stored Codex credentials could not be decoded."
        case let .keychainStatus(status):
            return "Keychain operation failed with status \(status)."
        }
    }
}

private enum KeychainCodexAuthStore {
    static func read(service: String, account: String) throws -> String? {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
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
            throw CodexAppAuthStoreError.keychainStatus(status)
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
        if updateStatus == errSecSuccess {
            return
        }

        guard updateStatus == errSecItemNotFound else {
            throw CodexAppAuthStoreError.keychainStatus(updateStatus)
        }

        var insertQuery = baseQuery
        insertQuery[kSecValueData as String] = data
        insertQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CodexAppAuthStoreError.keychainStatus(addStatus)
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
            throw CodexAppAuthStoreError.keychainStatus(status)
        }
    }
}
