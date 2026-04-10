import Foundation

enum MenuBarDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case shorter
    case clearer
    case mixedMetrics

    static let defaultValue: Self = .clearer

    var id: String { rawValue }

    static func fromStoredValue(_ rawValue: String?) -> Self {
        guard let rawValue, let value = Self(rawValue: rawValue) else {
            return defaultValue
        }

        return value
    }

    var title: String {
        switch self {
        case .shorter:
            return "Shorter"
        case .clearer:
            return "Clearer"
        case .mixedMetrics:
            return "Mixed Metrics"
        }
    }

    var detail: String {
        switch self {
        case .shorter:
            return "Compact labels for all detected providers."
        case .clearer:
            return "Full provider names with remaining percentages."
        case .mixedMetrics:
            return "Percent for usage providers, remaining request count for Copilot, status for Claude."
        }
    }

    var example: String {
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

struct ConfiguredAccountDirectory: Identifiable, Equatable, Hashable, Sendable {
    let path: String

    init(path: String) {
        self.path = Self.normalizedPath(path)
    }

    var id: String { path }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }

    var displayPath: String {
        NSString(string: path).abbreviatingWithTildeInPath
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func unique(paths: [String]) -> [ConfiguredAccountDirectory] {
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
    var defaultAccountDirectory: ConfiguredAccountDirectory {
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

    var defaultAccountDirectoryDisplayPath: String {
        defaultAccountDirectory.displayPath
    }

    var credentialsFileDescription: String {
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
