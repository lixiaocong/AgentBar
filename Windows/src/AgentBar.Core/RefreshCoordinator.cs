using System.Security.Cryptography;

namespace AgentBar.Core;

public sealed class RefreshCoordinator(
    ISettingsStore settingsStore,
    IAuthSessionStore authStore,
    AgentQuotaServiceFactory serviceFactory,
    AgentBarPathSet? paths = null)
{
    private readonly AgentBarPathSet _paths = paths ?? AgentBarPaths.Default;
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private AgentBarSettings _settings = AgentBarSettings.Default;
    private IReadOnlyList<AgentAccountStatus> _statuses = [];

    public event EventHandler? Updated;

    public AgentBarSettings Settings => _settings;
    public IReadOnlyList<AgentAccountStatus> AccountStatuses => _statuses;
    public IReadOnlyList<AgentAccountStatus> TrayStatuses => SelectTrayStatuses(_settings, _statuses);
    public IReadOnlyList<TrayStatusBar> TrayBars => BuildTrayBars(TrayStatuses);
    public string TooltipText => BuildTooltip(TrayStatuses, _statuses.Count);
    public bool HasAccounts => _settings.Accounts.Count > 0;

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        _settings = (await settingsStore.LoadAsync(cancellationToken)).Normalized();
        _statuses = _settings.Accounts.Select(account => new AgentAccountStatus(
            account,
            null,
            null,
            null,
            CredentialsDetected(account))).ToArray();
        Updated?.Invoke(this, EventArgs.Empty);
    }

    public async Task RefreshNowAsync(CancellationToken cancellationToken = default)
    {
        await _refreshGate.WaitAsync(cancellationToken);
        try
        {
            _settings = (await settingsStore.LoadAsync(cancellationToken)).Normalized();
            var tasks = _settings.Accounts.Select(account => RefreshAccountAsync(account, cancellationToken)).ToArray();
            _statuses = await Task.WhenAll(tasks);
            Updated?.Invoke(this, EventArgs.Empty);
        }
        finally
        {
            _refreshGate.Release();
        }
    }

    public async Task AddStoredAccountAsync(StoredAuthSession session, CancellationToken cancellationToken = default)
    {
        await authStore.SaveAsync(session, cancellationToken);
        var account = AccountForSession(session);
        await AddOrUpdateAccountAsync(account, showInTray: true, cancellationToken);
    }

    public async Task AddJunieTokenAsync(string token, string? label = null, CancellationToken cancellationToken = default)
    {
        var trimmed = token.Trim();
        if (trimmed.Length == 0)
        {
            throw new ArgumentException("Junie token cannot be empty.", nameof(token));
        }

        var accountId = $"junie-{Convert.ToHexString(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(trimmed)))[..12].ToLowerInvariant()}";
        var session = new StoredAuthSession(
            AgentProviderKind.Junie,
            accountId,
            string.IsNullOrWhiteSpace(label) ? "Junie API Key" : label.Trim(),
            trimmed,
            null,
            null,
            null,
            [],
            DateTimeOffset.UtcNow);
        await AddStoredAccountAsync(session, cancellationToken);
    }

    public async Task AddClaudeDirectoryAsync(string? directory = null, CancellationToken cancellationToken = default)
    {
        var path = string.IsNullOrWhiteSpace(directory) ? AgentBarPaths.ClaudeDefaultDirectory : directory.Trim();
        await AddOrUpdateAccountAsync(
            new ConfiguredAgentAccount(AgentProviderKind.Claude, new ConfiguredAccountDirectory(path)),
            showInTray: true,
            cancellationToken);
    }

    public async Task RemoveAccountAsync(string accountId, CancellationToken cancellationToken = default)
    {
        var settings = (await settingsStore.LoadAsync(cancellationToken)).Normalized();
        var account = settings.Accounts.FirstOrDefault(candidate => string.Equals(candidate.Id, accountId, StringComparison.OrdinalIgnoreCase));
        var updated = settings with
        {
            Accounts = settings.Accounts.Where(candidate => !string.Equals(candidate.Id, accountId, StringComparison.OrdinalIgnoreCase)).ToArray(),
            MenuBarAccountIds = settings.MenuBarAccountIds.Where(id => !string.Equals(id, accountId, StringComparison.OrdinalIgnoreCase)).ToArray()
        };
        await settingsStore.SaveAsync(updated, cancellationToken);

        if (account is not null && account.Provider is not AgentProviderKind.Claude)
        {
            await authStore.DeleteAsync(account.Provider, LocalAccountIdFromDirectory(account), cancellationToken);
        }

        await InitializeAsync(cancellationToken);
    }

    public async Task SetAccountShownInMenuBarAsync(
        string accountId,
        bool shown,
        CancellationToken cancellationToken = default)
    {
        var settings = (await settingsStore.LoadAsync(cancellationToken)).Normalized();
        var ids = settings.MenuBarAccountIds.ToList();
        ids.RemoveAll(id => string.Equals(id, accountId, StringComparison.OrdinalIgnoreCase));
        if (shown)
        {
            ids.Insert(0, accountId);
        }

        await settingsStore.SaveAsync(settings with
        {
            MenuBarAccountIds = ids.Take(AgentBarSettings.MaximumTrayAccounts).ToArray()
        }, cancellationToken);
        await InitializeAsync(cancellationToken);
    }

    public async Task SetRefreshIntervalAsync(int seconds, CancellationToken cancellationToken = default)
    {
        var settings = (await settingsStore.LoadAsync(cancellationToken)).Normalized();
        await settingsStore.SaveAsync(settings with { RefreshIntervalSeconds = seconds }, cancellationToken);
        await InitializeAsync(cancellationToken);
    }

    public async Task ResetMenuBarSelectionAsync(CancellationToken cancellationToken = default)
    {
        var settings = (await settingsStore.LoadAsync(cancellationToken)).Normalized();
        await settingsStore.SaveAsync(settings with { MenuBarAccountIds = [] }, cancellationToken);
        await InitializeAsync(cancellationToken);
    }

    private async Task AddOrUpdateAccountAsync(
        ConfiguredAgentAccount account,
        bool showInTray,
        CancellationToken cancellationToken)
    {
        var settings = (await settingsStore.LoadAsync(cancellationToken)).Normalized();
        var accounts = settings.Accounts.Where(existing => !string.Equals(existing.Id, account.Id, StringComparison.OrdinalIgnoreCase)).ToList();
        accounts.Add(account);
        var menuIds = settings.MenuBarAccountIds.Where(id => !string.Equals(id, account.Id, StringComparison.OrdinalIgnoreCase)).ToList();
        if (showInTray)
        {
            menuIds.Insert(0, account.Id);
        }

        await settingsStore.SaveAsync(settings with
        {
            Accounts = accounts.ToArray(),
            MenuBarAccountIds = menuIds.Take(AgentBarSettings.MaximumTrayAccounts).ToArray()
        }, cancellationToken);
        await InitializeAsync(cancellationToken);
    }

    private async Task<AgentAccountStatus> RefreshAccountAsync(
        ConfiguredAgentAccount account,
        CancellationToken cancellationToken)
    {
        try
        {
            var service = serviceFactory.Create(account);
            var detected = CredentialsDetected(account) || service.IsAvailable;
            if (!detected)
            {
                return new AgentAccountStatus(account, null, null, "Credentials not found.", false);
            }

            var snapshot = await service.LoadSnapshotAsync(cancellationToken);
            return new AgentAccountStatus(account, snapshot.AccountLabel, snapshot, null, true);
        }
        catch (Exception ex)
        {
            return new AgentAccountStatus(account, null, null, ex.Message, CredentialsDetected(account));
        }
    }

    private bool CredentialsDetected(ConfiguredAgentAccount account)
    {
        if (account.Provider == AgentProviderKind.Claude)
        {
            var directory = string.IsNullOrWhiteSpace(account.Directory.Path)
                ? AgentBarPaths.ClaudeDefaultDirectory
                : account.Directory.Path;
            return File.Exists(Path.Combine(directory, ".credentials.json"))
                || File.Exists(Path.Combine(directory, "auth.json"));
        }

        return Directory.Exists(account.Directory.Path);
    }

    private ConfiguredAgentAccount AccountForSession(StoredAuthSession session)
    {
        var directory = _paths.AccountDirectory(session.Provider, session.LocalAccountId);
        return new ConfiguredAgentAccount(session.Provider, new ConfiguredAccountDirectory(directory));
    }

    private static string LocalAccountIdFromDirectory(ConfiguredAgentAccount account)
    {
        var leaf = Path.GetFileName(account.Directory.Path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        if (string.IsNullOrWhiteSpace(leaf))
        {
            return account.Directory.Path;
        }

        try
        {
            return AccountIdCodec.Decode(leaf);
        }
        catch (FormatException)
        {
            return leaf;
        }
    }

    private static IReadOnlyList<AgentAccountStatus> SelectTrayStatuses(
        AgentBarSettings settings,
        IReadOnlyList<AgentAccountStatus> statuses)
    {
        if (statuses.Count == 0)
        {
            return [];
        }

        var byId = statuses.ToDictionary(status => status.Id, StringComparer.OrdinalIgnoreCase);
        var selected = settings.MenuBarAccountIds
            .Select(id => byId.TryGetValue(id, out var status) ? status : null)
            .OfType<AgentAccountStatus>()
            .Take(AgentBarSettings.MaximumTrayAccounts)
            .ToList();
        if (selected.Count > 0)
        {
            return selected;
        }

        return statuses
            .Where(status => status.ShouldDisplayInTray)
            .Take(AgentBarSettings.MaximumTrayAccounts)
            .ToArray();
    }

    private static IReadOnlyList<TrayStatusBar> BuildTrayBars(IReadOnlyList<AgentAccountStatus> statuses)
    {
        if (statuses.Count == 0)
        {
            return [new TrayStatusBar(null, "--", null)];
        }

        return statuses.Take(AgentBarSettings.MaximumTrayAccounts).Select(status =>
        {
            if (status.ErrorMessage is not null)
            {
                return new TrayStatusBar(status.Provider, status.Provider.MenuBarShortPrefix(), null, true);
            }

            return new TrayStatusBar(
                status.Provider,
                status.Provider.MenuBarShortPrefix(),
                status.Snapshot?.HighlightMetric?.RemainingPercent);
        }).ToArray();
    }

    private static string BuildTooltip(IReadOnlyList<AgentAccountStatus> trayStatuses, int totalCount)
    {
        if (totalCount == 0)
        {
            return "AgentBar - no accounts configured";
        }

        var lines = trayStatuses.Select(status =>
        {
            var label = status.DisplayLabel ?? status.Provider.Title();
            if (status.ErrorMessage is not null)
            {
                return $"{status.Provider.MenuBarTitlePrefix()} {label}: {status.ErrorMessage}";
            }

            var metric = status.Snapshot?.HighlightMetric;
            return metric is null
                ? $"{status.Provider.MenuBarTitlePrefix()} {label}: {status.Snapshot?.SourceSummary ?? "No quota windows"}"
                : $"{status.Provider.MenuBarTitlePrefix()} {label}: {metric.RemainingLabel}";
        });
        return string.Join(Environment.NewLine, lines);
    }
}
