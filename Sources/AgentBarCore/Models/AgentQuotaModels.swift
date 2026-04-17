import Foundation

public enum AgentProviderKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case githubCopilot
    case gemini
    case claude

    public var id: String { rawValue }

    public static func fromStoredValue(_ rawValue: String?) -> Self {
        switch rawValue {
        case AgentProviderKind.githubCopilot.rawValue:
            return .githubCopilot
        case AgentProviderKind.gemini.rawValue:
            return .gemini
        case AgentProviderKind.claude.rawValue:
            return .claude
        case AgentProviderKind.codex.rawValue, "codexCloudAPI", "localCodex", "openAIAdminAPI":
            return .codex
        default:
            return .codex
        }
    }

    public var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .githubCopilot:
            return "GitHub Copilot"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        }
    }

    public var subtitle: String {
        switch self {
        case .codex:
            return "Reads the same 5-hour and weekly usage data shown on the ChatGPT Codex usage page."
        case .githubCopilot:
            return "Tracks monthly GitHub Copilot premium-request usage for one personal account."
        case .gemini:
            return "Tracks per-model request quota for Gemini Code Assist (shared with Antigravity IDE)."
        case .claude:
            return "Detects the local Claude Code account from auth.json. Quota windows are not exposed by AgentBar yet."
        }
    }

    public var menuBarTitlePrefix: String {
        switch self {
        case .codex:
            return "Codex"
        case .githubCopilot:
            return "Copilot"
        case .gemini:
            return "Gemini"
        case .claude:
            return "Claude"
        }
    }

    public var menuBarShortPrefix: String {
        switch self {
        case .codex:
            return "C"
        case .githubCopilot:
            return "P"
        case .gemini:
            return "G"
        case .claude:
            return "Cl"
        }
    }

    public var refreshInterval: Duration {
        switch self {
        case .codex:
            return .seconds(20)
        case .githubCopilot:
            return .seconds(60)
        case .gemini:
            return .seconds(30)
        case .claude:
            return .seconds(30)
        }
    }
}

public struct AgentProviderAvailability: Sendable, Equatable {
    public var codex: Bool
    public var githubCopilot: Bool
    public var gemini: Bool
    public var claude: Bool

    public init(codex: Bool, githubCopilot: Bool, gemini: Bool, claude: Bool) {
        self.codex = codex
        self.githubCopilot = githubCopilot
        self.gemini = gemini
        self.claude = claude
    }

    public static let none = AgentProviderAvailability(codex: false, githubCopilot: false, gemini: false, claude: false)
    public static let all = AgentProviderAvailability(codex: true, githubCopilot: true, gemini: true, claude: true)

    public var availableProviders: [AgentProviderKind] {
        AgentProviderKind.allCases.filter(isAvailable)
    }

    public func isAvailable(_ provider: AgentProviderKind) -> Bool {
        switch provider {
        case .codex:
            return codex
        case .githubCopilot:
            return githubCopilot
        case .gemini:
            return gemini
        case .claude:
            return claude
        }
    }
}

public struct ConfiguredAgentAccount: Identifiable, Equatable, Sendable {
    public let provider: AgentProviderKind
    public let directory: ConfiguredAccountDirectory

    public init(provider: AgentProviderKind, directory: ConfiguredAccountDirectory) {
        self.provider = provider
        self.directory = directory
    }

    public var id: String {
        "\(provider.rawValue)::\(directory.path)"
    }

    public var displayPath: String {
        directory.displayPath
    }
}

public struct AgentAccountStatus: Identifiable, Equatable, Sendable {
    public let account: ConfiguredAgentAccount
    public let snapshot: AgentQuotaSnapshot?
    public let errorMessage: String?
    public let credentialsDetected: Bool

    public init(
        account: ConfiguredAgentAccount,
        snapshot: AgentQuotaSnapshot?,
        errorMessage: String?,
        credentialsDetected: Bool
    ) {
        self.account = account
        self.snapshot = snapshot
        self.errorMessage = errorMessage
        self.credentialsDetected = credentialsDetected
    }

    public var id: String { account.id }
    public var provider: AgentProviderKind { account.provider }
    public var displayPath: String { account.displayPath }

    public var shouldDisplayInMenu: Bool {
        credentialsDetected || snapshot != nil || errorMessage != nil
    }
}

public struct AgentQuotaSnapshot: Codable, Sendable, Equatable {
    public let provider: AgentProviderKind
    public let accountLabel: String
    public let planType: String?
    public let modelName: String?
    public let sourceSummary: String
    public let metrics: [AgentQuotaMetric]
    public let updatedAt: Date

    public init(
        provider: AgentProviderKind,
        accountLabel: String,
        planType: String?,
        modelName: String?,
        sourceSummary: String,
        metrics: [AgentQuotaMetric],
        updatedAt: Date
    ) {
        self.provider = provider
        self.accountLabel = accountLabel
        self.planType = planType
        self.modelName = modelName
        self.sourceSummary = sourceSummary
        self.metrics = metrics
        self.updatedAt = updatedAt
    }

    public var highlightMetric: AgentQuotaMetric? {
        metrics.max { lhs, rhs in
            lhs.usedPercent < rhs.usedPercent
        } ?? metrics.first
    }
}

public struct AgentQuotaMetric: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let usedPercent: Double
    public let usedLabel: String
    public let remainingLabel: String
    public let resetsAt: Date?

    public init(
        id: String,
        title: String,
        usedPercent: Double,
        usedLabel: String,
        remainingLabel: String,
        resetsAt: Date?
    ) {
        self.id = id
        self.title = title
        self.usedPercent = usedPercent
        self.usedLabel = usedLabel
        self.remainingLabel = remainingLabel
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    public var percentText: String {
        "\(Int(remainingPercent.rounded()))%"
    }

    public static func usageWindow(
        windowMinutes: Int,
        usedPercent: Double,
        resetsAt: Date
    ) -> AgentQuotaMetric {
        AgentQuotaMetric(
            id: "window-\(windowMinutes)",
            title: windowTitle(for: windowMinutes),
            usedPercent: usedPercent,
            usedLabel: "\(Int(usedPercent.rounded()))% used",
            remainingLabel: "\(Int(max(0, 100 - usedPercent).rounded()))% left",
            resetsAt: resetsAt
        )
    }

    public static func cappedUsage(
        id: String,
        title: String,
        used: Int,
        limit: Int,
        resetsAt: Date
    ) -> AgentQuotaMetric {
        let cappedLimit = max(limit, 1)
        let percent = min((Double(used) / Double(cappedLimit)) * 100, 100)

        return AgentQuotaMetric(
            id: id,
            title: title,
            usedPercent: percent,
            usedLabel: "\(used)/\(limit) used",
            remainingLabel: "\(max(0, limit - used)) left",
            resetsAt: resetsAt
        )
    }

    private static func windowTitle(for windowMinutes: Int) -> String {
        switch windowMinutes {
        case 60:
            return "1 hour window"
        case 300:
            return "5 hour window"
        case 1_440:
            return "24 hour window"
        case 10_080:
            return "7 day window"
        default:
            if windowMinutes % 1_440 == 0 {
                return "\(windowMinutes / 1_440) day window"
            }

            return "\(windowMinutes) minute window"
        }
    }
}
