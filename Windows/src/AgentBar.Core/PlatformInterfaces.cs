namespace AgentBar.Core;

public interface IAuthSessionStore
{
    Task<IReadOnlyList<StoredAuthSession>> ListAsync(AgentProviderKind provider, CancellationToken cancellationToken = default);
    Task<StoredAuthSession?> LoadAsync(AgentProviderKind provider, string accountId, CancellationToken cancellationToken = default);
    Task SaveAsync(StoredAuthSession session, CancellationToken cancellationToken = default);
    Task DeleteAsync(AgentProviderKind provider, string accountId, CancellationToken cancellationToken = default);
}

public interface ISettingsStore
{
    Task<AgentBarSettings> LoadAsync(CancellationToken cancellationToken = default);
    Task SaveAsync(AgentBarSettings settings, CancellationToken cancellationToken = default);
}

public interface IBrowserLauncher
{
    Task LaunchAsync(Uri uri, CancellationToken cancellationToken = default);
}

public interface ILocalCallbackServer
{
    Task<OAuthCallback> WaitForCallbackAsync(
        IReadOnlyList<int> preferredPorts,
        string expectedPath,
        TimeSpan timeout,
        CancellationToken cancellationToken = default);
}

public interface ITrayIconRenderer
{
    IconRenderResult Render(IReadOnlyList<TrayStatusBar> bars, int size = 32);
}

public interface IAgentQuotaService
{
    AgentProviderKind Provider { get; }
    ConfiguredAgentAccount Account { get; }
    bool IsAvailable { get; }
    Task<AgentQuotaSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default);
}

public sealed record OAuthCallback(string? Code, string? State, string? Error, int Port);

public sealed record IconRenderResult(System.Drawing.Icon Icon, int Width, int Height, bool HasNonTransparentPixels);

public sealed record AgentBarSettings(
    IReadOnlyList<ConfiguredAgentAccount> Accounts,
    IReadOnlyList<string> MenuBarAccountIds,
    int RefreshIntervalSeconds,
    bool StartHidden)
{
    public const int MaximumTrayAccounts = 1;
    public const int MinimumRefreshIntervalSeconds = 15;
    public const int MaximumRefreshIntervalSeconds = 3600;

    public static AgentBarSettings Default =>
        new([], [], 60, true);

    public AgentBarSettings Normalized()
    {
        var uniqueAccounts = Accounts
            .Where(account => !string.IsNullOrWhiteSpace(account.Directory.Path))
            .GroupBy(account => account.Id, StringComparer.OrdinalIgnoreCase)
            .Select(group => group.First())
            .ToArray();
        var accountIds = uniqueAccounts.Select(account => account.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var menuIds = MenuBarAccountIds
            .Where(accountIds.Contains)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(MaximumTrayAccounts)
            .ToArray();

        return this with
        {
            Accounts = uniqueAccounts,
            MenuBarAccountIds = menuIds,
            RefreshIntervalSeconds = Math.Clamp(
                RefreshIntervalSeconds,
                MinimumRefreshIntervalSeconds,
                MaximumRefreshIntervalSeconds)
        };
    }
}
