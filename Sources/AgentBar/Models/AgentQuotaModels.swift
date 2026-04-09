import Foundation

enum AgentProviderKind: String, CaseIterable, Identifiable, Sendable {
    case codex
    case githubCopilot
    case gemini

    var id: String { rawValue }

    static func fromStoredValue(_ rawValue: String?) -> Self {
        switch rawValue {
        case AgentProviderKind.githubCopilot.rawValue:
            return .githubCopilot
        case AgentProviderKind.gemini.rawValue:
            return .gemini
        case AgentProviderKind.codex.rawValue, "codexCloudAPI", "localCodex", "openAIAdminAPI":
            return .codex
        default:
            return .codex
        }
    }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .githubCopilot:
            return "GitHub Copilot"
        case .gemini:
            return "Gemini"
        }
    }

    var subtitle: String {
        switch self {
        case .codex:
            return "Reads the same 5-hour and weekly usage data shown on the ChatGPT Codex usage page."
        case .githubCopilot:
            return "Tracks monthly GitHub Copilot premium-request usage for one personal account."
        case .gemini:
            return "Tracks per-model request quota for Gemini Code Assist (shared with Antigravity IDE)."
        }
    }

    var menuBarTitlePrefix: String {
        switch self {
        case .codex:
            return "Codex"
        case .githubCopilot:
            return "Copilot"
        case .gemini:
            return "Gemini"
        }
    }

    var menuBarShortPrefix: String {
        switch self {
        case .codex:
            return "C"
        case .githubCopilot:
            return "P"
        case .gemini:
            return "G"
        }
    }

    var refreshInterval: Duration {
        switch self {
        case .codex:
            return .seconds(20)
        case .githubCopilot:
            return .seconds(60)
        case .gemini:
            return .seconds(30)
        }
    }
}

struct AgentProviderAvailability: Sendable, Equatable {
    var codex: Bool
    var githubCopilot: Bool
    var gemini: Bool

    static let none = AgentProviderAvailability(codex: false, githubCopilot: false, gemini: false)
    static let all = AgentProviderAvailability(codex: true, githubCopilot: true, gemini: true)

    var availableProviders: [AgentProviderKind] {
        AgentProviderKind.allCases.filter(isAvailable)
    }

    func isAvailable(_ provider: AgentProviderKind) -> Bool {
        switch provider {
        case .codex:
            return codex
        case .githubCopilot:
            return githubCopilot
        case .gemini:
            return gemini
        }
    }
}

struct AgentQuotaSnapshot: Sendable, Equatable {
    let provider: AgentProviderKind
    let accountLabel: String
    let planType: String?
    let modelName: String?
    let sourceSummary: String
    let metrics: [AgentQuotaMetric]
    let updatedAt: Date

    var highlightMetric: AgentQuotaMetric? {
        metrics.max { lhs, rhs in
            lhs.usedPercent < rhs.usedPercent
        } ?? metrics.first
    }
}

struct AgentQuotaMetric: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let usedPercent: Double
    let usedLabel: String
    let remainingLabel: String
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    var percentText: String {
        "\(Int(remainingPercent.rounded()))%"
    }

    static func usageWindow(
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

    static func cappedUsage(
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
