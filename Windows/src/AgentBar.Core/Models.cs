using System.Text;

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
        AgentProviderKind.Codex => "C",
        AgentProviderKind.GitHubCopilot => "P",
        AgentProviderKind.Gemini => "G",
        AgentProviderKind.Claude => "Cl",
        AgentProviderKind.Junie => "J",
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
    bool IsError = false);

public static class AgentQuotaDisplayColor
{
    public static readonly AgentQuotaDisplayRgb Healthy = new(0.20, 0.78, 0.35);
    public static readonly AgentQuotaDisplayRgb Warning = new(0.88, 0.66, 0.08);
    public static readonly AgentQuotaDisplayRgb Low = new(1.00, 0.58, 0.00);
    public static readonly AgentQuotaDisplayRgb Empty = new(1.00, 0.23, 0.19);

    public static AgentQuotaDisplayRgb ForRemainingPercent(double remainingPercent) => remainingPercent switch
    {
        >= 75 => Healthy,
        >= 45 => Warning,
        >= 20 => Low,
        _ => Empty
    };
}

public readonly record struct AgentQuotaDisplayRgb(double Red, double Green, double Blue);

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
