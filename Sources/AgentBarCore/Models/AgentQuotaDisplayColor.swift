public struct AgentQuotaDisplayRGB: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public enum AgentQuotaDisplayColor {
    public static let healthy = AgentQuotaDisplayRGB(red: 0.20, green: 0.78, blue: 0.35)
    public static let warning = AgentQuotaDisplayRGB(red: 0.88, green: 0.66, blue: 0.08)
    public static let low = AgentQuotaDisplayRGB(red: 1.00, green: 0.58, blue: 0.00)
    public static let empty = AgentQuotaDisplayRGB(red: 1.00, green: 0.23, blue: 0.19)

    public static func color(for remainingPercent: Double) -> AgentQuotaDisplayRGB {
        switch remainingPercent {
        case 75...:
            return healthy
        case 45..<75:
            return warning
        case 20..<45:
            return low
        default:
            return empty
        }
    }
}
