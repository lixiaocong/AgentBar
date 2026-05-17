import Foundation
import Security

enum AgentBarKeychainStore {
    static let sharedService = "AgentBar Auth"
    private static let sharedAccount = "browser-login-sessions"

    private static let lock = NSLock()

    static func read(
        logicalService: String,
        account: String
    ) throws -> String? {
        try locked {
            try readVault().entries[logicalService]?[account]
        }
    }

    static func write(
        _ value: String,
        logicalService: String,
        account: String
    ) throws {
        try locked {
            var vault = try readVault()
            vault.entries[logicalService, default: [:]][account] = value
            try writeVault(vault)
        }
    }

    @discardableResult
    static func delete(
        logicalService: String,
        account: String
    ) throws -> Bool {
        try locked {
            var vault = try readVault()
            guard var serviceEntries = vault.entries[logicalService],
                  serviceEntries.removeValue(forKey: account) != nil else {
                return false
            }

            if serviceEntries.isEmpty {
                vault.entries[logicalService] = nil
            } else {
                vault.entries[logicalService] = serviceEntries
            }
            try writeVault(vault)
            return true
        }
    }

    private static func locked<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func readVault() throws -> Vault {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedService,
            kSecAttrAccount as String: sharedAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw AgentBarKeychainStoreError.decodingFailed
            }
            return try JSONDecoder().decode(Vault.self, from: data)
        case errSecItemNotFound:
            return Vault()
        default:
            throw AgentBarKeychainStoreError.keychainStatus(status)
        }
    }

    private static func writeVault(_ vault: Vault) throws {
        let data = try JSONEncoder().encode(vault)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: sharedService,
            kSecAttrAccount as String: sharedAccount
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
            throw AgentBarKeychainStoreError.keychainStatus(updateStatus)
        }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AgentBarKeychainStoreError.keychainStatus(addStatus)
        }
    }
}

private struct Vault: Codable {
    var entries: [String: [String: String]] = [:]
}

enum AgentBarKeychainStoreError: LocalizedError {
    case decodingFailed
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .decodingFailed:
            return "Stored AgentBar credentials could not be decoded."
        case let .keychainStatus(status):
            return "Keychain operation failed with status \(status)."
        }
    }
}
