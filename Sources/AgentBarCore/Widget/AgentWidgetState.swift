import Foundation

public enum AgentBarWidgetConstants {
    public static let appBundleIdentifier = "com.agentbar.app"
    public static let widgetBundleIdentifier = "com.agentbar.app.widget"
    public static let appGroupIdentifier = "group.com.agentbar.shared"
    public static let kind = "AgentBarDesktopWidget"
    public static let snapshotFilename = "widget-state.json"
    public static let snapshotDirectoryName = "AgentBar"
    public static let snapshotDefaultsKey = "widgetStateData"
    public static let cacheFreshnessInterval: TimeInterval = 5 * 60
    public static let timelineRefreshInterval: TimeInterval = 15 * 60
}

public struct AgentWidgetProviderState: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: AgentProviderKind
    public let snapshot: AgentQuotaSnapshot?
    public let errorMessage: String?
    public let isAvailable: Bool

    public init(
        id: String,
        provider: AgentProviderKind,
        snapshot: AgentQuotaSnapshot?,
        errorMessage: String?,
        isAvailable: Bool
    ) {
        self.id = id
        self.provider = provider
        self.snapshot = snapshot
        self.errorMessage = errorMessage
        self.isAvailable = isAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case snapshot
        case errorMessage
        case isAvailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(AgentProviderKind.self, forKey: .provider)

        id = try container.decodeIfPresent(String.self, forKey: .id) ?? provider.rawValue
        self.provider = provider
        snapshot = try container.decodeIfPresent(AgentQuotaSnapshot.self, forKey: .snapshot)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? false
    }
}

public struct AgentWidgetState: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let providers: [AgentWidgetProviderState]

    public init(generatedAt: Date, providers: [AgentWidgetProviderState]) {
        self.generatedAt = generatedAt
        self.providers = providers
    }

    public var sortedProviders: [AgentWidgetProviderState] {
        providers
            .enumerated()
            .sorted { lhs, rhs in
                let leftOrder = lhs.element.provider.sortOrder
                let rightOrder = rhs.element.provider.sortOrder

                if leftOrder != rightOrder {
                    return leftOrder < rightOrder
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    public var highlightMetric: AgentQuotaMetric? {
        sortedProviders
            .compactMap(\.snapshot)
            .compactMap(\.highlightMetric)
            .max { lhs, rhs in
                lhs.usedPercent < rhs.usedPercent
            }
    }

    public var isFresh: Bool {
        Date().timeIntervalSince(generatedAt) <= AgentBarWidgetConstants.cacheFreshnessInterval
    }
}

public struct AgentWidgetStateStore {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func load() throws -> AgentWidgetState {
        var lastError: Error?

        if let sharedDefaults,
           let data = sharedDefaults.data(forKey: AgentBarWidgetConstants.snapshotDefaultsKey) {
            do {
                return try Self.decoder.decode(AgentWidgetState.self, from: data)
            } catch {
                lastError = error
            }
        }

        for fileURL in Self.candidateSnapshotURLs(fileManager: fileManager)
        where fileManager.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                return try Self.decoder.decode(AgentWidgetState.self, from: data)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? CocoaError(.fileReadNoSuchFile)
    }

    public func loadIfPresent() -> AgentWidgetState? {
        try? load()
    }

    public func save(_ state: AgentWidgetState) throws {
        let data = try Self.encoder.encode(state)
        var savedAtLeastOnce = false
        var lastError: Error?

        if let sharedDefaults {
            sharedDefaults.set(data, forKey: AgentBarWidgetConstants.snapshotDefaultsKey)
            sharedDefaults.synchronize()
            savedAtLeastOnce = true
        }

        for fileURL in Self.candidateSnapshotURLs(fileManager: fileManager) {
            do {
                let directory = fileURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: fileURL, options: .atomic)
                savedAtLeastOnce = true
            } catch {
                lastError = error
            }
        }

        if !savedAtLeastOnce {
            throw lastError ?? CocoaError(.fileWriteUnknown)
        }
    }

    public static var defaultFileURL: URL {
        legacySnapshotURL(fileManager: .default)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: AgentBarWidgetConstants.appGroupIdentifier)
    }

    private static func candidateSnapshotURLs(fileManager: FileManager) -> [URL] {
        var urls: [URL] = []

        if let ownAppSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(
                ownAppSupportURL
                    .appending(path: AgentBarWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
                    .appending(path: AgentBarWidgetConstants.snapshotFilename)
            )
        }

        if let sharedContainerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AgentBarWidgetConstants.appGroupIdentifier
        ) {
            urls.append(
                sharedContainerURL
                    .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                    .appending(path: AgentBarWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
                    .appending(path: AgentBarWidgetConstants.snapshotFilename)
            )
            urls.append(
                sharedContainerURL.appending(path: AgentBarWidgetConstants.snapshotFilename)
            )
        }

        urls.append(
            contentsOf: deterministicContainerSnapshotURLs(
                forBundleIdentifier: AgentBarWidgetConstants.widgetBundleIdentifier,
                fileManager: fileManager
            )
        )
        urls.append(
            contentsOf: deterministicContainerSnapshotURLs(
                forBundleIdentifier: AgentBarWidgetConstants.appBundleIdentifier,
                fileManager: fileManager
            )
        )
        urls.append(legacySnapshotURL(fileManager: fileManager))

        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func deterministicContainerSnapshotURLs(
        forBundleIdentifier bundleIdentifier: String,
        fileManager: FileManager
    ) -> [URL] {
        let containerRoot = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers", directoryHint: .isDirectory)
            .appending(path: bundleIdentifier, directoryHint: .isDirectory)
            .appending(path: "Data", directoryHint: .isDirectory)

        return [
            containerRoot
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: AgentBarWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
                .appending(path: AgentBarWidgetConstants.snapshotFilename),
            containerRoot
                .appending(path: AgentBarWidgetConstants.snapshotFilename),
        ]
    }

    private static func legacySnapshotURL(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: AgentBarWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
            .appending(path: AgentBarWidgetConstants.snapshotFilename)
    }
}

public extension AgentProviderKind {
    var sortOrder: Int {
        switch self {
        case .codex:
            return 0
        case .githubCopilot:
            return 1
        case .gemini:
            return 2
        case .claude:
            return 3
        }
    }
}
