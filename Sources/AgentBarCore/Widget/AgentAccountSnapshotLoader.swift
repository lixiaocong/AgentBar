import Foundation

public enum AgentAccountSnapshotLoader {
    public static func isAvailable(_ account: ConfiguredAgentAccount) -> Bool {
        switch account.provider {
        case .codex:
            return CodexQuotaService(
                installation: CodexInstallation(rootDirectory: account.directory.url)
            ).isAvailable
        case .githubCopilot:
            return GitHubCopilotQuotaService(
                installation: GitHubCopilotCLIInstallation(configDirectory: account.directory.url)
            ).isAvailable
        case .gemini:
            return GeminiQuotaService(
                installation: GeminiCLIInstallation(
                    configDirectory: account.directory.url,
                    executableLocations: GeminiCLIInstallation.defaultExecutableLocations
                )
            ).isAvailable
        case .claude:
            return ClaudeQuotaService(
                installation: ClaudeCLIInstallation(configDirectory: account.directory.url)
            ).isAvailable
        }
    }

    public static func loadSnapshot(
        for account: ConfiguredAgentAccount
    ) async throws -> AgentQuotaSnapshot {
        switch account.provider {
        case .codex:
            return try await CodexQuotaService(
                installation: CodexInstallation(rootDirectory: account.directory.url)
            ).loadSnapshot()
        case .githubCopilot:
            return try await GitHubCopilotQuotaService(
                installation: GitHubCopilotCLIInstallation(configDirectory: account.directory.url)
            ).loadSnapshot()
        case .gemini:
            return try await GeminiQuotaService(
                installation: GeminiCLIInstallation(
                    configDirectory: account.directory.url,
                    executableLocations: GeminiCLIInstallation.defaultExecutableLocations
                )
            ).loadSnapshot()
        case .claude:
            return try await ClaudeQuotaService(
                installation: ClaudeCLIInstallation(configDirectory: account.directory.url)
            ).loadSnapshot()
        }
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
