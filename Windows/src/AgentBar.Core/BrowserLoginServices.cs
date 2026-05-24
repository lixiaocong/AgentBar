using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace AgentBar.Core;

public sealed class CodexBrowserLoginService(
    IAuthSessionStore authStore,
    IBrowserLauncher browserLauncher,
    ILocalCallbackServer callbackServer)
{
    private static readonly int[] CallbackPorts = [1457, 1455];

    public async Task<StoredAuthSession> SignInAsync(CancellationToken cancellationToken = default)
    {
        var pkce = OAuthHelpers.GeneratePkce();
        var state = OAuthHelpers.RandomUrlSafeString(32);
        var port = TcpLocalCallbackServer.FirstAvailablePort(CallbackPorts);
        var redirectUri = $"http://localhost:{port}/auth/callback";
        var authorizeUri = BuildAuthorizeUri(redirectUri, pkce.CodeChallenge, state);

        await browserLauncher.LaunchAsync(authorizeUri, cancellationToken);
        var callback = await callbackServer.WaitForCallbackAsync([port], "/auth/callback", TimeSpan.FromMinutes(5), cancellationToken);
        BrowserLoginValidation.ValidateCallback(callback, state, "Codex");
        var token = await ExchangeCodeForTokensAsync(callback.Code!, redirectUri, pkce.CodeVerifier, cancellationToken);
        var identity = CodexQuotaService.IdentityFromIdToken(token.IdToken);
        if (string.IsNullOrWhiteSpace(identity.AccountId))
        {
            throw new ProviderBrowserLoginException("Codex sign-in did not return a ChatGPT account id.");
        }

        var localAccountId = await ResolveLocalAccountIdAsync(
            AgentProviderKind.Codex,
            identity.AccountId,
            identity.Subject,
            identity.SpaceId,
            token.IdToken,
            cancellationToken);
        var session = new StoredAuthSession(
            AgentProviderKind.Codex,
            identity.AccountId,
            CodexQuotaService.PreferredAccountLabel(token.IdToken, identity.AccountId),
            token.AccessToken,
            token.RefreshToken,
            token.IdToken,
            null,
            CodexQuotaService.Scopes.Split(' '),
            DateTimeOffset.UtcNow,
            identity.SpaceLabel,
            localAccountId);
        await authStore.SaveAsync(session, cancellationToken);
        return session;
    }

    public Uri BuildAuthorizeUri(string redirectUri, string codeChallenge, string state)
    {
        var query = OAuthHelpers.FormUrlEncode([
            new("response_type", "code"),
            new("client_id", CodexQuotaService.ClientId),
            new("redirect_uri", redirectUri),
            new("scope", CodexQuotaService.Scopes),
            new("code_challenge", codeChallenge),
            new("code_challenge_method", "S256"),
            new("id_token_add_organizations", "true"),
            new("codex_cli_simplified_flow", "true"),
            new("state", state),
            new("originator", CodexQuotaService.Originator),
            new("prompt", "login consent")
        ]);
        return new Uri($"{CodexQuotaService.AuthorizationUri}?{query}");
    }

    private static async Task<CodexOAuthTokenResponse> ExchangeCodeForTokensAsync(
        string code,
        string redirectUri,
        string codeVerifier,
        CancellationToken cancellationToken)
    {
        using var httpClient = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, CodexQuotaService.TokenUri);
        request.Content = new StringContent(
            OAuthHelpers.FormUrlEncode([
                new("grant_type", "authorization_code"),
                new("code", code),
                new("redirect_uri", redirectUri),
                new("client_id", CodexQuotaService.ClientId),
                new("code_verifier", codeVerifier)
            ]),
            Encoding.UTF8,
            "application/x-www-form-urlencoded");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderBrowserLoginException($"Codex token exchange failed with HTTP {(int)response.StatusCode}: {Encoding.UTF8.GetString(bytes)}");
        }

        var token = JsonSerializer.Deserialize<CodexOAuthTokenResponse>(bytes, JsonOptionsFactory.Create());
        if (token is null || string.IsNullOrWhiteSpace(token.AccessToken) || string.IsNullOrWhiteSpace(token.IdToken))
        {
            throw new ProviderBrowserLoginException("Codex sign-in returned an invalid token response.");
        }

        return token;
    }

    private async Task<string> ResolveLocalAccountIdAsync(
        AgentProviderKind provider,
        string accountId,
        string? subject,
        string? spaceId,
        string idToken,
        CancellationToken cancellationToken)
    {
        var existing = await authStore.ListAsync(provider, cancellationToken);
        foreach (var session in existing.Where(session => session.AccountId == accountId))
        {
            var identity = CodexQuotaService.IdentityFromIdToken(session.IdToken);
            if (identity.Subject == subject && identity.SpaceId == spaceId)
            {
                return session.LocalAccountId;
            }
        }

        if (existing.All(session => session.LocalAccountId != accountId))
        {
            return accountId;
        }

        return $"{accountId}#{OAuthHelpers.Base64Url(System.Security.Cryptography.RandomNumberGenerator.GetBytes(4))}";
    }

    private sealed record CodexOAuthTokenResponse(
        [property: System.Text.Json.Serialization.JsonPropertyName("id_token")] string IdToken,
        [property: System.Text.Json.Serialization.JsonPropertyName("access_token")] string AccessToken,
        [property: System.Text.Json.Serialization.JsonPropertyName("refresh_token")] string RefreshToken);
}

public sealed class GitHubCopilotBrowserLoginService(
    IAuthSessionStore authStore,
    IBrowserLauncher browserLauncher)
{
    private const string ClientId = "Ov23liV9UpD7Rnfnskm3";
    private static readonly string[] Scopes = ["repo", "workflow", "read:user", "user:email"];

    public async Task<StoredAuthSession> SignInAsync(Action<string?>? progress = null, CancellationToken cancellationToken = default)
    {
        var device = await RequestDeviceCodeAsync(cancellationToken);
        progress?.Invoke($"If GitHub does not fill the code automatically, enter {device.UserCode}.");
        await browserLauncher.LaunchAsync(device.VerificationUriToOpen, cancellationToken);
        var token = await PollForAccessTokenAsync(device, cancellationToken);
        if (string.IsNullOrWhiteSpace(token.AccessToken))
        {
            throw new ProviderBrowserLoginException("GitHub sign-in returned an invalid token response.");
        }

        var user = await FetchUserAsync(token.AccessToken, cancellationToken);
        var accountId = user.Id?.ToString() ?? user.Login;
        if (string.IsNullOrWhiteSpace(accountId))
        {
            throw new ProviderBrowserLoginException("GitHub sign-in did not return an account id.");
        }

        var email = await FetchPrimaryEmailAsync(token.AccessToken, cancellationToken) ?? user.Email;
        var label = PreferredGitHubLabel(email, user.Name, user.Login);
        progress?.Invoke(null);
        var session = new StoredAuthSession(
            AgentProviderKind.GitHubCopilot,
            accountId,
            label,
            token.AccessToken,
            null,
            null,
            null,
            token.Scope?.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? Scopes,
            DateTimeOffset.UtcNow);
        await authStore.SaveAsync(session, cancellationToken);
        return session;
    }

    private static async Task<GitHubDeviceCodeResponse> RequestDeviceCodeAsync(CancellationToken cancellationToken)
    {
        using var httpClient = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://github.com/login/device/code");
        request.Headers.Accept.ParseAdd("application/json");
        request.Content = new StringContent(
            OAuthHelpers.FormUrlEncode([new("client_id", ClientId), new("scope", string.Join(' ', Scopes))]),
            Encoding.UTF8,
            "application/x-www-form-urlencoded");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderBrowserLoginException("GitHub device code request failed.");
        }

        return JsonSerializer.Deserialize<GitHubDeviceCodeResponse>(bytes, JsonOptionsFactory.Create())
            ?? throw new ProviderBrowserLoginException("GitHub device code response was invalid.");
    }

    private static async Task<GitHubAccessTokenResponse> PollForAccessTokenAsync(
        GitHubDeviceCodeResponse device,
        CancellationToken cancellationToken)
    {
        using var httpClient = new HttpClient();
        var deadline = DateTimeOffset.UtcNow.AddSeconds(device.ExpiresIn);
        var interval = Math.Max(device.Interval ?? 5, 1);

        while (DateTimeOffset.UtcNow < deadline)
        {
            await Task.Delay(TimeSpan.FromSeconds(interval), cancellationToken);
            using var request = new HttpRequestMessage(HttpMethod.Post, "https://github.com/login/oauth/access_token");
            request.Headers.Accept.ParseAdd("application/json");
            request.Content = new StringContent(
                OAuthHelpers.FormUrlEncode([
                    new("client_id", ClientId),
                    new("device_code", device.DeviceCode),
                    new("grant_type", "urn:ietf:params:oauth:grant-type:device_code")
                ]),
                Encoding.UTF8,
                "application/x-www-form-urlencoded");
            using var response = await httpClient.SendAsync(request, cancellationToken);
            var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                throw new ProviderBrowserLoginException("GitHub access token request failed.");
            }

            var token = JsonSerializer.Deserialize<GitHubAccessTokenResponse>(bytes, JsonOptionsFactory.Create())
                ?? throw new ProviderBrowserLoginException("GitHub token response was invalid.");
            if (!string.IsNullOrWhiteSpace(token.AccessToken))
            {
                return token;
            }

            switch (token.Error)
            {
                case "authorization_pending":
                    break;
                case "slow_down":
                    interval += 5;
                    break;
                case "expired_token":
                    throw new ProviderBrowserLoginException("GitHub device code expired.");
                case "access_denied":
                    throw new ProviderBrowserLoginException("GitHub sign-in was denied.");
                case { } error:
                    throw new ProviderBrowserLoginException(error);
            }
        }

        throw new ProviderBrowserLoginException("GitHub sign-in timed out.");
    }

    private static async Task<GitHubUserResponse> FetchUserAsync(string accessToken, CancellationToken cancellationToken)
    {
        using var httpClient = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/user");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.UserAgent.ParseAdd("agent-bar");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderBrowserLoginException("GitHub user lookup failed.");
        }

        return JsonSerializer.Deserialize<GitHubUserResponse>(bytes, JsonOptionsFactory.Create())
            ?? throw new ProviderBrowserLoginException("GitHub user response was invalid.");
    }

    private static async Task<string?> FetchPrimaryEmailAsync(string accessToken, CancellationToken cancellationToken)
    {
        try
        {
            using var httpClient = new HttpClient();
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/user/emails");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            request.Headers.UserAgent.ParseAdd("agent-bar");
            using var response = await httpClient.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            var emails = JsonSerializer.Deserialize<GitHubEmailResponse[]>(
                await response.Content.ReadAsByteArrayAsync(cancellationToken),
                JsonOptionsFactory.Create()) ?? [];
            return emails
                .Where(email => email.Verified == true)
                .OrderBy(email => email.Primary == true ? 0 : 1)
                .Select(email => Clean(email.Email))
                .FirstOrDefault(email => email is not null);
        }
        catch
        {
            return null;
        }
    }

    private static string PreferredGitHubLabel(string? email, string? name, string? login) =>
        Clean(email) ?? Clean(name) ?? (Clean(login) is { } cleanLogin ? $"@{cleanLogin}" : "GitHub Account");

    private static string? Clean(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();
}

public sealed class GeminiBrowserLoginService(
    IAuthSessionStore authStore,
    IBrowserLauncher browserLauncher,
    ILocalCallbackServer callbackServer,
    Func<GeminiOAuthClientConfiguration>? oauthClientProvider = null)
{
    private static readonly int[] CallbackPorts = [1458, 1459];
    private readonly Func<GeminiOAuthClientConfiguration> _oauthClientProvider =
        oauthClientProvider ?? GeminiQuotaService.LoadOAuthClientConfiguration;

    public async Task<StoredAuthSession> SignInAsync(
        bool forceAccountSelection = false,
        CancellationToken cancellationToken = default)
    {
        var client = _oauthClientProvider();
        var state = OAuthHelpers.RandomUrlSafeString(32);
        var port = TcpLocalCallbackServer.FirstAvailablePort(CallbackPorts);
        var redirectUri = $"http://127.0.0.1:{port}/oauth2callback";
        var authorizeUri = BuildAuthorizeUri(client, redirectUri, state, forceAccountSelection);
        await browserLauncher.LaunchAsync(authorizeUri, cancellationToken);

        var callback = await callbackServer.WaitForCallbackAsync([port], "/oauth2callback", TimeSpan.FromMinutes(5), cancellationToken);
        BrowserLoginValidation.ValidateCallback(callback, state, "Gemini");
        var token = await ExchangeCodeForTokensAsync(client, callback.Code!, redirectUri, cancellationToken);
        var user = await FetchUserInfoAsync(token.AccessToken, cancellationToken);
        var accountId = user.Id ?? user.Email;
        if (string.IsNullOrWhiteSpace(accountId))
        {
            throw new ProviderBrowserLoginException("Gemini sign-in did not return an account id.");
        }

        var session = new StoredAuthSession(
            AgentProviderKind.Gemini,
            accountId,
            user.Email ?? user.Name ?? "Google Account",
            token.AccessToken,
            token.RefreshToken,
            null,
            token.ExpiresIn is null ? null : DateTimeOffset.UtcNow.AddSeconds(token.ExpiresIn.Value),
            GeminiQuotaService.Scopes,
            DateTimeOffset.UtcNow);
        await authStore.SaveAsync(session, cancellationToken);
        return session;
    }

    public Uri BuildAuthorizeUri(
        GeminiOAuthClientConfiguration client,
        string redirectUri,
        string state,
        bool forceAccountSelection)
    {
        var queryItems = new List<KeyValuePair<string, string?>>
        {
            new("response_type", "code"),
            new("client_id", client.ClientId),
            new("redirect_uri", redirectUri),
            new("scope", string.Join(' ', GeminiQuotaService.Scopes)),
            new("access_type", "offline"),
            new("include_granted_scopes", "true"),
            new("state", state),
            new("prompt", forceAccountSelection ? "select_account consent" : "consent")
        };
        return new Uri($"{GeminiQuotaService.AuthorizationUri}?{OAuthHelpers.FormUrlEncode(queryItems)}");
    }

    private static async Task<GoogleOAuthTokenResponse> ExchangeCodeForTokensAsync(
        GeminiOAuthClientConfiguration client,
        string code,
        string redirectUri,
        CancellationToken cancellationToken)
    {
        using var httpClient = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Post, GeminiQuotaService.TokenUri);
        request.Content = new StringContent(
            OAuthHelpers.FormUrlEncode([
                new("grant_type", "authorization_code"),
                new("code", code),
                new("redirect_uri", redirectUri),
                new("client_id", client.ClientId),
                new("client_secret", client.ClientSecret)
            ]),
            Encoding.UTF8,
            "application/x-www-form-urlencoded");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderBrowserLoginException($"Gemini token exchange failed with HTTP {(int)response.StatusCode}: {Encoding.UTF8.GetString(bytes)}");
        }

        return JsonSerializer.Deserialize<GoogleOAuthTokenResponse>(bytes, JsonOptionsFactory.Create())
            ?? throw new ProviderBrowserLoginException("Gemini token response was invalid.");
    }

    private static async Task<GoogleUserInfoResponse> FetchUserInfoAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var httpClient = new HttpClient();
        using var request = new HttpRequestMessage(HttpMethod.Get, GeminiQuotaService.UserInfoUri);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderBrowserLoginException("Gemini user lookup failed.");
        }

        return JsonSerializer.Deserialize<GoogleUserInfoResponse>(bytes, JsonOptionsFactory.Create())
            ?? throw new ProviderBrowserLoginException("Gemini user response was invalid.");
    }
}

public sealed class ProviderBrowserLoginException(string message) : Exception(message);

internal static class BrowserLoginValidation
{
    public static void ValidateCallback(OAuthCallback callback, string expectedState, string provider)
    {
        if (!string.IsNullOrWhiteSpace(callback.Error))
        {
            throw new ProviderBrowserLoginException($"{provider} sign-in failed: {callback.Error}");
        }

        if (!string.Equals(callback.State, expectedState, StringComparison.Ordinal))
        {
            throw new ProviderBrowserLoginException($"{provider} sign-in callback validation failed.");
        }

        if (string.IsNullOrWhiteSpace(callback.Code))
        {
            throw new ProviderBrowserLoginException($"{provider} sign-in did not return an authorization code.");
        }
    }
}

public sealed record GitHubDeviceCodeResponse(
    [property: System.Text.Json.Serialization.JsonPropertyName("device_code")] string DeviceCode,
    [property: System.Text.Json.Serialization.JsonPropertyName("user_code")] string UserCode,
    [property: System.Text.Json.Serialization.JsonPropertyName("verification_uri")] string VerificationUri,
    [property: System.Text.Json.Serialization.JsonPropertyName("verification_uri_complete")] string? VerificationUriComplete,
    [property: System.Text.Json.Serialization.JsonPropertyName("expires_in")] int ExpiresIn,
    int? Interval)
{
    public Uri VerificationUriToOpen
    {
        get
        {
            if (Uri.TryCreate(VerificationUriComplete, UriKind.Absolute, out var complete))
            {
                return complete;
            }

            return new Uri($"{VerificationUri}?user_code={Uri.EscapeDataString(UserCode)}");
        }
    }
}

public sealed record GitHubAccessTokenResponse(
    [property: System.Text.Json.Serialization.JsonPropertyName("access_token")] string? AccessToken,
    [property: System.Text.Json.Serialization.JsonPropertyName("token_type")] string? TokenType,
    string? Scope,
    string? Error,
    [property: System.Text.Json.Serialization.JsonPropertyName("error_description")] string? ErrorDescription);

public sealed record GitHubUserResponse(string? Login, string? Email, string? Name, long? Id);

public sealed record GitHubEmailResponse(string? Email, bool? Primary, bool? Verified);

public sealed record GoogleOAuthTokenResponse(
    [property: System.Text.Json.Serialization.JsonPropertyName("access_token")] string AccessToken,
    [property: System.Text.Json.Serialization.JsonPropertyName("refresh_token")] string? RefreshToken,
    [property: System.Text.Json.Serialization.JsonPropertyName("expires_in")] int? ExpiresIn);

public sealed record GoogleUserInfoResponse(string? Id, string? Email, string? Name);
