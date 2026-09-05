import AgentBarCore
import Foundation
import Testing

@Test
func quotaAggregatesAverageCommonWindowsAcrossAccountsInMetricOrder() {
    let earliestFiveHourReset = Date(timeIntervalSince1970: 1_700_010_000)
    let earliestSevenDayReset = Date(timeIntervalSince1970: 1_700_020_000)
    let aggregates = AgentQuotaMetricAggregation.completeAggregates(
        for: [
            quotaSnapshot(
                accountLabel: "first@example.com",
                metrics: [
                    quotaMetric(
                        id: "window-300",
                        title: "5 hour window",
                        remainingPercent: 100,
                        resetsAt: earliestFiveHourReset.addingTimeInterval(300)
                    ),
                    quotaMetric(
                        id: "window-10080",
                        title: "7 day window",
                        remainingPercent: 90,
                        resetsAt: earliestSevenDayReset.addingTimeInterval(300)
                    ),
                ]
            ),
            quotaSnapshot(
                accountLabel: "second@example.com",
                metrics: [
                    quotaMetric(
                        id: "window-300",
                        title: "5 hour window",
                        remainingPercent: 100,
                        resetsAt: earliestFiveHourReset
                    ),
                    quotaMetric(
                        id: "window-10080",
                        title: "7 day window",
                        remainingPercent: 60,
                        resetsAt: earliestSevenDayReset
                    ),
                ]
            ),
            quotaSnapshot(
                accountLabel: "third@example.com",
                metrics: [
                    quotaMetric(id: "window-300", title: "5 hour window", remainingPercent: 0),
                    quotaMetric(id: "window-10080", title: "7 day window", remainingPercent: 30),
                ]
            ),
        ]
    )

    #expect(aggregates.map(\.id) == ["window-300", "window-10080"])
    #expect(aggregates.map(\.accountCount) == [3, 3])
    #expect(abs(aggregates[0].remainingPercent - 66.666_666) < 0.000_01)
    #expect(aggregates[1].remainingPercent == 60)
    #expect(aggregates.map(\.displayValue) == ["66.67%", "60%"])
    #expect(aggregates.map(\.resetsAt) == [earliestFiveHourReset, earliestSevenDayReset])
}

@Test
func quotaAggregatesSkipWindowsMissingOrRenamedOnAnyAccount() {
    let aggregates = AgentQuotaMetricAggregation.completeAggregates(
        for: [
            quotaSnapshot(
                accountLabel: "first@example.com",
                metrics: [
                    quotaMetric(id: "window-300", title: "5 hour window", remainingPercent: 80),
                    quotaMetric(id: "window-10080", title: "7 day window", remainingPercent: 70),
                    quotaMetric(id: "model-limit", title: "Model A", remainingPercent: 90),
                ]
            ),
            quotaSnapshot(
                accountLabel: "second@example.com",
                metrics: [
                    quotaMetric(id: "window-300", title: "  5   HOUR window ", remainingPercent: 60),
                    quotaMetric(id: "model-limit", title: "Model B", remainingPercent: 50),
                ]
            ),
        ]
    )

    #expect(aggregates.map(\.id) == ["window-300"])
    #expect(aggregates.first?.remainingPercent == 70)
}

@Test
func quotaAggregatesPreserveUnlimitedInsteadOfShowingAFinitePercentage() {
    let aggregates = AgentQuotaMetricAggregation.completeAggregates(
        for: [
            quotaSnapshot(
                accountLabel: "first@example.com",
                metrics: [quotaMetric(id: "monthly", title: "Monthly quota", remainingPercent: 75)]
            ),
            quotaSnapshot(
                accountLabel: "second@example.com",
                metrics: [
                    quotaMetric(
                        id: "monthly",
                        title: "Monthly quota",
                        remainingPercent: 100,
                        remainingLabel: "Unlimited"
                    )
                ]
            ),
        ]
    )

    #expect(aggregates.count == 1)
    #expect(aggregates[0].isUnlimited)
    #expect(aggregates[0].displayValue == "Unlimited")
    #expect(aggregates[0].remainingPercent == 87.5)
}

private func quotaSnapshot(
    accountLabel: String,
    metrics: [AgentQuotaMetric]
) -> AgentQuotaSnapshot {
    AgentQuotaSnapshot(
        provider: .codex,
        accountLabel: accountLabel,
        planType: nil,
        modelName: nil,
        sourceSummary: "Test",
        metrics: metrics,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func quotaMetric(
    id: String,
    title: String,
    remainingPercent: Double,
    remainingLabel: String? = nil,
    resetsAt: Date? = nil
) -> AgentQuotaMetric {
    let usedPercent = 100 - remainingPercent
    return AgentQuotaMetric(
        id: id,
        title: title,
        usedPercent: usedPercent,
        usedLabel: "\(Int(usedPercent.rounded()))% used",
        remainingLabel: remainingLabel ?? "\(Int(remainingPercent.rounded()))% left",
        resetsAt: resetsAt
    )
}
