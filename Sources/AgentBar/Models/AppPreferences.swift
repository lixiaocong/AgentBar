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
            return "Compact labels for all three providers."
        case .clearer:
            return "Full provider names with remaining percentages."
        case .mixedMetrics:
            return "Percent for Codex and Gemini, remaining request count for Copilot."
        }
    }

    var example: String {
        switch self {
        case .shorter:
            return "C34%  P77%  G100%"
        case .clearer:
            return "Codex 34%  Copilot 77%  Gemini 100%"
        case .mixedMetrics:
            return "Codex 34%  Copilot 231 left  Gemini 100%"
        }
    }
}
