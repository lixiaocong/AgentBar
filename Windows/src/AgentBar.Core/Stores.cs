using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AgentBar.Core;

public sealed record AgentBarPathSet(string RootDirectory)
{
    public string SettingsFile => Path.Combine(RootDirectory, "settings.json");
    public string AuthVaultFile => Path.Combine(RootDirectory, "auth-vault.json.dpapi");
    public string AccountsRoot => Path.Combine(RootDirectory, "Accounts");

    public string AccountsDirectory(AgentProviderKind provider) =>
        Path.Combine(AccountsRoot, provider.StoredValue());

    public string AccountDirectory(AgentProviderKind provider, string accountId) =>
        Path.Combine(AccountsDirectory(provider), AccountIdCodec.Encode(accountId));
}

public static class AgentBarPaths
{
    public static AgentBarPathSet Default { get; } = new(
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AgentBar"));

    public static string ClaudeDefaultDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".claude");

    public static IEnumerable<string> DefaultJetBrainsQuotaCacheFiles()
    {
        var root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "JetBrains");
        if (!Directory.Exists(root))
        {
            yield break;
        }

        foreach (var productDirectory in Directory.EnumerateDirectories(root))
        {
            var file = Path.Combine(productDirectory, "options", "AIAssistantQuotaManager2.xml");
            if (File.Exists(file))
            {
                yield return file;
            }
        }
    }
}

public sealed class JsonSettingsStore(AgentBarPathSet? paths = null) : ISettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = JsonOptionsFactory.Create();
    private readonly AgentBarPathSet _paths = paths ?? AgentBarPaths.Default;

    public async Task<AgentBarSettings> LoadAsync(CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_paths.SettingsFile))
        {
            return AgentBarSettings.Default;
        }

        await using var stream = File.OpenRead(_paths.SettingsFile);
        var settings = await JsonSerializer.DeserializeAsync<AgentBarSettings>(
            stream,
            JsonOptions,
            cancellationToken);
        return (settings ?? AgentBarSettings.Default).Normalized();
    }

    public async Task SaveAsync(AgentBarSettings settings, CancellationToken cancellationToken = default)
    {
        Directory.CreateDirectory(_paths.RootDirectory);
        var normalized = settings.Normalized();
        var tempFile = _paths.SettingsFile + ".tmp";
        await using (var stream = File.Create(tempFile))
        {
            await JsonSerializer.SerializeAsync(stream, normalized, JsonOptions, cancellationToken);
        }

        File.Move(tempFile, _paths.SettingsFile, overwrite: true);
        foreach (var account in normalized.Accounts)
        {
            Directory.CreateDirectory(account.Directory.Path);
        }
    }
}

public sealed class DpapiAuthSessionStore(AgentBarPathSet? paths = null) : IAuthSessionStore
{
    private static readonly JsonSerializerOptions JsonOptions = JsonOptionsFactory.Create();
    private static readonly byte[] Entropy = "AgentBar.Windows.AuthVault.v1"u8.ToArray();
    private readonly AgentBarPathSet _paths = paths ?? AgentBarPaths.Default;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public async Task<IReadOnlyList<StoredAuthSession>> ListAsync(
        AgentProviderKind provider,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var vault = await LoadVaultUnlockedAsync(cancellationToken);
            return vault.Sessions.Values
                .Where(session => session.Provider == provider)
                .OrderBy(session => session.AccountLabel, StringComparer.CurrentCultureIgnoreCase)
                .ToArray();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task<StoredAuthSession?> LoadAsync(
        AgentProviderKind provider,
        string accountId,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var vault = await LoadVaultUnlockedAsync(cancellationToken);
            return vault.Sessions.TryGetValue(Key(provider, accountId), out var session) ? session : null;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task SaveAsync(StoredAuthSession session, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var vault = await LoadVaultUnlockedAsync(cancellationToken);
            vault.Sessions[Key(session.Provider, session.LocalAccountId)] = session;
            Directory.CreateDirectory(_paths.AccountDirectory(session.Provider, session.LocalAccountId));
            await SaveVaultUnlockedAsync(vault, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task DeleteAsync(
        AgentProviderKind provider,
        string accountId,
        CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var vault = await LoadVaultUnlockedAsync(cancellationToken);
            vault.Sessions.Remove(Key(provider, accountId));
            await SaveVaultUnlockedAsync(vault, cancellationToken);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<AuthVault> LoadVaultUnlockedAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_paths.AuthVaultFile))
        {
            return new AuthVault();
        }

        try
        {
            var protectedBytes = await File.ReadAllBytesAsync(_paths.AuthVaultFile, cancellationToken);
            var jsonBytes = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            return JsonSerializer.Deserialize<AuthVault>(jsonBytes, JsonOptions) ?? new AuthVault();
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException or IOException)
        {
            throw new AuthSessionStoreException("AgentBar auth vault could not be read.", ex);
        }
    }

    private async Task SaveVaultUnlockedAsync(AuthVault vault, CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(_paths.RootDirectory);
        var jsonBytes = JsonSerializer.SerializeToUtf8Bytes(vault, JsonOptions);
        var protectedBytes = ProtectedData.Protect(jsonBytes, Entropy, DataProtectionScope.CurrentUser);
        var tempFile = _paths.AuthVaultFile + ".tmp";
        await File.WriteAllBytesAsync(tempFile, protectedBytes, cancellationToken);
        File.Move(tempFile, _paths.AuthVaultFile, overwrite: true);
    }

    private static string Key(AgentProviderKind provider, string accountId) =>
        $"{provider.StoredValue()}::{accountId}";
}

public sealed class AuthSessionStoreException(string message, Exception innerException)
    : Exception(message, innerException);

internal sealed class AuthVault
{
    public int Version { get; set; } = 1;
    public Dictionary<string, StoredAuthSession> Sessions { get; set; } = new(StringComparer.OrdinalIgnoreCase);
}

internal static class JsonOptionsFactory
{
    public static JsonSerializerOptions Create()
    {
        var options = new JsonSerializerOptions(JsonSerializerDefaults.Web)
        {
            WriteIndented = true
        };
        options.Converters.Add(new JsonStringEnumConverter());
        return options;
    }
}
