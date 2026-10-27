using AgentBar.Core;

namespace AgentBar.Core.Tests;

public sealed class AgentQuotaMetricAggregationTests
{
    [Fact]
    public void CompleteAggregatesAveragesCommonWindowsAcrossAccountsInMetricOrder()
    {
        var earliestFiveHourReset = DateTimeOffset.FromUnixTimeSeconds(1_700_010_000);
        var earliestSevenDayReset = DateTimeOffset.FromUnixTimeSeconds(1_700_020_000);
        var aggregates = AgentQuotaMetricAggregation.CompleteAggregates(
        [
            Snapshot("first@example.com",
                Metric("window-300", "5 hour window", 100, resetsAt: earliestFiveHourReset.AddMinutes(5)),
                Metric("window-10080", "7 day window", 90, resetsAt: earliestSevenDayReset.AddMinutes(5))),
            Snapshot("second@example.com",
                Metric("window-300", "5 hour window", 100, resetsAt: earliestFiveHourReset),
                Metric("window-10080", "7 day window", 60, resetsAt: earliestSevenDayReset)),
            Snapshot("third@example.com",
                Metric("window-300", "5 hour window", 0),
                Metric("window-10080", "7 day window", 30))
        ]);

        Assert.Equal(new[] { "window-300", "window-10080" }, aggregates.Select(aggregate => aggregate.Id));
        Assert.Equal(66.666_666, aggregates[0].RemainingPercent, precision: 5);
        Assert.Equal(60, aggregates[1].RemainingPercent);
        Assert.Equal(new[] { "66.67%", "60%" }, aggregates.Select(aggregate => aggregate.DisplayValue));
        Assert.Equal(new DateTimeOffset?[] { earliestFiveHourReset, earliestSevenDayReset }, aggregates.Select(aggregate => aggregate.ResetsAt));
    }

    [Fact]
    public void CompleteAggregatesSkipsMissingOrRenamedWindows()
    {
        var aggregates = AgentQuotaMetricAggregation.CompleteAggregates(
        [
            Snapshot("first@example.com",
                Metric("window-300", "5 hour window", 80),
                Metric("window-10080", "7 day window", 70),
                Metric("model-limit", "Model A", 90)),
            Snapshot("second@example.com",
                Metric("window-300", "  5   HOUR window ", 60),
                Metric("model-limit", "Model B", 50))
        ]);

        var aggregate = Assert.Single(aggregates);
        Assert.Equal("window-300", aggregate.Id);
        Assert.Equal(70, aggregate.RemainingPercent);
    }

    [Fact]
    public void CompleteAggregatesPreservesUnlimited()
    {
        var aggregates = AgentQuotaMetricAggregation.CompleteAggregates(
        [
            Snapshot("first@example.com", Metric("monthly", "Monthly quota", 75)),
            Snapshot("second@example.com", Metric("monthly", "Monthly quota", 100, "Unlimited"))
        ]);

        var aggregate = Assert.Single(aggregates);
        Assert.True(aggregate.IsUnlimited);
        Assert.Equal("Unlimited", aggregate.DisplayValue);
        Assert.Equal(87.5, aggregate.RemainingPercent);
    }

    [Fact]
    public void GptReserveQuotaRemainsVisibleButDoesNotDriveOverallStatus()
    {
        var primary = Metric("window-10080", "7 day window", 69);
        var reserve = Metric("additional-1-window-10080", "GPT-Reserve 7 day window", 1);
        var snapshot = Snapshot("first@example.com", primary, reserve);

        Assert.Equal(new[] { primary.Id, reserve.Id }, snapshot.Metrics.Select(metric => metric.Id));
        Assert.True(primary.ParticipatesInOverallQuotaStatus);
        Assert.False(reserve.ParticipatesInOverallQuotaStatus);
        Assert.Equal(primary.Id, snapshot.HighlightMetric?.Id);
    }

    [Fact]
    public void GptReserveQuotaIsExcludedFromMultiAccountTotals()
    {
        var snapshots = new[] { "first@example.com", "second@example.com" }
            .Select(account => Snapshot(
                account,
                Metric("window-10080", "7 day window", 60),
                Metric("additional-1-window-10080", "gpt reserve 7 day window", 1)))
            .ToArray();

        var aggregate = Assert.Single(AgentQuotaMetricAggregation.CompleteAggregates(snapshots));
        Assert.Equal("window-10080", aggregate.Id);
    }

    private static AgentQuotaSnapshot Snapshot(string accountLabel, params AgentQuotaMetric[] metrics) =>
        new(
            AgentProviderKind.Codex,
            accountLabel,
            null,
            null,
            null,
            "Test",
            metrics,
            DateTimeOffset.UnixEpoch);

    private static AgentQuotaMetric Metric(
        string id,
        string title,
        double remainingPercent,
        string? remainingLabel = null,
        DateTimeOffset? resetsAt = null)
    {
        var usedPercent = 100 - remainingPercent;
        return new AgentQuotaMetric(
            id,
            title,
            usedPercent,
            $"{usedPercent:0}% used",
            remainingLabel ?? $"{remainingPercent:0}% left",
            resetsAt);
    }
}
