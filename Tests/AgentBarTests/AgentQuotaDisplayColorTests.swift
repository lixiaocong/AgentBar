import AgentBarCore
import Foundation
import Testing

@Test
func quotaColorComparesRemainingQuotaWithTimeRemainingBaseline() {
    let now = quotaColorTestDate("2026-09-04T00:00:00Z")
    let sevenDays: TimeInterval = 7 * 24 * 60 * 60
    let resetsInThreeDays = now.addingTimeInterval(3 * 24 * 60 * 60)
    let baseline = 20.0

    #expect(
        AgentQuotaDisplayColor.state(
            for: 25,
            resetsAt: resetsInThreeDays,
            windowDuration: sevenDays,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .healthy
    )
    #expect(
        AgentQuotaDisplayColor.state(
            for: 15,
            resetsAt: resetsInThreeDays,
            windowDuration: sevenDays,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .low
    )
    #expect(
        AgentQuotaDisplayColor.state(
            for: 9,
            resetsAt: resetsInThreeDays,
            windowDuration: sevenDays,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .empty
    )
    #expect(
        AgentQuotaDisplayColor.state(
            for: baseline,
            resetsAt: resetsInThreeDays,
            windowDuration: sevenDays,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .healthy
    )
    #expect(
        AgentQuotaDisplayColor.state(
            for: baseline / 2,
            resetsAt: resetsInThreeDays,
            windowDuration: sevenDays,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .low
    )
}

@Test
func quotaColorUsesFiveHourWindowBaseline() {
    let now = quotaColorTestDate("2026-09-02T12:00:00Z")
    let fiveHours: TimeInterval = 5 * 60 * 60
    let reset = now.addingTimeInterval(2.5 * 60 * 60)

    #expect(
        AgentQuotaDisplayColor.baselineRemainingPercent(
            resetsAt: reset,
            windowDuration: fiveHours,
            now: now,
            timeZone: quotaColorTestUTC
        ) == 50
    )

    #expect(
        AgentQuotaDisplayColor.state(
            for: 50,
            resetsAt: reset,
            windowDuration: fiveHours,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .healthy
    )
    #expect(
        AgentQuotaDisplayColor.state(
            for: 49,
            resetsAt: reset,
            windowDuration: fiveHours,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .low
    )
    #expect(
        AgentQuotaDisplayColor.state(
            for: 24,
            resetsAt: reset,
            windowDuration: fiveHours,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .empty
    )
}

@Test
func aggregateQuotaUsesAverageBalanceAndEarliestResetAsItsWindowEnd() {
    let now = quotaColorTestDate("2026-09-04T00:00:00Z")
    let aggregate = AgentQuotaMetricAggregate(
        id: "window-10080",
        title: "7 day window",
        accountCount: 3,
        remainingPercent: 50,
        isUnlimited: false,
        resetsAt: now.addingTimeInterval(3 * 24 * 60 * 60)
    )

    #expect(
        AgentQuotaDisplayColor.state(
            for: aggregate.remainingPercent,
            resetsAt: aggregate.resetsAt,
            windowDuration: aggregate.windowDuration,
            now: now,
            timeZone: quotaColorTestUTC
        ) == .healthy
    )
    #expect(
        AgentQuotaDisplayColor.baselineRemainingPercent(
            resetsAt: aggregate.resetsAt,
            windowDuration: aggregate.windowDuration,
            now: now,
            timeZone: quotaColorTestUTC
        ) == 20
    )
}

@Test
func quotaBaselineNormalizesTheFullWindowToWeekdays() {
    let reset = quotaColorTestDate("2026-09-07T00:00:00Z")
    let duration: TimeInterval = 7 * 24 * 60 * 60
    for now in [reset.addingTimeInterval(-duration), reset.addingTimeInterval(-duration - 3600)] {
        #expect(AgentQuotaDisplayColor.baselineRemainingPercent(
            resetsAt: reset, windowDuration: duration, now: now, timeZone: quotaColorTestUTC
        ) == 100)
    }

    #expect(AgentQuotaDisplayColor.baselineRemainingPercent(
        resetsAt: reset,
        windowDuration: 30 * 24 * 60 * 60,
        now: quotaColorTestDate("2026-09-04T00:00:00Z"),
        timeZone: quotaColorTestUTC
    ) == 5)
}

@Test
func quotaBaselineRemainsConstantDuringTheWeekend() {
    let reset = quotaColorTestDate("2026-09-08T00:00:00Z")
    for now in ["2026-09-05T00:00:00Z", "2026-09-06T12:00:00Z", "2026-09-07T00:00:00Z"] {
        #expect(AgentQuotaDisplayColor.baselineRemainingPercent(
            resetsAt: reset,
            windowDuration: 7 * 24 * 60 * 60,
            now: quotaColorTestDate(now),
            timeZone: quotaColorTestUTC
        ) == 20)
    }
}

@Test
func quotaBaselineIsZeroWhenNoWorkdayRemains() {
    let now = quotaColorTestDate("2026-09-05T12:00:00Z")
    let reset = now.addingTimeInterval(5 * 60 * 60)
    for duration in [TimeInterval(5 * 60 * 60), TimeInterval(7 * 24 * 60 * 60)] {
        #expect(AgentQuotaDisplayColor.baselineRemainingPercent(
            resetsAt: reset, windowDuration: duration, now: now, timeZone: quotaColorTestUTC
        ) == 0)
        #expect(AgentQuotaDisplayColor.state(
            for: 10, resetsAt: reset, windowDuration: duration, now: now, timeZone: quotaColorTestUTC
        ) == .healthy)
    }
}

@Test
func quotaBaselineCountsPartialWeekdaysAtWeekendBoundaries() throws {
    let cases: [(String, String, Double)] = [
        ("2026-09-04T22:00:00Z", "2026-09-05T02:00:00Z", 2.0 / 3.0 * 100),
        ("2026-09-06T22:00:00Z", "2026-09-07T02:00:00Z", 100),
        ("2026-09-07T01:00:00Z", "2026-09-07T02:00:00Z", 50),
    ]
    for (now, reset, expected) in cases {
        let baseline = try #require(AgentQuotaDisplayColor.baselineRemainingPercent(
            resetsAt: quotaColorTestDate(reset),
            windowDuration: 5 * 60 * 60,
            now: quotaColorTestDate(now),
            timeZone: quotaColorTestUTC
        ))
        #expect(abs(baseline - expected) < 0.000_001)
    }
}

@Test
func quotaBaselineAndColorUseTheComputerTimeZone() throws {
    let now = quotaColorTestDate("2026-09-04T15:00:00Z")
    let reset = quotaColorTestDate("2026-09-04T20:00:00Z")
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let metric = AgentQuotaMetric(
        id: "window-600", title: "10 hour window", usedPercent: 75,
        usedLabel: "75% used", remainingLabel: "25% left", resetsAt: reset
    )
    let baseline = try #require(AgentQuotaDisplayColor.baselineRemainingPercent(
        resetsAt: reset, windowDuration: metric.windowDuration, now: now, timeZone: shanghai
    ))
    #expect(abs(baseline - 100.0 / 6) < 0.000_001)
    #expect(AgentQuotaDisplayColor.baselineRemainingPercent(
        resetsAt: reset, windowDuration: metric.windowDuration, now: now, timeZone: quotaColorTestUTC
    ) == 50)
    #expect(AgentQuotaDisplayColor.color(for: metric, now: now, timeZone: shanghai)
        == AgentQuotaDisplayColor.healthy)
    #expect(AgentQuotaDisplayColor.color(for: metric, now: now, timeZone: quotaColorTestUTC)
        == AgentQuotaDisplayColor.low)
    #expect(AgentQuotaDisplayColor.baselineRemainingPercent(
        resetsAt: reset, windowDuration: metric.windowDuration, now: now
    ) == AgentQuotaDisplayColor.baselineRemainingPercent(
        resetsAt: reset, windowDuration: metric.windowDuration, now: now, timeZone: .current
    ))
}

@Test
func quotaBaselineUsesLocalDayBoundariesAcrossDST() throws {
    let cases: [(String, String, String, Double)] = [
        ("America/New_York", "2026-03-06T00:00:00-05:00", "2026-03-09T00:00:00-04:00", 20),
        ("America/New_York", "2026-10-30T00:00:00-04:00", "2026-11-02T00:00:00-05:00", 24.0 / 119 * 100),
        ("America/Santiago", "2026-09-04T00:00:00-04:00", "2026-09-07T00:00:00-03:00", 20),
    ]
    for (zone, now, reset, expected) in cases {
        let timeZone = try #require(TimeZone(identifier: zone))
        let baseline = try #require(AgentQuotaDisplayColor.baselineRemainingPercent(
            resetsAt: quotaColorTestDate(reset),
            windowDuration: 7 * 24 * 60 * 60,
            now: quotaColorTestDate(now),
            timeZone: timeZone
        ))
        #expect(abs(baseline - expected) < 0.000_001)
    }
}

@Test
func quotaWindowDurationRecognizesKnownWindowFormats() {
    #expect(
        AgentQuotaWindowDuration.seconds(metricID: "window-300", title: "5 hour window") == TimeInterval(5 * 60 * 60)
    )
    #expect(
        AgentQuotaWindowDuration.seconds(
            metricID: "gpt-5-3-codex-spark-window-10080",
            title: "GPT-5.3-Codex-Spark 7 day window"
        ) == TimeInterval(7 * 24 * 60 * 60)
    )
    #expect(
        AgentQuotaWindowDuration.seconds(metricID: "claude-five_hour", title: "Session (5h)") == TimeInterval(5 * 60 * 60)
    )
    #expect(
        AgentQuotaWindowDuration.seconds(metricID: "claude-seven_day_opus", title: "Opus weekly") == TimeInterval(7 * 24 * 60 * 60)
    )
    #expect(
        AgentQuotaWindowDuration.seconds(metricID: "zai-token-limit", title: "Token usage 5 hour window") == TimeInterval(5 * 60 * 60)
    )
    #expect(
        AgentQuotaWindowDuration.seconds(metricID: "gemini-2.5-pro", title: "Gemini 2.5 Pro") == nil
    )
}

@Test
func quotaColorFallsBackToPercentageThresholdsWithoutAUsableSchedule() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    for duration in [TimeInterval.zero, -1, .infinity, .nan] {
        #expect(AgentQuotaDisplayColor.baselineRemainingPercent(
            resetsAt: now.addingTimeInterval(60), windowDuration: duration, now: now
        ) == nil)
    }

    #expect(
        AgentQuotaDisplayColor.state(
            for: 60,
            resetsAt: nil,
            windowDuration: 5 * 60 * 60,
            now: now
        ) == .warning
    )
    #expect(
        AgentQuotaDisplayColor.state(
            for: 60,
            resetsAt: now.addingTimeInterval(-1),
            windowDuration: 5 * 60 * 60,
            now: now
        ) == .warning
    )
    #expect(
        AgentQuotaDisplayColor.state(
            for: 60,
            resetsAt: now.addingTimeInterval(60),
            windowDuration: nil,
            now: now
        ) == .warning
    )
}

private let quotaColorTestUTC = TimeZone(secondsFromGMT: 0)!

private func quotaColorTestDate(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
}
