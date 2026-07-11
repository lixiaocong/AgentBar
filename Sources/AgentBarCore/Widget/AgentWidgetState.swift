import Foundation
import Security

public enum AgentBarWidgetConstants {
    public static let appBundleIdentifier = "com.agentbar.menu"
    public static let widgetBundleIdentifier = "com.agentbar.menu.widget"
    public static let appGroupIdentifier = "CP22VZ6846.com.agentbar.menu.shared"
    public static let kind = "AgentBarDesktopWidget"
    public static let snapshotFilename = "widget-state.json"
    public static let snapshotDirectoryName = "AgentBar"
    public static let cacheFreshnessInterval: TimeInterval = 5 * 60
    public static let timelineRefreshInterval: TimeInterval = 60
}

public struct AgentWidgetProviderState: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: AgentProviderKind
    public let accountLabel: String?
    public let snapshot: AgentQuotaSnapshot?
    public let errorMessage: String?
    public let isAvailable: Bool

    public init(
        id: String,
        provider: AgentProviderKind,
        accountLabel: String? = nil,
        snapshot: AgentQuotaSnapshot?,
        errorMessage: String?,
        isAvailable: Bool
    ) {
        self.id = id
        self.provider = provider
        self.accountLabel = accountLabel
        self.snapshot = snapshot
        self.errorMessage = errorMessage
        self.isAvailable = isAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case accountLabel
        case snapshot
        case errorMessage
        case isAvailable
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(AgentProviderKind.self, forKey: .provider)

        id = try container.decodeIfPresent(String.self, forKey: .id) ?? provider.rawValue
        self.provider = provider
        accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel)
        snapshot = try container.decodeIfPresent(AgentQuotaSnapshot.self, forKey: .snapshot)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? false
    }

    public var displayLabel: String? {
        let label = snapshot?.accountLabel ?? accountLabel
        guard let label = label?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else {
            return nil
        }

        return label
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
        var loadedStates: [AgentWidgetState] = []
        var lastError: Error?

        for fileURL in Self.readSnapshotURLs(fileManager: fileManager)
        where fileManager.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                loadedStates.append(try Self.decoder.decode(AgentWidgetState.self, from: data))
            } catch {
                lastError = error
            }
        }

        if let newestState = Self.newestState(in: loadedStates) {
            return newestState
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

        for fileURL in Self.writeSnapshotURLs(fileManager: fileManager) {
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

    static func newestState(in states: [AgentWidgetState]) -> AgentWidgetState? {
        states.max { lhs, rhs in
            lhs.generatedAt < rhs.generatedAt
        }
    }

    private static func readSnapshotURLs(fileManager: FileManager) -> [URL] {
        if isWidgetExtension {
            return uniqueURLs(
                widgetLocalSnapshotURLs(fileManager: fileManager)
                    + appGroupSnapshotURLs(fileManager: fileManager)
            )
        }

        return uniqueURLs(writeSnapshotURLs(fileManager: fileManager))
    }

    static func writeSnapshotURLs(fileManager: FileManager) -> [URL] {
        var urls: [URL] = []

        urls.append(contentsOf: appGroupSnapshotURLs(fileManager: fileManager))

        guard !isWidgetExtension else {
            return uniqueURLs(urls)
        }

        if let ownAppSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(
                ownAppSupportURL
                    .appending(path: AgentBarWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
                    .appending(path: AgentBarWidgetConstants.snapshotFilename)
            )
        }

        urls.append(legacySnapshotURL(fileManager: fileManager))

        return uniqueURLs(urls)
    }

    /// Legacy paths the widget extension can read from within its own sandbox.
    /// The host app must never write here; doing so triggers macOS App Data access.
    private static func widgetLocalSnapshotURLs(fileManager: FileManager) -> [URL] {
        let home = fileManager.homeDirectoryForCurrentUser
        return [
            home
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: AgentBarWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
                .appending(path: AgentBarWidgetConstants.snapshotFilename),
            home
                .appending(path: AgentBarWidgetConstants.snapshotFilename)
        ]
    }

    private static func appGroupSnapshotURLs(fileManager: FileManager) -> [URL] {
        guard processHasAppGroupEntitlement,
              let sharedContainerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AgentBarWidgetConstants.appGroupIdentifier
        ) else {
            return []
        }

        return [
            sharedContainerURL
                .appending(path: "Library/Application Support", directoryHint: .isDirectory)
                .appending(path: AgentBarWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
                .appending(path: AgentBarWidgetConstants.snapshotFilename),
            sharedContainerURL.appending(path: AgentBarWidgetConstants.snapshotFilename)
        ]
    }

    private static var processHasAppGroupEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let groups = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil
              ) as? [String] else {
            return false
        }
        return groups.contains(AgentBarWidgetConstants.appGroupIdentifier)
    }

    private static func legacySnapshotURL(fileManager: FileManager) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: AgentBarWidgetConstants.snapshotDirectoryName, directoryHint: .isDirectory)
            .appending(path: AgentBarWidgetConstants.snapshotFilename)
    }

    private static var isWidgetExtension: Bool {
        let mainBundle = Bundle.main
        return mainBundle.bundleIdentifier == AgentBarWidgetConstants.widgetBundleIdentifier
            || mainBundle.bundlePath.hasSuffix(".appex")
            || mainBundle.infoDictionary?["NSExtension"] != nil
            || ProcessInfo.processInfo.processName == "AgentBarWidgetExtension"
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
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
        case .zai:
            return 4
        case .junie:
            return 5
        }
    }
}
