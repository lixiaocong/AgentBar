using AgentBar.Core;

namespace AgentBar.Core.Tests;

public sealed class StorageAndInfrastructureTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"AgentBarTests-{Guid.NewGuid():N}");
    private readonly AgentBarPathSet _paths;

    public StorageAndInfrastructureTests()
    {
        _paths = new AgentBarPathSet(_root);
    }

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    [Fact]
    public async Task DpapiVaultRoundTripsAndDeletesSession()
    {
        var store = new DpapiAuthSessionStore(_paths);
        var session = new StoredAuthSession(
            AgentProviderKind.Codex,
            "account-1",
            "dev@example.com",
            "access",
            "refresh",
            "id-token",
            null,
            ["scope"],
            DateTimeOffset.UtcNow);

        await store.SaveAsync(session);
        var loaded = await store.LoadAsync(AgentProviderKind.Codex, "account-1");
        Assert.Equal("access", loaded?.AccessToken);
        Assert.True(File.Exists(_paths.AuthVaultFile));

        await store.DeleteAsync(AgentProviderKind.Codex, "account-1");
        Assert.Null(await store.LoadAsync(AgentProviderKind.Codex, "account-1"));
    }

    [Fact]
    public async Task DpapiVaultReportsCorruptVault()
    {
        Directory.CreateDirectory(_root);
        await File.WriteAllTextAsync(_paths.AuthVaultFile, "not a dpapi payload");
        var store = new DpapiAuthSessionStore(_paths);

        await Assert.ThrowsAsync<AuthSessionStoreException>(async () =>
            await store.LoadAsync(AgentProviderKind.Codex, "account-1"));
    }

    [Fact]
    public async Task SettingsNormalizeTrayLimitAndRefreshInterval()
    {
        var store = new JsonSettingsStore(_paths);
        var accounts = Enumerable.Range(0, 5)
            .Select(index => new ConfiguredAgentAccount(
                AgentProviderKind.Codex,
                new ConfiguredAccountDirectory(_paths.AccountDirectory(AgentProviderKind.Codex, $"account-{index}"))))
            .ToArray();

        await store.SaveAsync(new AgentBarSettings(
            accounts,
            accounts.Select(account => account.Id).ToArray(),
            1,
            true));

        var loaded = await store.LoadAsync();
        Assert.Equal(5, loaded.Accounts.Count);
        Assert.Single(loaded.MenuBarAccountIds);
        Assert.Equal(AgentBarSettings.MinimumRefreshIntervalSeconds, loaded.RefreshIntervalSeconds);
    }

    [Fact]
    public void CallbackParserExtractsCodeStateAndError()
    {
        var callback = TcpLocalCallbackServer.ParseCallback(
            "GET /oauth2callback?code=abc&state=xyz HTTP/1.1",
            "/oauth2callback",
            1458);

        Assert.Equal("abc", callback.Code);
        Assert.Equal("xyz", callback.State);
        Assert.Null(callback.Error);
    }

    [Fact]
    public async Task BrowserLoginRejectsStateMismatchBeforeTokenExchange()
    {
        var store = new InMemoryAuthSessionStore();
        var browser = new FakeBrowserLauncher();
        var callback = new FixedCallbackServer(new OAuthCallback("code", "wrong-state", null, 1457));
        var service = new CodexBrowserLoginService(store, browser, callback);

        await Assert.ThrowsAsync<ProviderBrowserLoginException>(async () => await service.SignInAsync());
        Assert.NotNull(browser.LastUri);
    }
}
