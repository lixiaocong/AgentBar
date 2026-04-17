import Foundation

public enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case shorter
    case clearer
    case mixedMetrics

    public static let defaultValue: Self = .clearer

    public var id: String { rawValue }

    public static func fromStoredValue(_ rawValue: String?) -> Self {
        guard let rawValue, let value = Self(rawValue: rawValue) else {
            return defaultValue
        }

        return value
    }

    public var title: String {
        switch self {
        case .shorter:
            return "Shorter"
        case .clearer:
            return "Clearer"
        case .mixedMetrics:
            return "Mixed Metrics"
        }
    }

    public var detail: String {
        switch self {
        case .shorter:
            return "Compact labels for all detected providers."
        case .clearer:
            return "Full provider names with remaining percentages."
        case .mixedMetrics:
            return "Percent for usage providers, remaining request count for Copilot, status for Claude."
        }
    }

    public var example: String {
        switch self {
        case .shorter:
            return "C34%  P77%  G100%  Cl Ready"
        case .clearer:
            return "Codex 34%  Copilot 77%  Gemini 100%  Claude Ready"
        case .mixedMetrics:
            return "Codex 34%  Copilot 231 left  Gemini 100%  Claude Ready"
        }
    }
}

public struct ConfiguredAccountDirectory: Identifiable, Equatable, Hashable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = Self.normalizedPath(path)
    }

    public var id: String { path }

    public var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    public var displayPath: String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    public static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    public static func unique(paths: [String]) -> [ConfiguredAccountDirectory] {
        var seen = Set<String>()

        return paths.compactMap { rawPath in
            let directory = ConfiguredAccountDirectory(path: rawPath)
            guard seen.insert(directory.path).inserted else {
                return nil
            }

            return directory
        }
    }
}

extension AgentProviderKind {
    public var defaultAccountDirectory: ConfiguredAccountDirectory {
        switch self {
        case .codex:
            return ConfiguredAccountDirectory(path: "~/.codex")
        case .githubCopilot:
            return ConfiguredAccountDirectory(path: "~/.config/github-copilot")
        case .gemini:
            return ConfiguredAccountDirectory(path: "~/.gemini")
        case .claude:
            return ConfiguredAccountDirectory(path: "~/.config/claude-code")
        }
    }

    public var defaultAccountDirectoryDisplayPath: String {
        defaultAccountDirectory.displayPath
    }

    public var credentialsFileDescription: String {
        switch self {
        case .codex:
            return "auth.json"
        case .githubCopilot:
            return "apps.json"
        case .gemini:
            return "oauth_creds.json"
        case .claude:
            return "auth.json"
        }
    }
}
