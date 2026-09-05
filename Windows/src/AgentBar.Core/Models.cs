using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace AgentBar.Core;

public enum AgentProviderKind
{
    Codex,
    GitHubCopilot,
    Gemini,
    Claude,
    Junie
}

public static class AgentProviderKindExtensions
{
    public static IReadOnlyList<AgentProviderKind> All { get; } =
    [
        AgentProviderKind.Codex,
        AgentProviderKind.GitHubCopilot,
        AgentProviderKind.Gemini,
        AgentProviderKind.Claude,
        AgentProviderKind.Junie
    ];

    public static AgentProviderKind FromStoredValue(string? value) => value switch
    {
        "githubCopilot" => AgentProviderKind.GitHubCopilot,
        "gemini" => AgentProviderKind.Gemini,
        "claude" => AgentProviderKind.Claude,
        "junie" => AgentProviderKind.Junie,
        "codex" or "codexCloudAPI" or "localCodex" or "openAIAdminAPI" => AgentProviderKind.Codex,
        _ => AgentProviderKind.Codex
    };

    public static string StoredValue(this AgentProviderKind provider) => provider switch
    {
        AgentProviderKind.Codex => "codex",
        AgentProviderKind.GitHubCopilot => "githubCopilot",
        AgentProviderKind.Gemini => "gemini",
        AgentProviderKind.Claude => "claude",
        AgentProviderKind.Junie => "junie",
        _ => "codex"
    };

    public static string Title(this AgentProviderKind provider) => provider switch
    {
        AgentProviderKind.Codex => "Codex",
        AgentProviderKind.GitHubCopilot => "GitHub Copilot",
        AgentProviderKind.Gemini => "Gemini",
        AgentProviderKind.Claude => "Claude",
        AgentProviderKind.Junie => "Junie",
        _ => provider.StoredValue()
    };

    public static string MenuBarTitlePrefix(this AgentProviderKind provider) => provider switch
    {
        AgentProviderKind.Codex => "Codex",
        AgentProviderKind.GitHubCopilot => "Copilot",
        AgentProviderKind.Gemini => "Gemini",
        AgentProviderKind.Claude => "Claude",
        AgentProviderKind.Junie => "Junie",
        _ => provider.Title()
    };

    public static string MenuBarShortPrefix(this AgentProviderKind provider) => provider switch
    {
        AgentProviderKind.Codex => "cx",
        AgentProviderKind.GitHubCopilot => "cp",
        AgentProviderKind.Gemini => "gm",
        AgentProviderKind.Claude => "cl",
        AgentProviderKind.Junie => "jn",
        _ => "?"
    };

    public static TimeSpan RefreshInterval(this AgentProviderKind provider) => provider switch
    {
        AgentProviderKind.Codex => TimeSpan.FromSeconds(20),
        AgentProviderKind.GitHubCopilot => TimeSpan.FromSeconds(60),
        AgentProviderKind.Gemini => TimeSpan.FromSeconds(30),
        AgentProviderKind.Claude => TimeSpan.FromSeconds(30),
        AgentProviderKind.Junie => TimeSpan.FromSeconds(60),
        _ => TimeSpan.FromSeconds(60)
    };
}

public sealed record ConfiguredAccountDirectory(string Path)
{
    public string DisplayPath => string.IsNullOrWhiteSpace(Path) ? "AgentBar" : Path;
}

public sealed record ConfiguredAgentAccount(AgentProviderKind Provider, ConfiguredAccountDirectory Directory)
{
    public string Id => $"{Provider.StoredValue()}::{Directory.Path}";
    public string DisplayPath => Directory.DisplayPath;
}

public sealed record AgentAccountStatus(
    ConfiguredAgentAccount Account,
    string? AccountLabel,
    AgentQuotaSnapshot? Snapshot,
    string? ErrorMessage,
    bool CredentialsDetected)
{
    public string Id => Account.Id;
    public AgentProviderKind Provider => Account.Provider;
    public string DisplayPath => Account.DisplayPath;
    public string? DisplayLabel => Snapshot?.AccountLabel ?? AccountLabel;
    public bool ShouldDisplayInTray => CredentialsDetected || Snapshot is not null || ErrorMessage is not null;
}

public sealed record AgentQuotaSnapshot(
    AgentProviderKind Provider,
    string AccountLabel,
    string? SpaceLabel,
    string? PlanType,
    string? ModelName,
    string SourceSummary,
    IReadOnlyList<AgentQuotaMetric> Metrics,
    DateTimeOffset UpdatedAt)
{
    public AgentQuotaMetric? HighlightMetric => Metrics.OrderByDescending(metric => metric.UsedPercent).FirstOrDefault();
}

public sealed record AgentQuotaMetric(
    string Id,
    string Title,
    double UsedPercent,
    string UsedLabel,
    string RemainingLabel,
    DateTimeOffset? ResetsAt)
{
    public double RemainingPercent => Math.Max(0, 100 - UsedPercent);
    public string PercentText => $"{Math.Round(RemainingPercent):0}%";
    public TimeSpan? WindowDuration => AgentQuotaWindowDuration.For(Id, Title);

    public static AgentQuotaMetric UsageWindow(int windowMinutes, double usedPercent, DateTimeOffset resetsAt) =>
        new(
            $"window-{windowMinutes}",
            WindowTitle(windowMinutes),
            usedPercent,
            $"{Math.Round(usedPercent):0}% used",
            $"{Math.Round(Math.Max(0, 100 - usedPercent)):0}% left",
            resetsAt);

    public static AgentQuotaMetric CappedUsage(string id, string title, int used, int limit, DateTimeOffset resetsAt)
    {
        var cappedLimit = Math.Max(limit, 1);
        var percent = Math.Min(100, used / (double)cappedLimit * 100);
        return new(id, title, percent, $"{used}/{limit} used", $"{Math.Max(0, limit - used)} left", resetsAt);
    }

    private static string WindowTitle(int windowMinutes) => windowMinutes switch
    {
        60 => "1 hour window",
        300 => "5 hour window",
        1440 => "24 hour window",
        10080 => "7 day window",
        _ when windowMinutes % 1440 == 0 => $"{windowMinutes / 1440} day window",
        _ => $"{windowMinutes} minute window"
    };
}

public sealed record AgentQuotaMetricAggregate(
    string Id,
    string Title,
    int AccountCount,
    double RemainingPercent,
    bool IsUnlimited,
    DateTimeOffset? ResetsAt)
{
    public string DisplayValue => IsUnlimited
        ? "Unlimited"
        : $"{Math.Round(RemainingPercent, 2, MidpointRounding.AwayFromZero).ToString("0.##", CultureInfo.InvariantCulture)}%";
    public TimeSpan? WindowDuration => AgentQuotaWindowDuration.For(Id, Title);
}

public static class AgentQuotaMetricAggregation
{
    public static IReadOnlyList<AgentQuotaMetricAggregate> CompleteAggregates(
        IReadOnlyList<AgentQuotaSnapshot> snapshots)
    {
        if (snapshots.Count <= 1)
        {
            return [];
        }

        var aggregates = new List<AgentQuotaMetricAggregate>();
        foreach (var firstMetric in snapshots[0].Metrics)
        {
            var normalizedTitle = NormalizeTitle(firstMetric.Title);
            var matchingMetrics = snapshots
                .Select(snapshot => snapshot.Metrics.FirstOrDefault(metric =>
                    metric.Id == firstMetric.Id &&
                    NormalizeTitle(metric.Title) == normalizedTitle))
                .ToArray();

            if (matchingMetrics.Any(metric => metric is null))
            {
                continue;
            }

            var loadedMetrics = matchingMetrics.OfType<AgentQuotaMetric>().ToArray();
            var isUnlimited = loadedMetrics.Any(IsUnlimitedMetric);
            var summedRemainingPercent = loadedMetrics.Sum(metric =>
                Math.Clamp(metric.RemainingPercent, 0, 100));
            var remainingPercent = summedRemainingPercent / snapshots.Count;
            var knownResets = loadedMetrics
                .Where(metric => metric.ResetsAt is not null)
                .Select(metric => metric.ResetsAt!.Value)
                .ToArray();
            DateTimeOffset? earliestReset = knownResets.Length == 0 ? null : knownResets.Min();

            aggregates.Add(new AgentQuotaMetricAggregate(
                firstMetric.Id,
                firstMetric.Title,
                snapshots.Count,
                remainingPercent,
                isUnlimited,
                earliestReset));
        }

        return aggregates;
    }

    private static string NormalizeTitle(string title) =>
        string.Join(' ', title.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
            .ToLowerInvariant();

    private static bool IsUnlimitedMetric(AgentQuotaMetric metric) =>
        string.Equals(metric.RemainingLabel.Trim(), "Unlimited", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(metric.UsedLabel.Trim(), "Unlimited", StringComparison.OrdinalIgnoreCase);
}

public sealed record StoredAuthSession(
    AgentProviderKind Provider,
    string AccountId,
    string AccountLabel,
    string AccessToken,
    string? RefreshToken,
    string? IdToken,
    DateTimeOffset? ExpiresAt,
    IReadOnlyList<string> Scopes,
    DateTimeOffset LastRefresh,
    string? SpaceLabel = null,
    string? StorageAccountId = null)
{
    public string LocalAccountId => string.IsNullOrWhiteSpace(StorageAccountId) ? AccountId : StorageAccountId;
}

public sealed record TrayStatusBar(
    AgentProviderKind? Provider,
    string Label,
    double? RemainingPercent,
    bool IsError = false,
    DateTimeOffset? ResetsAt = null,
    TimeSpan? WindowDuration = null);

public enum AgentQuotaDisplayState
{
    Healthy,
    Warning,
    Low,
    Empty
}

public static class AgentQuotaDisplayColor
{
    public static readonly AgentQuotaDisplayRgb Healthy = new(0.20, 0.78, 0.35);
    public static readonly AgentQuotaDisplayRgb Warning = new(0.88, 0.66, 0.08);
    public static readonly AgentQuotaDisplayRgb Low = new(1.00, 0.58, 0.00);
    public static readonly AgentQuotaDisplayRgb Empty = new(1.00, 0.23, 0.19);

    public static AgentQuotaDisplayRgb ForRemainingPercent(double remainingPercent) =>
        ForState(StateForRemainingPercent(remainingPercent));

    public static AgentQuotaDisplayRgb For(
        double remainingPercent,
        DateTimeOffset? resetsAt,
        TimeSpan? windowDuration,
        DateTimeOffset? now = null,
        TimeZoneInfo? timeZone = null) =>
        ForState(StateFor(remainingPercent, resetsAt, windowDuration, now, timeZone));

    public static AgentQuotaDisplayRgb ForMetric(
        AgentQuotaMetric metric,
        DateTimeOffset? now = null,
        TimeZoneInfo? timeZone = null) =>
        For(metric.RemainingPercent, metric.ResetsAt, metric.WindowDuration, now, timeZone);

    public static AgentQuotaDisplayState StateForRemainingPercent(double remainingPercent) => remainingPercent switch
    {
        >= 75 => AgentQuotaDisplayState.Healthy,
        >= 45 => AgentQuotaDisplayState.Warning,
        >= 20 => AgentQuotaDisplayState.Low,
        _ => AgentQuotaDisplayState.Empty
    };

    public static AgentQuotaDisplayState StateFor(
        double remainingPercent,
        DateTimeOffset? resetsAt,
        TimeSpan? windowDuration,
        DateTimeOffset? now = null,
        TimeZoneInfo? timeZone = null)
    {
        var baseline = BaselineRemainingPercent(resetsAt, windowDuration, now, timeZone);
        if (baseline is null)
        {
            return StateForRemainingPercent(remainingPercent);
        }

        var remaining = Math.Clamp(remainingPercent, 0, 100);
        if (remaining < baseline.Value / 2)
        {
            return AgentQuotaDisplayState.Empty;
        }

        return remaining < baseline.Value
            ? AgentQuotaDisplayState.Low
            : AgentQuotaDisplayState.Healthy;
    }

    public static double? BaselineRemainingPercent(
        DateTimeOffset? resetsAt,
        TimeSpan? windowDuration,
        DateTimeOffset? now = null,
        TimeZoneInfo? timeZone = null)
    {
        if (resetsAt is null || windowDuration is null || windowDuration.Value <= TimeSpan.Zero)
        {
            return null;
        }

        var currentTime = now ?? DateTimeOffset.Now;
        var remainingTime = resetsAt.Value - currentTime;
        if (remainingTime <= TimeSpan.Zero)
        {
            return null;
        }

        var zone = timeZone ?? TimeZoneInfo.Local;
        var windowStart = resetsAt.Value - windowDuration.Value;
        // Normalize both intervals so a fresh window still starts at 100%.
        var totalWeekdayTime = WeekdaySeconds(windowStart, resetsAt.Value, zone);
        if (totalWeekdayTime <= 0)
        {
            return 0;
        }

        var remainingStart = currentTime > windowStart ? currentTime : windowStart;
        var remainingWeekdayTime = WeekdaySeconds(remainingStart, resetsAt.Value, zone);
        return Math.Clamp(remainingWeekdayTime / totalWeekdayTime, 0, 1) * 100;
    }

    private static double WeekdaySeconds(DateTimeOffset start, DateTimeOffset end, TimeZoneInfo timeZone)
    {
        var cursor = start;
        var seconds = 0.0;
        while (cursor < end)
        {
            var localDay = TimeZoneInfo.ConvertTime(cursor, timeZone).Date;
            var nextDay = LocalDayStart(localDay.AddDays(1), timeZone);
            var next = nextDay < end ? nextDay : end;
            if (localDay.DayOfWeek is not (DayOfWeek.Saturday or DayOfWeek.Sunday))
            {
                seconds += (next - cursor).TotalSeconds;
            }
            cursor = next;
        }
        return seconds;
    }

    private static DateTimeOffset LocalDayStart(DateTime day, TimeZoneInfo timeZone)
    {
        // Some zones advance or repeat midnight. Use the first valid occurrence.
        while (timeZone.IsInvalidTime(day))
        {
            day = day.AddMinutes(1);
        }
        var offset = timeZone.IsAmbiguousTime(day)
            ? timeZone.GetAmbiguousTimeOffsets(day).Max()
            : timeZone.GetUtcOffset(day);
        return new DateTimeOffset(day, offset);
    }

    public static AgentQuotaDisplayRgb ForState(AgentQuotaDisplayState state) => state switch
    {
        AgentQuotaDisplayState.Healthy => Healthy,
        AgentQuotaDisplayState.Warning => Warning,
        AgentQuotaDisplayState.Low => Low,
        AgentQuotaDisplayState.Empty => Empty,
        _ => Healthy
    };
}

public readonly record struct AgentQuotaDisplayRgb(double Red, double Green, double Blue);

public static class AgentQuotaWindowDuration
{
    private static readonly Regex TrailingWindow = new(
        @"(?:^|-)window-(?<minutes>\d+)$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    private static readonly Regex ExplicitDuration = new(
        @"(?<value>\d+(?:\.\d+)?)\s*(?<unit>seconds?|secs?|s|minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w|months?|mo)\b",
        RegexOptions.Compiled | RegexOptions.CultureInvariant | RegexOptions.IgnoreCase);

    public static TimeSpan? For(string metricId, string title)
    {
        var trailingWindow = TrailingWindow.Match(metricId);
        if (trailingWindow.Success &&
            double.TryParse(
                trailingWindow.Groups["minutes"].Value,
                NumberStyles.Number,
                CultureInfo.InvariantCulture,
                out var minutes) &&
            minutes > 0)
        {
            return TimeSpan.FromMinutes(minutes);
        }

        var normalizedId = metricId.ToLowerInvariant().Replace('-', '_');
        if (normalizedId.Contains("five_hour", StringComparison.Ordinal))
        {
            return TimeSpan.FromHours(5);
        }

        if (normalizedId.Contains("seven_day", StringComparison.Ordinal))
        {
            return TimeSpan.FromDays(7);
        }

        var explicitDuration = ExplicitDuration.Match(title);
        if (explicitDuration.Success &&
            double.TryParse(
                explicitDuration.Groups["value"].Value,
                NumberStyles.Number,
                CultureInfo.InvariantCulture,
                out var value) &&
            value > 0)
        {
            var unit = explicitDuration.Groups["unit"].Value.ToLowerInvariant();
            return unit switch
            {
                "second" or "seconds" or "sec" or "secs" or "s" => TimeSpan.FromSeconds(value),
                "minute" or "minutes" or "min" or "mins" or "m" => TimeSpan.FromMinutes(value),
                "hour" or "hours" or "hr" or "hrs" or "h" => TimeSpan.FromHours(value),
                "day" or "days" or "d" => TimeSpan.FromDays(value),
                "week" or "weeks" or "w" => TimeSpan.FromDays(value * 7),
                "month" or "months" or "mo" => TimeSpan.FromDays(value * 30),
                _ => null
            };
        }

        var normalizedTitle = title.ToLowerInvariant();
        if (normalizedTitle.Contains("weekly", StringComparison.Ordinal))
        {
            return TimeSpan.FromDays(7);
        }

        if (normalizedTitle.Contains("monthly", StringComparison.Ordinal) ||
            normalizedTitle.Contains("/ month", StringComparison.Ordinal))
        {
            return TimeSpan.FromDays(30);
        }

        return null;
    }
}

public static class AccountIdCodec
{
    public static string Encode(string value)
    {
        var bytes = Encoding.UTF8.GetBytes(value);
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    public static string Decode(string value)
    {
        var normalized = value.Replace('-', '+').Replace('_', '/');
        normalized = normalized.PadRight(normalized.Length + (4 - normalized.Length % 4) % 4, '=');
        return Encoding.UTF8.GetString(Convert.FromBase64String(normalized));
    }
}
