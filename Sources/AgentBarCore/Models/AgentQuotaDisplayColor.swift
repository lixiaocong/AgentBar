import Foundation

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

public enum AgentQuotaDisplayState: Int, Equatable, Comparable, Sendable {
    case healthy
    case warning
    case low
    case empty

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum AgentQuotaDisplayColor {
    public static let healthy = AgentQuotaDisplayRGB(red: 0.20, green: 0.78, blue: 0.35)
    public static let warning = AgentQuotaDisplayRGB(red: 0.88, green: 0.66, blue: 0.08)
    public static let low = AgentQuotaDisplayRGB(red: 1.00, green: 0.58, blue: 0.00)
    public static let empty = AgentQuotaDisplayRGB(red: 1.00, green: 0.23, blue: 0.19)

    public static func color(for remainingPercent: Double) -> AgentQuotaDisplayRGB {
        color(for: state(for: remainingPercent))
    }

    public static func color(
        for remainingPercent: Double,
        resetsAt: Date?,
        windowDuration: TimeInterval?,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> AgentQuotaDisplayRGB {
        color(
            for: state(
                for: remainingPercent,
                resetsAt: resetsAt,
                windowDuration: windowDuration,
                now: now,
                timeZone: timeZone
            )
        )
    }

    public static func color(
        for metric: AgentQuotaMetric,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> AgentQuotaDisplayRGB {
        color(
            for: metric.remainingPercent,
            resetsAt: metric.resetsAt,
            windowDuration: metric.windowDuration,
            now: now,
            timeZone: timeZone
        )
    }

    public static func state(for remainingPercent: Double) -> AgentQuotaDisplayState {
        switch remainingPercent {
        case 75...:
            return .healthy
        case 45..<75:
            return .warning
        case 20..<45:
            return .low
        default:
            return .empty
        }
    }

    public static func state(
        for remainingPercent: Double,
        resetsAt: Date?,
        windowDuration: TimeInterval?,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> AgentQuotaDisplayState {
        guard let baseline = baselineRemainingPercent(
            resetsAt: resetsAt,
            windowDuration: windowDuration,
            now: now,
            timeZone: timeZone
        ) else {
            return state(for: remainingPercent)
        }

        let remaining = min(max(remainingPercent, 0), 100)
        if remaining < baseline / 2 {
            return .empty
        }
        if remaining < baseline {
            return .low
        }
        return .healthy
    }

    public static func baselineRemainingPercent(
        resetsAt: Date?,
        windowDuration: TimeInterval?,
        now: Date = Date(),
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Double? {
        guard let resetsAt,
              let windowDuration,
              windowDuration.isFinite,
              windowDuration > 0 else {
            return nil
        }

        let remainingTime = resetsAt.timeIntervalSince(now)
        guard remainingTime > 0 else {
            return nil
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let windowStart = resetsAt.addingTimeInterval(-windowDuration)
        // Normalize both intervals so a fresh window still starts at 100%.
        let totalWeekdayTime = weekdayTime(from: windowStart, to: resetsAt, calendar: calendar)
        guard totalWeekdayTime > 0 else { return 0 }

        let remainingWeekdayTime = weekdayTime(
            from: max(now, windowStart),
            to: resetsAt,
            calendar: calendar
        )
        return min(max(remainingWeekdayTime / totalWeekdayTime, 0), 1) * 100
    }

    private static func weekdayTime(from start: Date, to end: Date, calendar: Calendar) -> TimeInterval {
        var cursor = start
        var duration: TimeInterval = 0

        // Local day boundaries preserve partial days and 23/25-hour DST days.
        while cursor < end,
              let day = calendar.dateInterval(of: .day, for: cursor),
              day.end > cursor {
            let next = min(day.end, end)
            let weekday = calendar.component(.weekday, from: cursor)
            if weekday != 1 && weekday != 7 {
                duration += next.timeIntervalSince(cursor)
            }
            cursor = next
        }
        return duration
    }

    public static func color(for state: AgentQuotaDisplayState) -> AgentQuotaDisplayRGB {
        switch state {
        case .healthy:
            return healthy
        case .warning:
            return warning
        case .low:
            return low
        case .empty:
            return empty
        }
    }
}

public enum AgentQuotaWindowDuration {
    public static func seconds(metricID: String, title: String) -> TimeInterval? {
        let normalizedID = metricID.lowercased().replacingOccurrences(of: "-", with: "_")

        if let minutes = trailingWindowMinutes(in: metricID) {
            return TimeInterval(minutes * 60)
        }
        if normalizedID.contains("five_hour") {
            return 5 * 60 * 60
        }
        if normalizedID.contains("seven_day") {
            return 7 * 24 * 60 * 60
        }
        if let explicitDuration = explicitDuration(in: title) {
            return explicitDuration
        }

        let normalizedTitle = title.lowercased()
        if normalizedTitle.contains("weekly") {
            return 7 * 24 * 60 * 60
        }
        if normalizedTitle.contains("monthly") || normalizedTitle.contains("/ month") {
            return 30 * 24 * 60 * 60
        }

        return nil
    }

    private static func trailingWindowMinutes(in metricID: String) -> Int? {
        let parts = metricID.lowercased().split(separator: "-")
        guard parts.count >= 2,
              parts[parts.count - 2] == "window",
              let minutes = Int(parts[parts.count - 1]),
              minutes > 0 else {
            return nil
        }
        return minutes
    }

    private static func explicitDuration(in title: String) -> TimeInterval? {
        let tokens = title.lowercased().split { character in
            !character.isLetter && !character.isNumber && character != "."
        }

        for (index, token) in tokens.enumerated() {
            if let value = Double(token),
               tokens.indices.contains(index + 1),
               let seconds = seconds(value: value, unit: String(tokens[index + 1])) {
                return seconds
            }

            let compact = String(token)
            guard compact.count >= 2,
                  let unit = compact.last,
                  let value = Double(compact.dropLast()) else {
                continue
            }

            switch unit {
            case "s":
                return value
            case "m":
                return value * 60
            case "h":
                return value * 60 * 60
            case "d":
                return value * 24 * 60 * 60
            case "w":
                return value * 7 * 24 * 60 * 60
            default:
                continue
            }
        }

        return nil
    }

    private static func seconds(value: Double, unit: String) -> TimeInterval? {
        guard value > 0 else { return nil }

        switch unit {
        case "second", "seconds":
            return value
        case "minute", "minutes":
            return value * 60
        case "hour", "hours":
            return value * 60 * 60
        case "day", "days":
            return value * 24 * 60 * 60
        case "week", "weeks":
            return value * 7 * 24 * 60 * 60
        case "month", "months":
            return value * 30 * 24 * 60 * 60
        default:
            return nil
        }
    }
}

public extension AgentQuotaMetric {
    var windowDuration: TimeInterval? {
        AgentQuotaWindowDuration.seconds(metricID: id, title: title)
    }
}

public extension AgentQuotaMetricAggregate {
    var windowDuration: TimeInterval? {
        AgentQuotaWindowDuration.seconds(metricID: id, title: title)
    }
}
