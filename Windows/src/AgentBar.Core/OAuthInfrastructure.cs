using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AgentBar.Core;

public sealed class WindowsBrowserLauncher : IBrowserLauncher
{
    public Task LaunchAsync(Uri uri, CancellationToken cancellationToken = default)
    {
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri)
        {
            UseShellExecute = true
        });
        return Task.CompletedTask;
    }
}

public sealed class TcpLocalCallbackServer : ILocalCallbackServer
{
    public static int FirstAvailablePort(IReadOnlyList<int> preferredPorts)
    {
        foreach (var port in preferredPorts)
        {
            try
            {
                var listener = new TcpListener(IPAddress.Loopback, port);
                listener.Start(1);
                listener.Stop();
                return port;
            }
            catch (SocketException)
            {
                continue;
            }
        }

        throw new OAuthCallbackException("No local callback port was available.");
    }

    public async Task<OAuthCallback> WaitForCallbackAsync(
        IReadOnlyList<int> preferredPorts,
        string expectedPath,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        Exception? lastError = null;
        foreach (var port in preferredPorts)
        {
            try
            {
                return await WaitOnPortAsync(port, expectedPath, timeout, cancellationToken);
            }
            catch (Exception ex) when (ex is SocketException or IOException)
            {
                lastError = ex;
            }
        }

        throw new OAuthCallbackException("No local callback port was available.", lastError);
    }

    private static async Task<OAuthCallback> WaitOnPortAsync(
        int port,
        string expectedPath,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(timeout);

        var listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start(1);
        try
        {
            using var client = await listener.AcceptTcpClientAsync(timeoutCts.Token);
            await using var stream = client.GetStream();
            using var reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
            var firstLine = await reader.ReadLineAsync(timeoutCts.Token);
            var callback = ParseCallback(firstLine, expectedPath, port);

            var body = callback.Error is null
                ? "Sign-in completed. You can close this window."
                : "Sign-in failed. Return to AgentBar to try again.";
            await WriteResponseAsync(stream, callback.Error is null ? 200 : 400, body, timeoutCts.Token);
            return callback;
        }
        finally
        {
            listener.Stop();
        }
    }

    public static OAuthCallback ParseCallback(string? firstLine, string expectedPath, int port)
    {
        if (string.IsNullOrWhiteSpace(firstLine))
        {
            throw new OAuthCallbackException("The callback request was empty.");
        }

        var parts = firstLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2)
        {
            throw new OAuthCallbackException("The callback request line was invalid.");
        }

        if (!Uri.TryCreate($"http://127.0.0.1:{port}{parts[1]}", UriKind.Absolute, out var components))
        {
            throw new OAuthCallbackException("The callback URL was invalid.");
        }

        if (!string.Equals(components.AbsolutePath, expectedPath, StringComparison.Ordinal))
        {
            throw new OAuthCallbackException($"Unexpected callback path: {components.AbsolutePath}");
        }

        var query = ParseQuery(components.Query);
        query.TryGetValue("code", out var code);
        query.TryGetValue("state", out var state);
        query.TryGetValue("error_description", out var errorDescription);
        query.TryGetValue("error", out var error);
        return new OAuthCallback(code, state, errorDescription ?? error, port);
    }

    private static async Task WriteResponseAsync(
        Stream stream,
        int status,
        string message,
        CancellationToken cancellationToken)
    {
        var statusText = status == 200 ? "OK" : "Bad Request";
        var html = $"""
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>AgentBar Sign In</title></head>
        <body><p>{WebUtility.HtmlEncode(message)}</p></body>
        </html>
        """;
        var header = string.Join("\r\n",
            $"HTTP/1.1 {status} {statusText}",
            "Content-Type: text/html; charset=utf-8",
            $"Content-Length: {Encoding.UTF8.GetByteCount(html)}",
            "Connection: close",
            "",
            "");
        var bytes = Encoding.UTF8.GetBytes(header + html);
        await stream.WriteAsync(bytes, cancellationToken);
    }

    private static Dictionary<string, string> ParseQuery(string query)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var trimmed = query.TrimStart('?');
        if (string.IsNullOrWhiteSpace(trimmed))
        {
            return values;
        }

        foreach (var pair in trimmed.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = pair.Split('=', 2);
            var key = Uri.UnescapeDataString(parts[0].Replace("+", " "));
            var value = parts.Length == 2 ? Uri.UnescapeDataString(parts[1].Replace("+", " ")) : "";
            values[key] = value;
        }

        return values;
    }
}

public sealed class OAuthCallbackException(string message, Exception? innerException = null)
    : Exception(message, innerException);

public static class OAuthHelpers
{
    public static string FormUrlEncode(IEnumerable<KeyValuePair<string, string?>> values) =>
        string.Join("&", values.Select(pair =>
            $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value ?? "")}"));

    public static string RandomUrlSafeString(int byteCount)
    {
        var bytes = RandomNumberGenerator.GetBytes(byteCount);
        return Base64Url(bytes);
    }

    public static PkcePair GeneratePkce()
    {
        var verifier = RandomUrlSafeString(64);
        var challenge = Base64Url(SHA256.HashData(Encoding.UTF8.GetBytes(verifier)));
        return new PkcePair(verifier, challenge);
    }

    public static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static byte[] FromBase64Url(string value)
    {
        var normalized = value.Replace('-', '+').Replace('_', '/');
        normalized = normalized.PadRight(normalized.Length + (4 - normalized.Length % 4) % 4, '=');
        return Convert.FromBase64String(normalized);
    }

    public static JsonElement? DecodeJwtPayload(string? jwt)
    {
        if (string.IsNullOrWhiteSpace(jwt))
        {
            return null;
        }

        var parts = jwt.Split('.');
        if (parts.Length < 2)
        {
            return null;
        }

        try
        {
            var bytes = FromBase64Url(parts[1]);
            using var document = JsonDocument.Parse(bytes);
            return document.RootElement.Clone();
        }
        catch
        {
            return null;
        }
    }

    public static bool JwtExpiresSoon(string? jwt, TimeSpan buffer)
    {
        var payload = DecodeJwtPayload(jwt);
        if (payload is null || !payload.Value.TryGetProperty("exp", out var exp))
        {
            return false;
        }

        var seconds = exp.ValueKind switch
        {
            JsonValueKind.Number when exp.TryGetInt64(out var value) => value,
            _ => 0
        };
        if (seconds <= 0)
        {
            return false;
        }

        return DateTimeOffset.FromUnixTimeSeconds(seconds) <= DateTimeOffset.UtcNow.Add(buffer);
    }
}

public sealed record PkcePair(string CodeVerifier, string CodeChallenge);
