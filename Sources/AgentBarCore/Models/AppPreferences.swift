import Foundation

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
            return ConfiguredAccountDirectory(path: CodexAppAuthStore.accountsDirectory.path)
        case .githubCopilot:
            return ConfiguredAccountDirectory(path: AgentProviderAppAuthStore.accountsDirectory(for: .githubCopilot).path)
        case .gemini:
            return ConfiguredAccountDirectory(path: AgentProviderAppAuthStore.accountsDirectory(for: .gemini).path)
        case .claude:
            return ConfiguredAccountDirectory(path: ClaudeCLIInstallation.defaultConfigDirectory.path)
        }
    }

    public var defaultAccountDirectoryDisplayPath: String {
        defaultAccountDirectory.displayPath
    }

    public var credentialsFileDescription: String {
        switch self {
        case .codex:
            return "AgentBar browser login"
        case .githubCopilot:
            return "AgentBar browser login"
        case .gemini:
            return "AgentBar browser login"
        case .claude:
            return "auth.json"
        }
    }
}
