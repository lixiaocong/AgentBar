using System.Diagnostics;
using System.Globalization;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Xml.Linq;

namespace AgentBar.Core;

public sealed class AgentQuotaServiceFactory(IAuthSessionStore authStore, HttpClient? httpClient = null)
    : IAgentQuotaServiceFactory
{
    private readonly HttpClient _httpClient = httpClient ?? new HttpClient();

    public IAgentQuotaService Create(ConfiguredAgentAccount account) => account.Provider switch
    {
        AgentProviderKind.Codex => new CodexQuotaService(account, authStore, _httpClient),
        AgentProviderKind.GitHubCopilot => new GitHubCopilotQuotaService(account, authStore, _httpClient),
        AgentProviderKind.Gemini => new GeminiQuotaService(account, authStore, _httpClient),
        AgentProviderKind.Claude => new ClaudeQuotaService(account),
        AgentProviderKind.Junie => new JunieQuotaService(account, authStore, _httpClient),
        _ => throw new NotSupportedException($"Provider {account.Provider} is not supported.")
    };
}

public abstract class AgentQuotaServiceBase(ConfiguredAgentAccount account) : IAgentQuotaService
{
    public ConfiguredAgentAccount Account { get; } = account;
    public AgentProviderKind Provider => Account.Provider;
    public virtual bool IsAvailable => !string.IsNullOrWhiteSpace(Account.Directory.Path);
    public abstract Task<AgentQuotaSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default);

    protected static string AccountIdFromDirectory(ConfiguredAgentAccount account)
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
}

public sealed class CodexQuotaService(
    ConfiguredAgentAccount account,
    IAuthSessionStore authStore,
    HttpClient httpClient)
    : AgentQuotaServiceBase(account)
{
    public const string ClientId = "app_EMoamEEZ73f0CkXaXp7hrann";
    public static readonly Uri AuthorizationUri = new("https://auth.openai.com/oauth/authorize");
    public static readonly Uri TokenUri = new("https://auth.openai.com/oauth/token");
    public const string Scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke";
    public const string Originator = "agentbar";

    public override async Task<AgentQuotaSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var accountId = AccountIdFromDirectory(Account);
        var session = await authStore.LoadAsync(Provider, accountId, cancellationToken)
            ?? throw new ProviderQuotaException("No AgentBar Codex browser login was found. Sign in from AgentBar settings.");
        session = await RefreshIfNeededAsync(session, force: false, cancellationToken);

        try
        {
            return await LoadWithSessionAsync(session, cancellationToken);
        }
        catch (ProviderQuotaException ex) when (ex.IsAuthenticationFailure)
        {
            var refreshed = await RefreshIfNeededAsync(session, force: true, cancellationToken);
            if (refreshed.AccessToken == session.AccessToken)
            {
                throw;
            }

            return await LoadWithSessionAsync(refreshed, cancellationToken);
        }
    }

    public AgentQuotaSnapshot DecodeSnapshot(
        byte[] data,
        string accountLabel,
        string? spaceLabel,
        DateTimeOffset updatedAt)
    {
        using var document = JsonDocument.Parse(data);
        var root = document.RootElement;
        var planType = root.String("plan_type", "planType");
        var metrics = new List<AgentQuotaMetric>();
        var hasQuotaState = false;

        if (root.TryProperty(out var rateLimit, "rate_limit", "rateLimit"))
        {
            hasQuotaState |= HasCodexQuotaState(rateLimit);
            AddCodexRateLimitMetrics(metrics, rateLimit);
        }

        if (root.TryProperty(out var codeReviewRateLimit, "code_review_rate_limit", "codeReviewRateLimit"))
        {
            hasQuotaState |= HasCodexQuotaState(codeReviewRateLimit);
            AddCodexRateLimitMetrics(metrics, codeReviewRateLimit, "code-review", "Code review");
        }

        if (root.TryProperty(out var additionalRateLimits, "additional_rate_limits", "additionalRateLimits")
            && additionalRateLimits.ValueKind == JsonValueKind.Array)
        {
            var index = 0;
            foreach (var additionalRateLimit in additionalRateLimits.EnumerateArray())
            {
                if (additionalRateLimit.TryProperty(out var nestedRateLimit, "rate_limit", "rateLimit"))
                {
                    index++;
                    hasQuotaState |= HasCodexQuotaState(nestedRateLimit);
                    AddCodexRateLimitMetrics(
                        metrics,
                        nestedRateLimit,
                        $"additional-{index}",
                        CodexAdditionalRateLimitDisplayLabel(additionalRateLimit) ?? $"Additional limit {index}");
                }
            }
        }

        if (root.TryProperty(out var credits, "credits"))
        {
            hasQuotaState |= HasCodexCreditsState(credits);
        }

        metrics = metrics
            .GroupBy(metric => metric.Id, StringComparer.Ordinal)
            .Select(group => group.First())
            .ToList();

        if (metrics.Count == 0 && !hasQuotaState)
        {
            throw new ProviderQuotaException("The Codex usage API response did not include 5-hour or weekly quota windows.");
        }

        return new AgentQuotaSnapshot(
            AgentProviderKind.Codex,
            accountLabel,
            DisplaySpaceLabel(spaceLabel, planType),
            planType,
            null,
            metrics.Count == 0 ? "No active Codex quota windows" : "ChatGPT Codex API",
            metrics,
            updatedAt);
    }

    private static void AddCodexRateLimitMetrics(
        List<AgentQuotaMetric> metrics,
        JsonElement rateLimit,
        string? idPrefix = null,
        string? titlePrefix = null)
    {
        foreach (var key in new[] { "primary_window", "primaryWindow", "secondary_window", "secondaryWindow" })
        {
            if (!rateLimit.TryProperty(out var window, key)
                || TryBuildCodexUsageWindow(window, idPrefix, titlePrefix) is not { } metric)
            {
                continue;
            }

            metrics.Add(metric);
        }
    }

    private static AgentQuotaMetric? TryBuildCodexUsageWindow(
        JsonElement window,
        string? idPrefix = null,
        string? titlePrefix = null)
    {
        if (window.ValueKind != JsonValueKind.Object
            || window.Number("used_percent", "usedPercent") is not { } usedPercent
            || CodexWindowMinutes(window) is not { } windowMinutes
            || window.Number("reset_at", "resetAt", "resets_at", "resetsAt") is not { } resetAt
            || resetAt <= 0)
        {
            return null;
        }

        var windowTitle = CodexWindowTitle(windowMinutes);
        return new AgentQuotaMetric(
            idPrefix is null ? $"window-{windowMinutes}" : $"{idPrefix}-window-{windowMinutes}",
            titlePrefix is null ? windowTitle : $"{titlePrefix} {windowTitle}",
            usedPercent,
            $"{Math.Round(usedPercent):0}% used",
            $"{Math.Round(Math.Max(0, 100 - usedPercent)):0}% left",
            DateTimeOffset.FromUnixTimeSeconds((long)resetAt));
    }

    private static int? CodexWindowMinutes(JsonElement window)
    {
        if (window.Number("limit_window_seconds", "limitWindowSeconds") is { } seconds && seconds > 0)
        {
            return Math.Max(1, ((int)seconds + 59) / 60);
        }

        if (window.Number("window_duration_mins", "windowDurationMins") is { } minutes && minutes > 0)
        {
            return (int)minutes;
        }

        return null;
    }

    private static string CodexWindowTitle(int windowMinutes) => windowMinutes switch
    {
        60 => "1 hour window",
        300 => "5 hour window",
        1_440 => "24 hour window",
        10_080 => "7 day window",
        _ when windowMinutes % 1_440 == 0 => $"{windowMinutes / 1_440} day window",
        _ => $"{windowMinutes} minute window"
    };

    private static string? CodexAdditionalRateLimitDisplayLabel(JsonElement additionalRateLimit)
    {
        return Clean(additionalRateLimit.CleanString("limit_name", "limitName"))
            ?? FormatDisplayToken(Clean(additionalRateLimit.CleanString("metered_feature", "meteredFeature")));
    }

    private static bool HasCodexQuotaState(JsonElement rateLimit) =>
        rateLimit.ValueKind == JsonValueKind.Object
        && (rateLimit.TryProperty(out _, "allowed")
            || rateLimit.TryProperty(out _, "limit_reached", "limitReached")
            || rateLimit.TryProperty(out _, "primary_window", "primaryWindow")
            || rateLimit.TryProperty(out _, "secondary_window", "secondaryWindow"));

    private static bool HasCodexCreditsState(JsonElement credits) =>
        credits.ValueKind == JsonValueKind.Object
        && (credits.TryProperty(out _, "has_credits", "hasCredits")
            || credits.TryProperty(out _, "unlimited")
            || credits.TryProperty(out _, "balance"));

    public string? DecodeWorkspaceDisplayName(byte[] data)
    {
        using var document = JsonDocument.Parse(data);
        var root = document.RootElement;
        return root.CleanString("workspace_name", "workspaceName")
            ?? root.CleanString("display_name", "displayName")
            ?? root.CleanString("name")
            ?? root.CleanString("public_display_name", "publicDisplayName");
    }

    public static string PreferredAccountLabel(string? idToken, string fallbackAccountId)
    {
        var identity = IdentityFromIdToken(idToken);
        return Clean(identity.Email) ?? Clean(identity.Name) ?? $"Account {Masked(fallbackAccountId)}";
    }

    public static CodexTokenIdentity IdentityFromIdToken(string? idToken)
    {
        var payload = OAuthHelpers.DecodeJwtPayload(idToken);
        if (payload is null)
        {
            return new CodexTokenIdentity(null, null, null, null, null, null);
        }

        var root = payload.Value;
        var profile = root.OptionalObject("https://api.openai.com/profile");
        var auth = root.OptionalObject("https://api.openai.com/auth");
        var organization = SelectedOrganization(auth);

        return new CodexTokenIdentity(
            root.CleanString("sub"),
            profile.CleanString("email") ?? root.CleanString("email"),
            profile.CleanString("name") ?? root.CleanString("name"),
            auth.CleanString("chatgpt_account_id", "account_id"),
            organization.CleanString("id"),
            organization.CleanString("title", "name"));
    }

    private async Task<AgentQuotaSnapshot> LoadWithSessionAsync(
        StoredAuthSession session,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://chatgpt.com/backend-api/wham/usage");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", session.AccessToken);
        request.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", session.AccountId);
        request.Headers.TryAddWithoutValidation("User-Agent", "codex-cli");

        using var response = await httpClient.SendAsync(request, cancellationToken);
        var data = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var body = Encoding.UTF8.GetString(data);
            var revoked = IsTokenRevokedResponse(body);
            throw new ProviderQuotaException(
                revoked ? "Codex login was revoked. Reconnect this account from AgentBar settings." : $"Codex usage API failed with HTTP {(int)response.StatusCode}: {body}",
                (int)response.StatusCode,
                revoked);
        }

        var workspace = await LoadWorkspaceDisplayNameAsync(session, cancellationToken) ?? session.SpaceLabel;
        return DecodeSnapshot(data, session.AccountLabel, workspace, DateTimeOffset.UtcNow);
    }

    private async Task<string?> LoadWorkspaceDisplayNameAsync(
        StoredAuthSession session,
        CancellationToken cancellationToken)
    {
        try
        {
            var url = $"https://chatgpt.com/backend-api/accounts/{Uri.EscapeDataString(session.AccountId)}/settings";
            using var request = new HttpRequestMessage(HttpMethod.Get, url);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", session.AccessToken);
            request.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", session.AccountId);
            request.Headers.TryAddWithoutValidation("User-Agent", "codex-cli");
            using var response = await httpClient.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            return DecodeWorkspaceDisplayName(await response.Content.ReadAsByteArrayAsync(cancellationToken));
        }
        catch
        {
            return null;
        }
    }

    private async Task<StoredAuthSession> RefreshIfNeededAsync(
        StoredAuthSession session,
        bool force,
        CancellationToken cancellationToken)
    {
        if (!force && !OAuthHelpers.JwtExpiresSoon(session.AccessToken, TimeSpan.FromSeconds(60)))
        {
            return session;
        }

        if (string.IsNullOrWhiteSpace(session.RefreshToken))
        {
            return session;
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, TokenUri);
        request.Content = new StringContent(
            OAuthHelpers.FormUrlEncode([
                new("grant_type", "refresh_token"),
                new("refresh_token", session.RefreshToken),
                new("client_id", ClientId)
            ]),
            Encoding.UTF8,
            "application/x-www-form-urlencoded");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var body = Encoding.UTF8.GetString(bytes);
            throw new ProviderQuotaException(
                IsTokenRevokedResponse(body) ? "Codex login was revoked. Reconnect this account from AgentBar settings." : $"Codex browser login refresh failed: {body}",
                (int)response.StatusCode,
                IsTokenRevokedResponse(body));
        }

        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        var idToken = root.CleanString("id_token") ?? session.IdToken;
        var accessToken = root.CleanString("access_token") ?? session.AccessToken;
        var refreshToken = root.CleanString("refresh_token") ?? session.RefreshToken;
        var identity = IdentityFromIdToken(idToken);
        var returnedAccount = identity.AccountId ?? session.AccountId;
        if (!string.Equals(returnedAccount, session.AccountId, StringComparison.Ordinal))
        {
            throw new ProviderQuotaException("Token refresh returned a different Codex account.");
        }

        var updated = session with
        {
            IdToken = idToken,
            AccessToken = accessToken,
            RefreshToken = refreshToken,
            AccountLabel = PreferredAccountLabel(idToken, session.AccountId),
            SpaceLabel = identity.SpaceLabel ?? session.SpaceLabel,
            LastRefresh = DateTimeOffset.UtcNow
        };
        await authStore.SaveAsync(updated, cancellationToken);
        return updated;
    }

    private static string? DisplaySpaceLabel(string? rawSpaceLabel, string? planType)
    {
        var normalizedPlan = planType?.Trim().ToLowerInvariant() ?? "";
        if (IsBusinessPlan(normalizedPlan))
        {
            var label = Clean(rawSpaceLabel);
            if (label is not null && !IsGenericPersonalSpaceLabel(label))
            {
                return $"{WorkspaceDisplayName(label)} - {BusinessPlanFallbackLabel(normalizedPlan)}";
            }

            return BusinessPlanFallbackLabel(normalizedPlan);
        }

        if (normalizedPlan.Contains("pro", StringComparison.Ordinal)) return "Personal Pro";
        if (normalizedPlan.Contains("plus", StringComparison.Ordinal)) return "Personal Plus";
        if (normalizedPlan == "free") return "Personal Free";
        return Clean(rawSpaceLabel);
    }

    private static JsonElement SelectedOrganization(JsonElement auth)
    {
        if (!auth.TryProperty(out var organizations, "organizations") || organizations.ValueKind != JsonValueKind.Array)
        {
            return default;
        }

        JsonElement? fallback = null;
        foreach (var organization in organizations.EnumerateArray())
        {
            fallback ??= organization.Clone();
            if (organization.Bool("is_default", "isDefault") == true)
            {
                return organization.Clone();
            }
        }

        return fallback ?? default;
    }

    private static bool IsBusinessPlan(string plan) =>
        plan.Contains("team", StringComparison.Ordinal)
        || plan.Contains("business", StringComparison.Ordinal)
        || plan.Contains("enterprise", StringComparison.Ordinal)
        || plan.Contains("workspace", StringComparison.Ordinal)
        || plan.Contains("edu", StringComparison.Ordinal);

    private static string BusinessPlanFallbackLabel(string plan)
    {
        if (plan.Contains("enterprise", StringComparison.Ordinal)) return "Enterprise";
        if (plan.Contains("edu", StringComparison.Ordinal)) return "Education";
        if (plan.Contains("team", StringComparison.Ordinal)) return "Team";
        return "Business";
    }

    private static bool IsGenericPersonalSpaceLabel(string label)
    {
        var normalized = label.Trim().ToLowerInvariant();
        return normalized is "personal" or "personal workspace" or "personal org";
    }

    private static string WorkspaceDisplayName(string label) =>
        Regex.Replace(label, @"(?i)\s+workspace\s+#\d+$", "");

    private static string? Clean(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static string? FormatDisplayToken(string? value)
    {
        if (Clean(value) is not { } clean)
        {
            return null;
        }

        return CultureInfo.CurrentCulture.TextInfo.ToTitleCase(clean.Replace("_", " ").Replace("-", " "));
    }

    private static string Masked(string value) =>
        value.Length <= 8 ? value : $"{value[..4]}...{value[^4..]}";

    private static bool IsTokenRevokedResponse(string body)
    {
        var normalized = body.ToLowerInvariant();
        return normalized.Contains("token_revoked", StringComparison.Ordinal)
            || normalized.Contains("token_invalidated", StringComparison.Ordinal)
            || normalized.Contains("invalidated oauth token", StringComparison.Ordinal)
            || normalized.Contains("authentication token has been invalidated", StringComparison.Ordinal);
    }
}

public sealed record CodexTokenIdentity(
    string? Subject,
    string? Email,
    string? Name,
    string? AccountId,
    string? SpaceId,
    string? SpaceName)
{
    public string? SpaceLabel => string.IsNullOrWhiteSpace(SpaceName) ? null : SpaceName;
}

public sealed class GitHubCopilotQuotaService(
    ConfiguredAgentAccount account,
    IAuthSessionStore authStore,
    HttpClient httpClient)
    : AgentQuotaServiceBase(account)
{
    public override async Task<AgentQuotaSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var accountId = AccountIdFromDirectory(Account);
        var session = await authStore.LoadAsync(Provider, accountId, cancellationToken)
            ?? throw new ProviderQuotaException("No AgentBar GitHub Copilot browser login was found. Sign in from AgentBar settings.");
        using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/copilot_internal/user");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", session.AccessToken);
        request.Headers.Accept.ParseAdd("application/vnd.github+json");
        request.Headers.UserAgent.ParseAdd("agent-bar");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var data = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderQuotaException($"GitHub Copilot API request failed with HTTP {(int)response.StatusCode}: {Encoding.UTF8.GetString(data)}", (int)response.StatusCode);
        }

        var profile = await LoadProfileAsync(session.AccessToken, cancellationToken);
        return DecodeSnapshot(data, profile, DateTimeOffset.UtcNow);
    }

    public AgentQuotaSnapshot DecodeSnapshot(byte[] data, DateTimeOffset updatedAt) =>
        DecodeSnapshot(data, null, updatedAt);

    private AgentQuotaSnapshot DecodeSnapshot(byte[] data, GitHubProfile? profile, DateTimeOffset updatedAt)
    {
        using var document = JsonDocument.Parse(data);
        var root = document.RootElement;
        var quotaSnapshots = root.OptionalObject("quota_snapshots", "quotaSnapshots");
        var resetAt = ParseResetDate(root.CleanString("quota_reset_date_utc", "quotaResetDateUtc"), updatedAt);
        var metrics = quotaSnapshots.ValueKind == JsonValueKind.Object
            ? quotaSnapshots
                .EnumerateObject()
                .OrderBy(property => CopilotQuotaDisplayOrder(property.Name))
                .ThenBy(property => property.Name, StringComparer.Ordinal)
                .Select(property => CopilotQuotaMetric(
                    $"github-copilot-{CopilotQuotaIdSuffix(property.Name)}",
                    CopilotQuotaTitle(property.Name),
                    property.Value,
                    resetAt))
                .OfType<AgentQuotaMetric>()
                .ToArray()
            : [];

        if (metrics.Length == 0)
        {
            metrics =
            [
                new AgentQuotaMetric(
                "github-copilot-premium-interactions",
                "Premium requests / month",
                0,
                "Unlimited",
                "Unlimited",
                resetAt)
            ];
        }

        return new AgentQuotaSnapshot(
            AgentProviderKind.GitHubCopilot,
            PreferredAccountLabel(
                profile?.Email ?? root.CleanString("email"),
                profile?.Name ?? root.CleanString("name"),
                profile?.Login ?? root.CleanString("login")),
            null,
            root.CleanString("copilot_plan", "copilotPlan"),
            null,
            "GitHub Copilot API",
            metrics,
            updatedAt);
    }

    private static AgentQuotaMetric? CopilotQuotaMetric(
        string id,
        string title,
        JsonElement quota,
        DateTimeOffset resetAt)
    {
        if (quota.ValueKind != JsonValueKind.Object
            || quota.Number("entitlement") is not { } entitlement
            || entitlement <= 0)
        {
            return null;
        }

        var limit = (int)Math.Round(entitlement);
        var remaining = NormalizedCopilotRemaining(quota, limit);
        return AgentQuotaMetric.CappedUsage(
            id,
            title,
            Math.Max(0, limit - remaining),
            limit,
            resetAt);
    }

    private static int NormalizedCopilotRemaining(JsonElement quota, int limit)
    {
        if (quota.Number("remaining") is { } remaining)
        {
            return Math.Clamp((int)Math.Round(remaining), 0, limit);
        }

        if (quota.Number("quota_remaining", "quotaRemaining") is { } quotaRemaining)
        {
            return Math.Clamp((int)Math.Round(quotaRemaining), 0, limit);
        }

        if (quota.Number("percent_remaining", "percentRemaining") is { } percentRemaining)
        {
            var clampedPercent = Math.Clamp(percentRemaining, 0, 100);
            return Math.Clamp((int)Math.Round(limit * clampedPercent / 100), 0, limit);
        }

        return 0;
    }

    private static int CopilotQuotaDisplayOrder(string key) => key switch
    {
        "chat" => 0,
        "completions" => 1,
        "premium_interactions" or "premiumInteractions" => 2,
        _ => 100
    };

    private static string CopilotQuotaTitle(string key) => key switch
    {
        "chat" => "Chat messages / month",
        "completions" => "Code completions / month",
        "premium_interactions" or "premiumInteractions" => "Premium requests / month",
        _ => $"{FormatDisplayToken(key)} / month"
    };

    private static string CopilotQuotaIdSuffix(string key) =>
        Regex.Replace(key, "([a-z0-9])([A-Z])", "$1-$2")
            .Replace("_", "-")
            .ToLowerInvariant();

    private async Task<GitHubProfile?> LoadProfileAsync(string token, CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/user");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            request.Headers.UserAgent.ParseAdd("agent-bar");
            using var response = await httpClient.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            using var document = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(cancellationToken));
            var root = document.RootElement;
            return new GitHubProfile(
                root.CleanString("login"),
                await LoadPrimaryEmailAsync(token, cancellationToken) ?? root.CleanString("email"),
                root.CleanString("name"));
        }
        catch
        {
            return null;
        }
    }

    private async Task<string?> LoadPrimaryEmailAsync(string token, CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.github.com/user/emails");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            request.Headers.UserAgent.ParseAdd("agent-bar");
            using var response = await httpClient.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            using var document = JsonDocument.Parse(await response.Content.ReadAsByteArrayAsync(cancellationToken));
            return document.RootElement.EnumerateArray()
                .Where(email => email.Bool("verified") == true)
                .OrderBy(email => email.Bool("primary") == true ? 0 : 1)
                .Select(email => email.CleanString("email"))
                .FirstOrDefault(email => email is not null);
        }
        catch
        {
            return null;
        }
    }

    private static DateTimeOffset ParseResetDate(string? value, DateTimeOffset fallback)
    {
        if (DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed))
        {
            return parsed;
        }

        return new DateTimeOffset(fallback.Year, fallback.Month, 1, 0, 0, 0, TimeSpan.Zero).AddMonths(1);
    }

    private static string PreferredAccountLabel(string? email, string? name, string? login) =>
        Clean(email) ?? Clean(name) ?? (Clean(login) is { } cleanLogin ? $"@{cleanLogin}" : "GitHub Account");

    private static string? Clean(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value.Trim();

    private static string FormatDisplayToken(string value)
    {
        var spaced = Regex.Replace(value, "([a-z0-9])([A-Z])", "$1 $2")
            .Replace("_", " ")
            .Replace("-", " ");

        return CultureInfo.CurrentCulture.TextInfo.ToTitleCase(spaced);
    }
}

public sealed record GitHubProfile(string? Login, string? Email, string? Name);

public sealed class GeminiQuotaService(
    ConfiguredAgentAccount account,
    IAuthSessionStore authStore,
    HttpClient httpClient)
    : AgentQuotaServiceBase(account)
{
    public static readonly Uri AuthorizationUri = new("https://accounts.google.com/o/oauth2/v2/auth");
    public static readonly Uri TokenUri = new("https://oauth2.googleapis.com/token");
    public static readonly Uri UserInfoUri = new("https://www.googleapis.com/oauth2/v2/userinfo");
    public static readonly string[] Scopes =
    [
        "https://www.googleapis.com/auth/cloud-platform",
        "https://www.googleapis.com/auth/userinfo.email",
        "https://www.googleapis.com/auth/userinfo.profile"
    ];

    public override async Task<AgentQuotaSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var accountId = AccountIdFromDirectory(Account);
        var session = await authStore.LoadAsync(Provider, accountId, cancellationToken)
            ?? throw new ProviderQuotaException("No AgentBar Gemini browser login was found. Sign in from AgentBar settings.");
        var accessToken = await ResolveAccessTokenAsync(session, cancellationToken);
        var codeAssist = await PostJsonAsync("https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", accessToken, """{"cloudaicompanionProject":null,"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}""", cancellationToken);
        using var caDocument = JsonDocument.Parse(codeAssist);
        var projectId = caDocument.RootElement.CleanString("cloudaicompanionProject") ?? "";
        var quota = await PostJsonAsync("https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota", accessToken, $$"""{"project":"{{JsonEncoded(projectId)}}"}""", cancellationToken);
        return DecodeSnapshot(codeAssist, quota, session.AccountLabel, DateTimeOffset.UtcNow);
    }

    public AgentQuotaSnapshot DecodeSnapshot(byte[] codeAssistData, byte[] quotaData, string accountLabel, DateTimeOffset updatedAt)
    {
        using var caDocument = JsonDocument.Parse(codeAssistData);
        using var quotaDocument = JsonDocument.Parse(quotaData);
        var caRoot = caDocument.RootElement;
        var quotaRoot = quotaDocument.RootElement;
        var tier = caRoot.OptionalObject("currentTier");
        var tierId = tier.CleanString("id");
        var tierName = tier.CleanString("name");

        var metrics = new List<AgentQuotaMetric>();
        if (quotaRoot.TryProperty(out var buckets, "buckets") && buckets.ValueKind == JsonValueKind.Array)
        {
            foreach (var bucket in buckets.EnumerateArray())
            {
                if (!string.Equals(bucket.CleanString("tokenType"), "REQUESTS", StringComparison.Ordinal))
                {
                    continue;
                }

                var modelId = bucket.CleanString("modelId") ?? "unknown";
                var remainingFraction = Math.Clamp(bucket.Number("remainingFraction") ?? 0, 0, 1);
                var reset = ParseIso(bucket.CleanString("resetTime"));
                var usedPercent = (1 - remainingFraction) * 100;
                var remainingAmount = bucket.CleanString("remainingAmount") is { } rawAmount && int.TryParse(rawAmount, out var parsedAmount)
                    ? parsedAmount
                    : (int?)null;
                string usedLabel;
                string remainingLabel;
                if (remainingAmount is { } amount && remainingFraction > 0)
                {
                    var limit = (int)Math.Round(amount / remainingFraction);
                    usedLabel = $"{Math.Max(0, limit - amount)}/{limit} used";
                    remainingLabel = $"{amount} left";
                }
                else if (remainingAmount is { } amountOnly)
                {
                    usedLabel = $"{Math.Round(usedPercent):0}% used";
                    remainingLabel = $"{amountOnly} left";
                }
                else
                {
                    usedLabel = $"{Math.Round(usedPercent):0}% used";
                    remainingLabel = $"{Math.Round(Math.Max(0, 100 - usedPercent)):0}% left";
                }

                metrics.Add(new AgentQuotaMetric(
                    modelId,
                    FormatModelName(modelId),
                    usedPercent,
                    usedLabel,
                    remainingLabel,
                    reset is { } date && date.ToUnixTimeSeconds() >= 100 ? date : null));
            }
        }

        return new AgentQuotaSnapshot(
            AgentProviderKind.Gemini,
            accountLabel,
            null,
            TierLabel(tierId, tierName),
            null,
            "Google Cloud Code Assist API",
            metrics.ToArray(),
            updatedAt);
    }

    public static GeminiOAuthClientConfiguration ParseOAuthClientConfiguration(string source)
    {
        var clientId = ExtractJavaScriptConstant("OAUTH_CLIENT_ID", source);
        var clientSecret = ExtractJavaScriptConstant("OAUTH_CLIENT_SECRET", source);
        if (clientId is null || clientSecret is null)
        {
            throw new ProviderQuotaException("Gemini OAuth client metadata was not found.");
        }

        return new GeminiOAuthClientConfiguration(clientId, clientSecret);
    }

    public static GeminiOAuthClientConfiguration LoadOAuthClientConfiguration()
    {
        foreach (var file in OAuthClientSourceFiles())
        {
            try
            {
                return ParseOAuthClientConfiguration(File.ReadAllText(file));
            }
            catch
            {
                continue;
            }
        }

        throw new ProviderQuotaException("Gemini OAuth client metadata was not found. Install or update Gemini CLI, then sign in from AgentBar settings.");
    }

    private async Task<string> ResolveAccessTokenAsync(StoredAuthSession session, CancellationToken cancellationToken)
    {
        if (session.ExpiresAt is null || session.ExpiresAt > DateTimeOffset.UtcNow.AddSeconds(60))
        {
            return session.AccessToken;
        }

        if (string.IsNullOrWhiteSpace(session.RefreshToken))
        {
            throw new ProviderQuotaException(
                "Gemini access token expired and no refresh token is available. Sign in from AgentBar settings.",
                invalidatesStoredLogin: true);
        }

        var client = LoadOAuthClientConfiguration();
        using var request = new HttpRequestMessage(HttpMethod.Post, TokenUri);
        request.Content = new StringContent(
            OAuthHelpers.FormUrlEncode([
                new("client_id", client.ClientId),
                new("client_secret", client.ClientSecret),
                new("refresh_token", session.RefreshToken),
                new("grant_type", "refresh_token")
            ]),
            Encoding.UTF8,
            "application/x-www-form-urlencoded");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            var body = Encoding.UTF8.GetString(bytes);
            throw new ProviderQuotaException(
                $"Gemini token refresh failed with HTTP {(int)response.StatusCode}: {body}",
                (int)response.StatusCode,
                IsInvalidGeminiLoginResponse(body));
        }

        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        var accessToken = root.CleanString("access_token") ?? session.AccessToken;
        var expiresAt = root.Number("expires_in") is { } expiresIn
            ? DateTimeOffset.UtcNow.AddSeconds(expiresIn)
            : session.ExpiresAt;
        await authStore.SaveAsync(session with
        {
            AccessToken = accessToken,
            RefreshToken = root.CleanString("refresh_token") ?? session.RefreshToken,
            ExpiresAt = expiresAt,
            LastRefresh = DateTimeOffset.UtcNow
        }, cancellationToken);
        return accessToken;
    }

    private async Task<byte[]> PostJsonAsync(
        string url,
        string accessToken,
        string json,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        request.Content = new StringContent(json, Encoding.UTF8, "application/json");
        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderQuotaException($"Gemini API request failed with HTTP {(int)response.StatusCode}: {Encoding.UTF8.GetString(bytes)}", (int)response.StatusCode);
        }

        return bytes;
    }

    private static bool IsInvalidGeminiLoginResponse(string body)
    {
        var normalized = body.ToLowerInvariant();
        return normalized.Contains("invalid_grant", StringComparison.Ordinal)
            || normalized.Contains("invalid_token", StringComparison.Ordinal)
            || normalized.Contains("refresh token", StringComparison.Ordinal);
    }

    private static IEnumerable<string> OAuthClientSourceFiles()
    {
        foreach (var executable in FindGeminiExecutables())
        {
            foreach (var candidate in OAuthClientSourceCandidates(executable))
            {
                if (File.Exists(candidate))
                {
                    yield return candidate;
                }
                else if (Directory.Exists(candidate))
                {
                    foreach (var file in SafeEnumerateJavaScriptFiles(candidate))
                    {
                        yield return file;
                    }
                }
            }
        }
    }

    private static IEnumerable<string> FindGeminiExecutables()
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in RunAndReadLines("where", "gemini"))
        {
            if (seen.Add(path)) yield return path;
        }

        foreach (var root in RunAndReadLines("npm", "root -g"))
        {
            var executable = Path.Combine(root, "@google", "gemini-cli", "bundle", "gemini.js");
            if (seen.Add(executable)) yield return executable;
        }

        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var appDataCandidate = Path.Combine(appData, "npm", "node_modules", "@google", "gemini-cli", "bundle", "gemini.js");
        if (seen.Add(appDataCandidate)) yield return appDataCandidate;
    }

    private static IEnumerable<string> SafeEnumerateJavaScriptFiles(string directory)
    {
        try
        {
            return Directory.EnumerateFiles(directory, "*.js").OrderBy(Path.GetFileName).ToArray();
        }
        catch
        {
            return [];
        }
    }

    private static IEnumerable<string> OAuthClientSourceCandidates(string executable)
    {
        var directories = new List<string>();
        var current = File.Exists(executable) ? Path.GetDirectoryName(executable) : executable;
        for (var i = 0; current is not null && i < 8; i++)
        {
            directories.Add(current);
            current = Directory.GetParent(current)?.FullName;
        }

        string[] suffixes =
        [
            Path.Combine("lib", "node_modules", "@google", "gemini-cli", "node_modules", "@google", "gemini-cli-core", "dist", "src", "code_assist", "oauth2.js"),
            Path.Combine("node_modules", "@google", "gemini-cli", "node_modules", "@google", "gemini-cli-core", "dist", "src", "code_assist", "oauth2.js"),
            Path.Combine("dist", "src", "code_assist", "oauth2.js")
        ];

        foreach (var directory in directories)
        {
            foreach (var suffix in suffixes)
            {
                yield return Path.Combine(directory, suffix);
            }

            yield return Path.GetFileName(directory).Equals("bundle", StringComparison.OrdinalIgnoreCase)
                ? directory
                : Path.Combine(directory, "bundle");
        }
    }

    private static IEnumerable<string> RunAndReadLines(string fileName, string arguments)
    {
        var lines = new List<string>();
        try
        {
            using var process = Process.Start(new ProcessStartInfo(fileName, arguments)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            if (process is null)
            {
                return lines;
            }

            if (!process.WaitForExit(3000))
            {
                process.Kill(entireProcessTree: true);
                return lines;
            }

            while (!process.StandardOutput.EndOfStream)
            {
                var line = process.StandardOutput.ReadLine();
                if (!string.IsNullOrWhiteSpace(line))
                {
                    lines.Add(line.Trim());
                }
            }
        }
        catch
        {
        }

        return lines;
    }

    private static string? ExtractJavaScriptConstant(string name, string source)
    {
        var match = Regex.Match(source, $@"(?:const|let|var)\s+{Regex.Escape(name)}\s*=\s*[""'](?<value>[^""']+)[""']");
        return match.Success ? match.Groups["value"].Value : null;
    }

    private static string FormatModelName(string modelId) =>
        CultureInfo.CurrentCulture.TextInfo.ToTitleCase(modelId.Replace("-", " "));

    private static string? TierLabel(string? tierId, string? tierName) => tierId switch
    {
        "free-tier" => "Free",
        "legacy-tier" => "Legacy",
        "standard-tier" => "Standard",
        null => null,
        _ => tierName ?? tierId
    };

    private static DateTimeOffset? ParseIso(string? value)
    {
        return DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed)
            ? parsed
            : null;
    }

    private static string JsonEncoded(string value) =>
        value.Replace("\\", "\\\\").Replace("\"", "\\\"");
}

public sealed record GeminiOAuthClientConfiguration(string ClientId, string ClientSecret);

public sealed class ClaudeQuotaService(ConfiguredAgentAccount account) : AgentQuotaServiceBase(account)
{
    public override bool IsAvailable => File.Exists(CredentialsFile()) || File.Exists(AuthFile());

    public override async Task<AgentQuotaSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var file = File.Exists(CredentialsFile()) ? CredentialsFile() : AuthFile();
        if (!File.Exists(file))
        {
            throw new ProviderQuotaException("No Claude Code credentials were found.");
        }

        return DecodeSnapshot(await File.ReadAllBytesAsync(file, cancellationToken), DateTimeOffset.UtcNow);
    }

    public AgentQuotaSnapshot DecodeSnapshot(byte[] data, DateTimeOffset updatedAt)
    {
        using var document = JsonDocument.Parse(data);
        var root = document.RootElement;
        var account = root.OptionalObject("oauth").OptionalObject("account");
        var accountLabel = account.CleanString("email")
            ?? account.CleanString("name")
            ?? root.CleanString("email", "username")
            ?? (root.TryProperty(out _, "customApiKeyResponses") ? "Anthropic Console" : "Claude Account");
        var planType = root.CleanString("subscriptionType", "subscription_type", "planType", "plan")
            ?? (root.TryProperty(out _, "customApiKeyResponses") ? "Anthropic Console" : null);

        return new AgentQuotaSnapshot(
            AgentProviderKind.Claude,
            accountLabel,
            null,
            planType,
            null,
            "Claude Code local auth",
            [],
            updatedAt);
    }

    private string CredentialsFile()
    {
        var directory = string.IsNullOrWhiteSpace(Account.Directory.Path)
            ? AgentBarPaths.ClaudeDefaultDirectory
            : Account.Directory.Path;
        return Path.Combine(directory, ".credentials.json");
    }

    private string AuthFile()
    {
        var directory = string.IsNullOrWhiteSpace(Account.Directory.Path)
            ? AgentBarPaths.ClaudeDefaultDirectory
            : Account.Directory.Path;
        return Path.Combine(directory, "auth.json");
    }
}

public sealed class JunieQuotaService(
    ConfiguredAgentAccount account,
    IAuthSessionStore authStore,
    HttpClient httpClient,
    IReadOnlyList<string>? quotaCacheFiles = null,
    Uri? endpointUri = null,
    Uri? quotaEndpointUri = null)
    : AgentQuotaServiceBase(account)
{
    private readonly Uri _endpointUri = endpointUri ?? new Uri("https://ingrazzio-cloud-prod.labs.jb.gg/auth/test");
    private readonly Uri? _quotaEndpointUri = quotaEndpointUri;
    private readonly IReadOnlyList<string> _quotaCacheFiles = quotaCacheFiles ?? AgentBarPaths.DefaultJetBrainsQuotaCacheFiles().ToArray();

    public override async Task<AgentQuotaSnapshot> LoadSnapshotAsync(CancellationToken cancellationToken = default)
    {
        var accountId = AccountIdFromDirectory(Account);
        var session = await authStore.LoadAsync(Provider, accountId, cancellationToken)
            ?? throw new ProviderQuotaException("No AgentBar Junie API token was found. Add a Junie API token from AgentBar settings.");
        var token = session.AccessToken.Trim();
        if (token.Length == 0)
        {
            throw new ProviderQuotaException("The saved Junie API token is empty. Add the account again from AgentBar settings.");
        }

        var authInfo = await SendJunieAsync(_endpointUri, HttpMethod.Get, token, null, cancellationToken);
        var quota = _quotaEndpointUri is null
            ? null
            : await TryFetchQuotaAsync(token, cancellationToken);
        return DecodeSnapshot(authInfo, quota, session.AccountLabel, DateTimeOffset.UtcNow);
    }

    public AgentQuotaSnapshot DecodeSnapshot(
        byte[] data,
        byte[]? quotaData,
        string accountLabelFallback,
        DateTimeOffset updatedAt)
    {
        using var document = JsonDocument.Parse(data);
        var root = document.RootElement;
        var quota = quotaData is null ? CachedQuotaDetails(root) : DecodeQuotaDetails(quotaData);
        var accountLabel = root.CleanString("username") ?? accountLabelFallback;
        var licenseType = root.CleanString("licenseType", "license_type");
        var planType = CleanPlanLabel(licenseType);
        var balanceLeft = NormalizedBalance(root.Number("balanceLeft", "balance_left") ?? quota?.Current);
        var total = NormalizedBalance(quota?.Maximum ?? root.Number("balanceTotal", "balanceMaximum", "quotaTotal", "quotaMaximum", "subscriptionTotal"));
        total ??= InferSubscriptionTotal(root, balanceLeft);
        var isMonthlyCredits = quota?.Source == JunieQuotaSource.AiAssistantCache || string.Equals(licenseType, "AIP", StringComparison.OrdinalIgnoreCase);
        var metrics = BuildMetrics(balanceLeft, total, quota?.ResetsAt, isMonthlyCredits, quota?.AdditionalQuotas);
        var balance = BalanceLabel(root, balanceLeft, total, isMonthlyCredits);
        var summary = $"{(root.Bool("active") == false ? "Inactive" : "Active")}{(balance is null ? "" : $" - {balance}")}";

        return new AgentQuotaSnapshot(
            AgentProviderKind.Junie,
            accountLabel,
            null,
            planType,
            null,
            summary,
            metrics,
            updatedAt);
    }

    public JunieQuotaDetails? ParseAIAssistantQuotaCache(string xml)
    {
        var document = XDocument.Parse(xml);
        var options = document.Descendants("component")
            .Where(component => string.Equals((string?)component.Attribute("name"), "AIAssistantQuotaManager2", StringComparison.Ordinal))
            .Elements("option")
            .ToDictionary(
                option => (string?)option.Attribute("name") ?? "",
                option => (string?)option.Attribute("value") ?? "",
                StringComparer.Ordinal);
        options.TryGetValue("quotaInfo", out var quotaInfoJson);
        options.TryGetValue("nextRefill", out var nextRefillJson);
        if (string.IsNullOrWhiteSpace(quotaInfoJson))
        {
            return null;
        }

        using var quotaDocument = JsonDocument.Parse(quotaInfoJson);
        var quotaRoot = quotaDocument.RootElement;
        var tariffQuota = quotaRoot.OptionalObject("tariffQuota");
        var current = tariffQuota.Number("available") ?? quotaRoot.Number("available");
        var maximum = tariffQuota.Number("maximum") ?? quotaRoot.Number("maximum");
        if (current is null && tariffQuota.Number("current") is { } spent && maximum is { } max)
        {
            current = Math.Max(0, max - spent);
        }

        DateTimeOffset? resetsAt = null;
        if (!string.IsNullOrWhiteSpace(nextRefillJson))
        {
            using var refillDocument = JsonDocument.Parse(nextRefillJson);
            resetsAt = ParseIso(refillDocument.RootElement.CleanString("next"));
            maximum ??= refillDocument.RootElement.OptionalObject("tariff").Number("amount");
        }

        var additionalQuotas = new List<JunieNamedQuota>();
        var topUpQuota = quotaRoot.OptionalObject("topUpQuota");
        if (topUpQuota.ValueKind == JsonValueKind.Object)
        {
            var topUpCurrent = topUpQuota.Number("available");
            var topUpMaximum = topUpQuota.Number("maximum");
            if (topUpCurrent is null && topUpQuota.Number("current") is { } topUpSpent && topUpMaximum is { } topUpMax)
            {
                topUpCurrent = Math.Max(0, topUpMax - topUpSpent);
            }

            if (topUpMaximum is > 0)
            {
                additionalQuotas.Add(new JunieNamedQuota(
                    "junie-top-up-credits",
                    "Top-up credits",
                    topUpCurrent,
                    topUpMaximum,
                    resetsAt));
            }
        }

        return current is null && maximum is null
            ? null
            : new JunieQuotaDetails(current, maximum, resetsAt, JunieQuotaSource.AiAssistantCache, additionalQuotas);
    }

    private async Task<byte[]> SendJunieAsync(
        Uri uri,
        HttpMethod method,
        string token,
        string? body,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(method, uri);
        request.Headers.TryAddWithoutValidation("Authorization", token.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? token : $"Bearer {token}");
        request.Headers.TryAddWithoutValidation("Accept", "application/json");
        request.Headers.TryAddWithoutValidation("X-Accept-EAP-License", "true");
        request.Headers.TryAddWithoutValidation("X-Accept-Release-License", "true");
        request.Headers.TryAddWithoutValidation("User-Agent", "agent-bar");
        if (body is not null)
        {
            request.Content = new StringContent(body, Encoding.UTF8, "application/json");
        }

        using var response = await httpClient.SendAsync(request, cancellationToken);
        var bytes = await response.Content.ReadAsByteArrayAsync(cancellationToken);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderQuotaException($"Junie request failed with HTTP {(int)response.StatusCode}: {Encoding.UTF8.GetString(bytes)}", (int)response.StatusCode);
        }

        return bytes;
    }

    private async Task<byte[]?> TryFetchQuotaAsync(string token, CancellationToken cancellationToken)
    {
        try
        {
            return await SendJunieAsync(_quotaEndpointUri!, HttpMethod.Post, token, "{}", cancellationToken);
        }
        catch
        {
            return null;
        }
    }

    private JunieQuotaDetails? CachedQuotaDetails(JsonElement response)
    {
        var licenseType = response.CleanString("licenseType", "license_type");
        if (!string.Equals(licenseType, "AIP", StringComparison.OrdinalIgnoreCase)
            && licenseType?.Contains("ai pro", StringComparison.OrdinalIgnoreCase) != true)
        {
            return null;
        }

        foreach (var file in _quotaCacheFiles.OrderByDescending(File.GetLastWriteTimeUtc))
        {
            try
            {
                var details = ParseAIAssistantQuotaCache(File.ReadAllText(file));
                if (details is not null)
                {
                    return details;
                }
            }
            catch
            {
                continue;
            }
        }

        return null;
    }

    private static JunieQuotaDetails? DecodeQuotaDetails(byte[] data)
    {
        using var document = JsonDocument.Parse(data);
        var root = document.RootElement;
        var quota = root.OptionalObject("current");
        if (quota.ValueKind != JsonValueKind.Object || quota.OptionalObject("current").ValueKind == JsonValueKind.Object)
        {
            quota = quota.OptionalObject("current").ValueKind == JsonValueKind.Object ? quota : root;
        }

        var current = quota.Number("current", "remaining", "left");
        var maximum = quota.Number("maximum", "max", "limit", "total");
        return current is null && maximum is null
            ? null
            : new JunieQuotaDetails(current, maximum, null, JunieQuotaSource.QuotaEndpoint);
    }

    private static IReadOnlyList<AgentQuotaMetric> BuildMetrics(
        double? left,
        double? total,
        DateTimeOffset? resetsAt,
        bool isMonthlyCredits,
        IReadOnlyList<JunieNamedQuota>? additionalQuotas)
    {
        var metrics = new List<AgentQuotaMetric>();
        if (left is not null && total is not null && total > 0)
        {
            var cappedLeft = Math.Clamp(left.Value, 0, total.Value);
            var used = Math.Max(0, total.Value - cappedLeft);
            var usedPercent = Math.Clamp(used / total.Value * 100, 0, 100);
            metrics.Add(new AgentQuotaMetric(
                "junie-subscription-quota",
                isMonthlyCredits ? "Monthly credits" : "Subscription quota",
                usedPercent,
                isMonthlyCredits ? $"{FormatCreditAmount(used)} used" : $"{FormatCurrency(used)} used",
                isMonthlyCredits
                    ? RemainingMonthlyCreditsLabel(Math.Max(left.Value, 0), total.Value)
                    : RemainingCurrencyLabel(Math.Max(left.Value, 0), total.Value),
                resetsAt));
        }

        foreach (var additionalQuota in additionalQuotas ?? [])
        {
            if (BuildAdditionalQuotaMetric(additionalQuota) is { } metric)
            {
                metrics.Add(metric);
            }
        }

        return metrics;
    }

    private static AgentQuotaMetric? BuildAdditionalQuotaMetric(JunieNamedQuota quota)
    {
        var left = NormalizedBalance(quota.Current);
        var total = NormalizedBalance(quota.Maximum);
        if (left is null || total is null || total <= 0)
        {
            return null;
        }

        var cappedLeft = Math.Clamp(left.Value, 0, total.Value);
        var used = Math.Max(0, total.Value - cappedLeft);
        var usedPercent = Math.Clamp(used / total.Value * 100, 0, 100);
        return new AgentQuotaMetric(
            quota.Id,
            quota.Title,
            usedPercent,
            $"{FormatCreditAmount(used)} used",
            RemainingCreditsLabel(Math.Max(left.Value, 0), total.Value),
            quota.ResetsAt);
    }

    private static string? BalanceLabel(JsonElement root, double? left, double? total, bool isMonthlyCredits)
    {
        if (left is null)
        {
            return null;
        }

        if (isMonthlyCredits)
        {
            return RemainingMonthlyCreditsLabel(left.Value, total);
        }

        if (total is not null || IsDollarLikeUnit(root.CleanString("balanceUnit", "balance_unit")))
        {
            return RemainingCurrencyLabel(left.Value, total);
        }

        return $"{FormatNumber(left.Value)} left";
    }

    private static double? NormalizedBalance(double? value) =>
        value is { } amount && Math.Abs(amount) >= 10000 ? amount / 100000 : value;

    private static double? InferSubscriptionTotal(JsonElement root, double? left)
    {
        if (left is null)
        {
            return null;
        }

        var licenseType = root.CleanString("licenseType", "license_type")?.ToLowerInvariant();
        var authType = root.CleanString("authType", "auth_type")?.ToLowerInvariant();
        if ((licenseType is not null && (licenseType.Contains("junie", StringComparison.Ordinal) || licenseType == "aip"))
            || (authType is not null && authType.Contains("api", StringComparison.Ordinal)))
        {
            return Math.Max(10, left.Value);
        }

        return null;
    }

    private static string? CleanPlanLabel(string? licenseType)
    {
        if (string.IsNullOrWhiteSpace(licenseType))
        {
            return null;
        }

        var formatted = CultureInfo.CurrentCulture.TextInfo.ToTitleCase(
            licenseType.Replace("_", " ").Replace("-", " ").ToLowerInvariant());
        return formatted.StartsWith("Junie ", StringComparison.OrdinalIgnoreCase)
            ? formatted["Junie ".Length..]
            : formatted.Replace("Aip", "Pro", StringComparison.Ordinal);
    }

    private static string RemainingCurrencyLabel(double left, double? total) =>
        total is { } max && max > 0 ? $"{FormatCurrency(left)} / {FormatCurrency(max)} left" : $"{FormatCurrency(left)} left";

    private static string RemainingMonthlyCreditsLabel(double left, double? total) =>
        total is { } max && max > 0 ? $"{FormatCreditAmount(left)} / {FormatCreditAmount(max)} monthly credits left" : $"{FormatCreditAmount(left)} monthly credits left";

    private static string RemainingCreditsLabel(double left, double? total) =>
        total is { } max && max > 0 ? $"{FormatCreditAmount(left)} / {FormatCreditAmount(max)} credits left" : $"{FormatCreditAmount(left)} credits left";

    private static bool IsDollarLikeUnit(string? value) =>
        value is not null && new[] { "credit", "credits", "usd", "dollar", "dollars" }.Contains(value.Trim().ToLowerInvariant());

    private static string FormatCurrency(double value) =>
        Math.Round(value) == value ? $"${value:0}" : value.ToString("$0.00", CultureInfo.InvariantCulture);

    private static string FormatCreditAmount(double value) =>
        value.ToString("0.00", CultureInfo.InvariantCulture);

    private static string FormatNumber(double value) =>
        Math.Round(value) == value ? value.ToString("0", CultureInfo.InvariantCulture) : value.ToString("0.##", CultureInfo.InvariantCulture);

    private static DateTimeOffset? ParseIso(string? value) =>
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var parsed)
            ? parsed
            : null;
}

public sealed record JunieQuotaDetails(
    double? Current,
    double? Maximum,
    DateTimeOffset? ResetsAt,
    JunieQuotaSource Source,
    IReadOnlyList<JunieNamedQuota>? AdditionalQuotas = null);

public sealed record JunieNamedQuota(
    string Id,
    string Title,
    double? Current,
    double? Maximum,
    DateTimeOffset? ResetsAt);

public enum JunieQuotaSource
{
    QuotaEndpoint,
    AiAssistantCache
}

public sealed class ProviderQuotaException(
    string message,
    int? statusCode = null,
    bool invalidatesStoredLogin = false)
    : Exception(message)
{
    public int? StatusCode { get; } = statusCode;
    public bool InvalidatesStoredLogin { get; } = invalidatesStoredLogin;
    public bool IsAuthenticationFailure => InvalidatesStoredLogin || StatusCode is 401 or 403;
}

internal static class JsonElementExtensions
{
    public static bool TryProperty(this JsonElement element, out JsonElement value, params string[] names)
    {
        if (element.ValueKind == JsonValueKind.Object)
        {
            foreach (var name in names)
            {
                if (element.TryGetProperty(name, out value))
                {
                    return true;
                }
            }
        }

        value = default;
        return false;
    }

    public static JsonElement OptionalObject(this JsonElement element, params string[] names) =>
        element.TryProperty(out var value, names) && value.ValueKind == JsonValueKind.Object ? value : default;

    public static string? CleanString(this JsonElement element, params string[] names)
    {
        if (!element.TryProperty(out var value, names))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.String => Clean(value.GetString()),
            JsonValueKind.Number => value.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null
        };
    }

    public static string? String(this JsonElement element, params string[] names) =>
        element.TryProperty(out var value, names) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;

    public static double? Number(this JsonElement element, params string[] names)
    {
        if (!element.TryProperty(out var value, names))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.Number when value.TryGetDouble(out var number) => number,
            JsonValueKind.String when double.TryParse(value.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed) => parsed,
            JsonValueKind.Object when value.TryProperty(out var amount, "amount") => DirectNumber(amount),
            _ => null
        };
    }

    public static bool? Bool(this JsonElement element, params string[] names)
    {
        if (!element.TryProperty(out var value, names))
        {
            return null;
        }

        return value.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.String when bool.TryParse(value.GetString(), out var parsed) => parsed,
            _ => null
        };
    }

    private static string? Clean(string? value) =>
        string.IsNullOrWhiteSpace(value) || string.Equals(value.Trim(), "unknown", StringComparison.OrdinalIgnoreCase)
            ? null
            : value.Trim();

    private static double? DirectNumber(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Number when value.TryGetDouble(out var number) => number,
        JsonValueKind.String when double.TryParse(value.GetString(), NumberStyles.Any, CultureInfo.InvariantCulture, out var parsed) => parsed,
        _ => null
    };
}
