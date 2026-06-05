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
    public void SettingsDefaultsMatchMacRefreshPolicy()
    {
        var defaults = AgentBarSettings.Default.Normalized();

        Assert.Equal(10, defaults.RefreshIntervalSeconds);
        Assert.Equal(5, AgentBarSettings.MinimumRefreshIntervalSeconds);
        Assert.Equal(300, AgentBarSettings.MaximumRefreshIntervalSeconds);
        Assert.Equal(5, AgentBarSettings.RefreshIntervalStepSeconds);
    }

    [Fact]
    public void ProviderShortLabelsMatchMacStatusIconLabels()
    {
        Assert.Equal("cx", AgentProviderKind.Codex.MenuBarShortPrefix());
        Assert.Equal("cp", AgentProviderKind.GitHubCopilot.MenuBarShortPrefix());
        Assert.Equal("gm", AgentProviderKind.Gemini.MenuBarShortPrefix());
        Assert.Equal("cl", AgentProviderKind.Claude.MenuBarShortPrefix());
        Assert.Equal("jn", AgentProviderKind.Junie.MenuBarShortPrefix());
    }

    [Fact]
    public async Task CoordinatorAutoDetectsDefaultClaudeCredentials()
    {
        var claudeRoot = Path.Combine(_root, "claude-default");
        Directory.CreateDirectory(claudeRoot);
        await File.WriteAllTextAsync(Path.Combine(claudeRoot, "auth.json"), "{}");
        var paths = new AgentBarPathSet(_root, claudeRoot);
        var coordinator = new RefreshCoordinator(
            new JsonSettingsStore(paths),
            new InMemoryAuthSessionStore(),
            new FakeAgentQuotaServiceFactory(account => new FakeAgentQuotaService(account)),
            paths);

        await coordinator.InitializeAsync();

        var status = Assert.Single(coordinator.AccountStatuses);
        Assert.Equal(AgentProviderKind.Claude, status.Provider);
        Assert.Equal(claudeRoot, status.Account.Directory.Path);
        Assert.True(status.CredentialsDetected);
    }

    [Fact]
    public async Task CoordinatorRejectsClaudeDirectoryWithoutCredentials()
    {
        var coordinator = new RefreshCoordinator(
            new JsonSettingsStore(_paths),
            new InMemoryAuthSessionStore(),
            new FakeAgentQuotaServiceFactory(account => new FakeAgentQuotaService(account)),
            _paths);

        await Assert.ThrowsAsync<InvalidOperationException>(async () =>
            await coordinator.AddClaudeDirectoryAsync(Path.Combine(_root, "empty-claude")));
    }

    [Fact]
    public async Task RefreshPreservesStoredAccountLabelOnAccountError()
    {
        var authStore = new InMemoryAuthSessionStore();
        var account = new ConfiguredAgentAccount(
            AgentProviderKind.Codex,
            new ConfiguredAccountDirectory(_paths.AccountDirectory(AgentProviderKind.Codex, "codex-account")));
        await authStore.SaveAsync(new StoredAuthSession(
            AgentProviderKind.Codex,
            "codex-account",
            "dev@example.com",
            "access",
            "refresh",
            "id",
            null,
            [],
            DateTimeOffset.UtcNow));
        await new JsonSettingsStore(_paths).SaveAsync(new AgentBarSettings([account], [account.Id], 10, true));
        var coordinator = new RefreshCoordinator(
            new JsonSettingsStore(_paths),
            authStore,
            new FakeAgentQuotaServiceFactory(candidate => new FakeAgentQuotaService(
                candidate,
                exception: new ProviderQuotaException("offline"))),
            _paths);

        await coordinator.InitializeAsync();
        await coordinator.RefreshNowAsync();

        var status = Assert.Single(coordinator.AccountStatuses);
        Assert.Equal("dev@example.com", status.DisplayLabel);
        Assert.Equal("offline", status.ErrorMessage);
    }

    [Fact]
    public async Task RefreshRemovesInvalidGeminiLoginLikeMac()
    {
        var authStore = new InMemoryAuthSessionStore();
        var account = new ConfiguredAgentAccount(
            AgentProviderKind.Gemini,
            new ConfiguredAccountDirectory(_paths.AccountDirectory(AgentProviderKind.Gemini, "gemini-account")));
        await authStore.SaveAsync(new StoredAuthSession(
            AgentProviderKind.Gemini,
            "gemini-account",
            "gemini@example.com",
            "access",
            "refresh",
            null,
            null,
            [],
            DateTimeOffset.UtcNow));
        await new JsonSettingsStore(_paths).SaveAsync(new AgentBarSettings([account], [account.Id], 10, true));
        var coordinator = new RefreshCoordinator(
            new JsonSettingsStore(_paths),
            authStore,
            new FakeAgentQuotaServiceFactory(candidate => new FakeAgentQuotaService(
                candidate,
                exception: new ProviderQuotaException(
                    "invalid_grant",
                    statusCode: 400,
                    invalidatesStoredLogin: true))),
            _paths);

        await coordinator.InitializeAsync();
        await coordinator.RefreshNowAsync();

        Assert.Empty(coordinator.Settings.Accounts);
        Assert.Empty(coordinator.AccountStatuses);
        Assert.Null(await authStore.LoadAsync(AgentProviderKind.Gemini, "gemini-account"));
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
