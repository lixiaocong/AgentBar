using AgentBar.Core;
using System.Globalization;

namespace AgentBar.Core.Tests;

public sealed class AgentQuotaDisplayColorTests
{
    [Fact]
    public void ColorStateComparesRemainingQuotaWithTimeRemainingBaseline()
    {
        var now = Date("2026-09-04T00:00:00Z");
        var reset = now.AddDays(3);
        var sevenDays = TimeSpan.FromDays(7);
        var baseline = 20.0;

        Assert.Equal(AgentQuotaDisplayState.Healthy, AgentQuotaDisplayColor.StateFor(25, reset, sevenDays, now, TimeZoneInfo.Utc));
        Assert.Equal(AgentQuotaDisplayState.Low, AgentQuotaDisplayColor.StateFor(15, reset, sevenDays, now, TimeZoneInfo.Utc));
        Assert.Equal(AgentQuotaDisplayState.Empty, AgentQuotaDisplayColor.StateFor(9, reset, sevenDays, now, TimeZoneInfo.Utc));
        Assert.Equal(AgentQuotaDisplayState.Healthy, AgentQuotaDisplayColor.StateFor(baseline, reset, sevenDays, now, TimeZoneInfo.Utc));
        Assert.Equal(AgentQuotaDisplayState.Low, AgentQuotaDisplayColor.StateFor(baseline / 2, reset, sevenDays, now, TimeZoneInfo.Utc));
    }

    [Fact]
    public void ColorStateUsesFiveHourWindowBaseline()
    {
        var now = Date("2026-09-02T12:00:00Z");
        var reset = now.AddHours(2.5);
        var fiveHours = TimeSpan.FromHours(5);

        Assert.Equal(50, AgentQuotaDisplayColor.BaselineRemainingPercent(reset, fiveHours, now, TimeZoneInfo.Utc));
        Assert.Equal(AgentQuotaDisplayState.Healthy, AgentQuotaDisplayColor.StateFor(50, reset, fiveHours, now, TimeZoneInfo.Utc));
        Assert.Equal(AgentQuotaDisplayState.Low, AgentQuotaDisplayColor.StateFor(49, reset, fiveHours, now, TimeZoneInfo.Utc));
        Assert.Equal(AgentQuotaDisplayState.Empty, AgentQuotaDisplayColor.StateFor(24, reset, fiveHours, now, TimeZoneInfo.Utc));
    }

    [Fact]
    public void AggregateQuotaUsesAverageBalanceAndEarliestResetAsWindowEnd()
    {
        var now = Date("2026-09-04T00:00:00Z");
        var aggregate = new AgentQuotaMetricAggregate(
            "window-10080",
            "7 day window",
            3,
            50,
            false,
            now.AddDays(3));

        Assert.Equal(
            AgentQuotaDisplayState.Healthy,
            AgentQuotaDisplayColor.StateFor(
                aggregate.RemainingPercent,
                aggregate.ResetsAt,
                aggregate.WindowDuration,
                now,
                TimeZoneInfo.Utc));
        Assert.Equal(20, AgentQuotaDisplayColor.BaselineRemainingPercent(
            aggregate.ResetsAt, aggregate.WindowDuration, now, TimeZoneInfo.Utc));
    }

    [Fact]
    public void BaselineNormalizesTheFullWindowToWeekdays()
    {
        var reset = Date("2026-09-07T00:00:00Z");
        foreach (var now in new[] { reset.AddDays(-7), reset.AddDays(-7).AddHours(-1) })
        {
            Assert.Equal(100, AgentQuotaDisplayColor.BaselineRemainingPercent(
                reset, TimeSpan.FromDays(7), now, TimeZoneInfo.Utc));
        }
        Assert.Equal(5, AgentQuotaDisplayColor.BaselineRemainingPercent(
            reset, TimeSpan.FromDays(30), Date("2026-09-04T00:00:00Z"), TimeZoneInfo.Utc));
    }

    [Theory]
    [InlineData("2026-09-05T00:00:00Z")]
    [InlineData("2026-09-06T12:00:00Z")]
    [InlineData("2026-09-07T00:00:00Z")]
    public void BaselineRemainsConstantDuringTheWeekend(string now)
    {
        Assert.Equal(20, AgentQuotaDisplayColor.BaselineRemainingPercent(
            Date("2026-09-08T00:00:00Z"), TimeSpan.FromDays(7), Date(now), TimeZoneInfo.Utc));
    }

    [Fact]
    public void BaselineIsZeroWhenNoWorkdayRemains()
    {
        var now = Date("2026-09-05T12:00:00Z");
        var reset = now.AddHours(5);
        foreach (var duration in new[] { TimeSpan.FromHours(5), TimeSpan.FromDays(7) })
        {
            Assert.Equal(0, AgentQuotaDisplayColor.BaselineRemainingPercent(reset, duration, now, TimeZoneInfo.Utc));
            Assert.Equal(AgentQuotaDisplayState.Healthy, AgentQuotaDisplayColor.StateFor(10, reset, duration, now, TimeZoneInfo.Utc));
        }
    }

    [Theory]
    [InlineData("2026-09-04T22:00:00Z", "2026-09-05T02:00:00Z", 2.0 / 3.0 * 100)]
    [InlineData("2026-09-06T22:00:00Z", "2026-09-07T02:00:00Z", 100)]
    [InlineData("2026-09-07T01:00:00Z", "2026-09-07T02:00:00Z", 50)]
    public void BaselineCountsPartialWeekdaysAtWeekendBoundaries(string now, string reset, double expected)
    {
        var baseline = AgentQuotaDisplayColor.BaselineRemainingPercent(
            Date(reset), TimeSpan.FromHours(5), Date(now), TimeZoneInfo.Utc);
        Assert.NotNull(baseline);
        Assert.Equal(expected, baseline.Value, 6);
    }

    [Fact]
    public void BaselineAndColorUseTheComputerTimeZone()
    {
        var now = Date("2026-09-04T15:00:00Z");
        var reset = Date("2026-09-04T20:00:00Z");
        var shanghai = TimeZoneInfo.FindSystemTimeZoneById("Asia/Shanghai");
        var metric = new AgentQuotaMetric("window-600", "10 hour window", 75, "75% used", "25% left", reset);
        var baseline = AgentQuotaDisplayColor.BaselineRemainingPercent(reset, metric.WindowDuration, now, shanghai);
        Assert.NotNull(baseline);
        Assert.Equal(100.0 / 6, baseline.Value, 6);
        Assert.Equal(50, AgentQuotaDisplayColor.BaselineRemainingPercent(reset, metric.WindowDuration, now, TimeZoneInfo.Utc));
        Assert.Equal(AgentQuotaDisplayColor.Healthy, AgentQuotaDisplayColor.ForMetric(metric, now, shanghai));
        Assert.Equal(AgentQuotaDisplayColor.Low, AgentQuotaDisplayColor.ForMetric(metric, now, TimeZoneInfo.Utc));
        Assert.Equal(
            AgentQuotaDisplayColor.BaselineRemainingPercent(reset, metric.WindowDuration, now, TimeZoneInfo.Local),
            AgentQuotaDisplayColor.BaselineRemainingPercent(reset, metric.WindowDuration, now));
    }

    [Theory]
    [InlineData("America/New_York", "2026-03-06T00:00:00-05:00", "2026-03-09T00:00:00-04:00", 20)]
    [InlineData("America/New_York", "2026-10-30T00:00:00-04:00", "2026-11-02T00:00:00-05:00", 24.0 / 119 * 100)]
    [InlineData("America/Santiago", "2026-09-04T00:00:00-04:00", "2026-09-07T00:00:00-03:00", 20)]
    public void BaselineUsesLocalDayBoundariesAcrossDST(string zone, string now, string reset, double expected)
    {
        var baseline = AgentQuotaDisplayColor.BaselineRemainingPercent(
            Date(reset), TimeSpan.FromDays(7), Date(now), TimeZoneInfo.FindSystemTimeZoneById(zone));
        Assert.NotNull(baseline);
        Assert.Equal(expected, baseline.Value, 6);
    }

    [Theory]
    [InlineData("window-300", "5 hour window", 5)]
    [InlineData("gpt-5-3-codex-spark-window-10080", "GPT-5.3-Codex-Spark 7 day window", 168)]
    [InlineData("claude-five_hour", "Session (5h)", 5)]
    [InlineData("claude-seven_day_opus", "Opus weekly", 168)]
    [InlineData("zai-token-limit", "Token usage 5 hour window", 5)]
    public void WindowDurationRecognizesKnownFormats(string metricId, string title, double expectedHours)
    {
        Assert.Equal(TimeSpan.FromHours(expectedHours), AgentQuotaWindowDuration.For(metricId, title));
    }

    [Fact]
    public void WindowDurationDoesNotGuessUnknownDynamicQuotaPeriods()
    {
        Assert.Null(AgentQuotaWindowDuration.For("gemini-2.5-pro", "Gemini 2.5 Pro"));
    }

    [Fact]
    public void ColorStateFallsBackToPercentageThresholdsWithoutUsableSchedule()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);

        Assert.Equal(AgentQuotaDisplayState.Warning, AgentQuotaDisplayColor.StateFor(60, null, TimeSpan.FromHours(5), now));
        Assert.Equal(AgentQuotaDisplayState.Warning, AgentQuotaDisplayColor.StateFor(60, now.AddSeconds(-1), TimeSpan.FromHours(5), now));
        Assert.Equal(AgentQuotaDisplayState.Warning, AgentQuotaDisplayColor.StateFor(60, now.AddMinutes(1), null, now));
        Assert.Null(AgentQuotaDisplayColor.BaselineRemainingPercent(now.AddMinutes(1), TimeSpan.Zero, now));
        Assert.Null(AgentQuotaDisplayColor.BaselineRemainingPercent(now.AddMinutes(1), TimeSpan.FromHours(-1), now));
    }

    private static DateTimeOffset Date(string value) => DateTimeOffset.Parse(value, CultureInfo.InvariantCulture);
}
