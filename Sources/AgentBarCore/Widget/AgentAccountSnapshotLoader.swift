import Foundation

public enum AgentAccountSnapshotLoader {
    public static func isAvailable(_ account: ConfiguredAgentAccount) -> Bool {
        switch account.provider {
        case .codex:
            return CodexQuotaService(installation: codexInstallation(for: account)).isAvailable
        case .githubCopilot:
            return GitHubCopilotQuotaService(
                installation: githubCopilotInstallation(for: account)
            ).isAvailable
        case .gemini:
            return GeminiQuotaService(
                installation: geminiInstallation(for: account)
            ).isAvailable
        case .claude:
            return ClaudeQuotaService(
                installation: ClaudeCLIInstallation(configDirectory: account.directory.url)
            ).isAvailable
        case .junie:
            return JunieQuotaService(
                installation: junieInstallation(for: account)
            ).isAvailable
        }
    }

    public static func loadSnapshot(
        for account: ConfiguredAgentAccount
    ) async throws -> AgentQuotaSnapshot {
        switch account.provider {
        case .codex:
            return try await CodexQuotaService(installation: codexInstallation(for: account)).loadSnapshot()
        case .githubCopilot:
            return try await GitHubCopilotQuotaService(
                installation: githubCopilotInstallation(for: account)
            ).loadSnapshot()
        case .gemini:
            return try await GeminiQuotaService(
                installation: geminiInstallation(for: account)
            ).loadSnapshot()
        case .claude:
            return try await ClaudeQuotaService(
                installation: ClaudeCLIInstallation(configDirectory: account.directory.url)
            ).loadSnapshot()
        case .junie:
            return try await JunieQuotaService(
                installation: junieInstallation(for: account)
            ).loadSnapshot()
        }
    }

    private static func codexInstallation(for account: ConfiguredAgentAccount) -> CodexInstallation {
        if let accountID = CodexAppAuthStore.accountID(fromAccountDirectory: account.directory.url) {
            return .appManaged(accountID: accountID)
        }

        return CodexInstallation(rootDirectory: account.directory.url)
    }

    private static func githubCopilotInstallation(for account: ConfiguredAgentAccount) -> GitHubCopilotCLIInstallation {
        if let accountID = AgentProviderAppAuthStore.accountID(
            fromAccountDirectory: account.directory.url,
            provider: .githubCopilot
        ) {
            return .appManaged(accountID: accountID)
        }

        return GitHubCopilotCLIInstallation(configDirectory: account.directory.url)
    }

    private static func geminiInstallation(for account: ConfiguredAgentAccount) -> GeminiCLIInstallation {
        if let accountID = AgentProviderAppAuthStore.accountID(
            fromAccountDirectory: account.directory.url,
            provider: .gemini
        ) {
            return .appManaged(accountID: accountID)
        }

        return GeminiCLIInstallation(
            configDirectory: account.directory.url,
            executableLocations: GeminiCLIInstallation.defaultExecutableLocations
        )
    }

    private static func junieInstallation(for account: ConfiguredAgentAccount) -> JunieInstallation {
        if let accountID = AgentProviderAppAuthStore.accountID(
            fromAccountDirectory: account.directory.url,
            provider: .junie
        ) {
            return .appManaged(accountID: accountID)
        }

        return JunieInstallation(configDirectory: account.directory.url)
    }
}

public struct AgentWidgetStateLoader: Sendable {
    public init() {}

    public func loadState() async -> AgentWidgetState {
        await withTaskGroup(
            of: AgentWidgetProviderState?.self,
            returning: AgentWidgetState.self
        ) { group in
            for provider in AgentProviderKind.allCases {
                group.addTask {
                    await loadProviderState(provider)
                }
            }

            var providers: [AgentWidgetProviderState] = []
            for await providerState in group {
                if let providerState {
                    providers.append(providerState)
                }
            }

            return AgentWidgetState(
                generatedAt: Date(),
                providers: providers.sorted { lhs, rhs in
                    lhs.provider.sortOrder < rhs.provider.sortOrder
                }
            )
        }
    }

    private func loadProviderState(_ provider: AgentProviderKind) async -> AgentWidgetProviderState? {
        let account = ConfiguredAgentAccount(provider: provider, directory: provider.defaultAccountDirectory)
        let isAvailable = AgentAccountSnapshotLoader.isAvailable(account)

        guard isAvailable else {
            return nil
        }

        do {
            let snapshot = try await AgentAccountSnapshotLoader.loadSnapshot(for: account)
            return AgentWidgetProviderState(
                id: account.id,
                provider: provider,
                snapshot: snapshot,
                errorMessage: nil,
                isAvailable: true
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return AgentWidgetProviderState(
                id: account.id,
                provider: provider,
                snapshot: nil,
                errorMessage: message,
                isAvailable: true
            )
        }
    }
}
