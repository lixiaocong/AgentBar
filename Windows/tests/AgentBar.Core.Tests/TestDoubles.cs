using AgentBar.Core;

namespace AgentBar.Core.Tests;

internal sealed class InMemoryAuthSessionStore : IAuthSessionStore
{
    private readonly Dictionary<string, StoredAuthSession> _sessions = new(StringComparer.OrdinalIgnoreCase);

    public Task<IReadOnlyList<StoredAuthSession>> ListAsync(
        AgentProviderKind provider,
        CancellationToken cancellationToken = default)
    {
        IReadOnlyList<StoredAuthSession> sessions = _sessions.Values
            .Where(session => session.Provider == provider)
            .ToArray();
        return Task.FromResult(sessions);
    }

    public Task<StoredAuthSession?> LoadAsync(
        AgentProviderKind provider,
        string accountId,
        CancellationToken cancellationToken = default)
    {
        _sessions.TryGetValue(Key(provider, accountId), out var session);
        return Task.FromResult(session);
    }

    public Task SaveAsync(StoredAuthSession session, CancellationToken cancellationToken = default)
    {
        _sessions[Key(session.Provider, session.LocalAccountId)] = session;
        return Task.CompletedTask;
    }

    public Task DeleteAsync(
        AgentProviderKind provider,
        string accountId,
        CancellationToken cancellationToken = default)
    {
        _sessions.Remove(Key(provider, accountId));
        return Task.CompletedTask;
    }

    private static string Key(AgentProviderKind provider, string accountId) =>
        $"{provider.StoredValue()}::{accountId}";
}

internal sealed class FakeBrowserLauncher : IBrowserLauncher
{
    public Uri? LastUri { get; private set; }

    public Task LaunchAsync(Uri uri, CancellationToken cancellationToken = default)
    {
        LastUri = uri;
        return Task.CompletedTask;
    }
}

internal sealed class FixedCallbackServer(OAuthCallback callback) : ILocalCallbackServer
{
    public Task<OAuthCallback> WaitForCallbackAsync(
        IReadOnlyList<int> preferredPorts,
        string expectedPath,
        TimeSpan timeout,
        CancellationToken cancellationToken = default) =>
        Task.FromResult(callback with { Port = preferredPorts[0] });
}
