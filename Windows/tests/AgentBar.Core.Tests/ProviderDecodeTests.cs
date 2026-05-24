using AgentBar.Core;

namespace AgentBar.Core.Tests;

public sealed class ProviderDecodeTests
{
    private static readonly ConfiguredAgentAccount Account = new(
        AgentProviderKind.Codex,
        new ConfiguredAccountDirectory("test"));

    [Fact]
    public void CodexDecodeMatchesSharedFixture()
    {
        var service = new CodexQuotaService(Account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            Fixture.Bytes("codex", "usage-team.json"),
            "Account test",
            "Newsbreak-BJ",
            DateTimeOffset.FromUnixTimeSeconds(1_775_600_000));

        Fixture.AssertSnapshotMatches(snapshot, "expected", "codex-team.json");
    }

    [Fact]
    public void GitHubCopilotDecodeMatchesSharedFixture()
    {
        var account = Account with { Provider = AgentProviderKind.GitHubCopilot };
        var service = new GitHubCopilotQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            Fixture.Bytes("copilot", "premium.json"),
            DateTimeOffset.FromUnixTimeSeconds(1_744_160_000));

        Fixture.AssertSnapshotMatches(snapshot, "expected", "copilot-premium.json");
    }

    [Fact]
    public void GeminiDecodeMatchesSharedFixture()
    {
        var account = Account with { Provider = AgentProviderKind.Gemini };
        var service = new GeminiQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            Fixture.Bytes("gemini", "code-assist-free.json"),
            Fixture.Bytes("gemini", "quota-free.json"),
            "test@example.com",
            DateTimeOffset.UtcNow);

        Fixture.AssertSnapshotMatches(snapshot, "expected", "gemini-free.json");
    }

    [Fact]
    public void ClaudeDecodeMatchesSharedFixture()
    {
        var account = Account with { Provider = AgentProviderKind.Claude };
        var service = new ClaudeQuotaService(account);
        var snapshot = service.DecodeSnapshot(
            Fixture.Bytes("claude", "subscription-auth.json"),
            DateTimeOffset.FromUnixTimeSeconds(1_744_160_000));

        Fixture.AssertSnapshotMatches(snapshot, "expected", "claude-subscription.json");
    }

    [Fact]
    public void JunieDecodeMatchesSharedFixture()
    {
        var account = Account with { Provider = AgentProviderKind.Junie };
        var service = new JunieQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient(), []);
        var snapshot = service.DecodeSnapshot(
            Fixture.Bytes("junie", "auth-info.json"),
            Fixture.Bytes("junie", "quota.json"),
            "Fallback Junie",
            DateTimeOffset.FromUnixTimeSeconds(1_776_240_000));

        Fixture.AssertSnapshotMatches(snapshot, "expected", "junie-pro.json");
    }

    [Fact]
    public void GeminiParsesOAuthClientMetadataFromCliJavaScript()
    {
        var metadata = GeminiQuotaService.ParseOAuthClientConfiguration("""
            var OAUTH_CLIENT_ID = 'test-client-id.apps.googleusercontent.com';
            var OAUTH_CLIENT_SECRET = 'test-client-secret';
            """);

        Assert.Equal("test-client-id.apps.googleusercontent.com", metadata.ClientId);
        Assert.Equal("test-client-secret", metadata.ClientSecret);
    }

    [Fact]
    public void JunieParsesJetBrainsQuotaCache()
    {
        var account = Account with { Provider = AgentProviderKind.Junie };
        var service = new JunieQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient(), []);
        var details = service.ParseAIAssistantQuotaCache(Fixture.Text("junie", "ai-cache.xml"));

        Assert.NotNull(details);
        Assert.Equal(JunieQuotaSource.AiAssistantCache, details.Source);
        Assert.Equal(647454.18, details.Current.GetValueOrDefault(), precision: 2);
        Assert.Equal(1000000d, details.Maximum.GetValueOrDefault(), precision: 3);
        Assert.Equal(DateTimeOffset.Parse("2026-06-16T05:53:53.825Z"), details.ResetsAt.GetValueOrDefault());
    }
}
