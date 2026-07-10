import Foundation
import Security

enum AgentBarKeychainStore {
    static let productionService = "AgentBar Auth v3"
    static let developmentService = "AgentBar Auth Debug v2"
    static let previousProductionService = "AgentBar Auth v2"
    static let legacyService = "AgentBar Auth"
    static let productionBundleIdentifier = "com.agentbar.menu"
    private static let sharedAccount = "browser-login-sessions"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var testVault = Vault()

    static var sharedService: String {
        serviceName(for: Bundle.main.bundleIdentifier)
    }

    static func serviceName(for bundleIdentifier: String?) -> String {
        bundleIdentifier == productionBundleIdentifier ? productionService : developmentService
    }

    static func migrationServices(for bundleIdentifier: String?) -> [String] {
        guard bundleIdentifier == productionBundleIdentifier else {
            return []
        }

        return [previousProductionService, legacyService]
    }

    static func read(
        logicalService: String,
        account: String
    ) throws -> String? {
        try locked {
            if usesInMemoryStoreForTests {
                return testVault.entries[logicalService]?[account]
            }

            return try readVault().entries[logicalService]?[account]
        }
    }

    static func write(
        _ value: String,
        logicalService: String,
        account: String
    ) throws {
        try locked {
            if usesInMemoryStoreForTests {
                testVault.entries[logicalService, default: [:]][account] = value
                return
            }

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
            if usesInMemoryStoreForTests {
                guard var serviceEntries = testVault.entries[logicalService],
                      serviceEntries.removeValue(forKey: account) != nil else {
                    return false
                }

                if serviceEntries.isEmpty {
                    testVault.entries[logicalService] = nil
                } else {
                    testVault.entries[logicalService] = serviceEntries
                }
                return true
            }

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

    private static var usesInMemoryStoreForTests: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }

        return processInfo.arguments.contains { argument in
            argument.contains("AgentBarPackageTests.xctest")
        }
    }

    private static func locked<T>(_ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func readVault() throws -> Vault {
        if let vault = try readVault(service: sharedService) {
            return vault
        }

        for service in migrationServices(for: Bundle.main.bundleIdentifier) {
            guard let previousVault = try readVault(service: service) else {
                continue
            }

            try writeVault(previousVault, service: sharedService)
            return previousVault
        }

        return Vault()
    }

    private static func readVault(service: String) throws -> Vault? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
            return nil
        default:
            throw AgentBarKeychainStoreError.keychainStatus(status)
        }
    }

    private static func writeVault(_ vault: Vault) throws {
        try writeVault(vault, service: sharedService)
    }

    private static func writeVault(_ vault: Vault, service: String) throws {
        let data = try JSONEncoder().encode(vault)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
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
