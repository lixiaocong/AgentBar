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
    public void CodexIgnoresZeroDurationPlaceholderWindows()
    {
        var service = new CodexQuotaService(Account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            """
            {
              "plan_type": "prolite",
              "rate_limit": {
                "allowed": true,
                "limit_reached": false,
                "primary_window": {
                  "used_percent": 0,
                  "limit_window_seconds": 0,
                  "reset_after_seconds": 0,
                  "reset_at": 1780463229
                },
                "secondary_window": null
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "metered_feature": "codex_bengalfox",
                  "rate_limit": {
                    "allowed": true,
                    "limit_reached": false,
                    "primary_window": {
                      "used_percent": 0,
                      "limit_window_seconds": 0,
                      "reset_after_seconds": 0,
                      "reset_at": 1780463229
                    },
                    "secondary_window": null
                  }
                }
              ],
              "credits": {
                "has_credits": false,
                "unlimited": false,
                "balance": "0"
              }
            }
            """u8.ToArray(),
            "Account test",
            "Personal",
            DateTimeOffset.FromUnixTimeSeconds(1_775_600_000));

        Assert.Equal("prolite", snapshot.PlanType);
        Assert.Equal("Personal Pro", snapshot.SpaceLabel);
        Assert.Equal("No active Codex quota windows", snapshot.SourceSummary);
        Assert.Empty(snapshot.Metrics);
    }

    [Fact]
    public void CodexDecodesWindowDurationMinutePayloads()
    {
        var service = new CodexQuotaService(Account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            """
            {
              "plan_type": "prolite",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "window_duration_mins": 300,
                  "resets_at": 1780463229
                }
              }
            }
            """u8.ToArray(),
            "Account test",
            "Personal",
            DateTimeOffset.FromUnixTimeSeconds(1_775_600_000));

        var metric = Assert.Single(snapshot.Metrics);
        Assert.Equal("5 hour window", metric.Title);
        Assert.Equal(25, metric.UsedPercent);
        Assert.Equal("75% left", metric.RemainingLabel);
    }

    [Fact]
    public void CodexDisplaysAdditionalRateLimitWindowsIndependently()
    {
        var service = new CodexQuotaService(Account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            """
            {
              "plan_type": "prolite",
              "rate_limit": {
                "primary_window": {
                  "used_percent": 12,
                  "limit_window_seconds": 18000,
                  "reset_at": 1780517499
                },
                "secondary_window": {
                  "used_percent": 54,
                  "limit_window_seconds": 604800,
                  "reset_at": 1780846287
                }
              },
              "additional_rate_limits": [
                {
                  "limit_name": "GPT-5.3-Codex-Spark",
                  "metered_feature": "codex_bengalfox",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 7,
                      "limit_window_seconds": 18000,
                      "reset_at": 1780518342
                    },
                    "secondary_window": {
                      "used_percent": 9,
                      "limit_window_seconds": 604800,
                      "reset_at": 1781105142
                    }
                  }
                }
              ]
            }
            """u8.ToArray(),
            "Account test",
            "Personal",
            DateTimeOffset.FromUnixTimeSeconds(1_775_600_000));

        Assert.Collection(snapshot.Metrics,
            metric =>
            {
                Assert.Equal("window-300", metric.Id);
                Assert.Equal("5 hour window", metric.Title);
                Assert.Equal(12, metric.UsedPercent);
            },
            metric =>
            {
                Assert.Equal("window-10080", metric.Id);
                Assert.Equal("7 day window", metric.Title);
                Assert.Equal(54, metric.UsedPercent);
            },
            metric =>
            {
                Assert.Equal("additional-1-window-300", metric.Id);
                Assert.Equal("GPT-5.3-Codex-Spark 5 hour window", metric.Title);
                Assert.Equal(7, metric.UsedPercent);
            },
            metric =>
            {
                Assert.Equal("additional-1-window-10080", metric.Id);
                Assert.Equal("GPT-5.3-Codex-Spark 7 day window", metric.Title);
                Assert.Equal(9, metric.UsedPercent);
            });
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
    public void GitHubCopilotUsesPositiveFreeQuotaWhenUnlimitedFlagIsTrue()
    {
        var account = Account with { Provider = AgentProviderKind.GitHubCopilot };
        var service = new GitHubCopilotQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            """
            {
              "login": "free-user",
              "copilot_plan": "free",
              "quota_reset_date_utc": "2026-05-01T00:00:00.000Z",
              "quota_snapshots": {
                "premium_interactions": {
                  "remaining": 37,
                  "entitlement": 50,
                  "percent_remaining": 74.0,
                  "unlimited": true,
                  "overage_count": 0
                }
              }
            }
            """u8.ToArray(),
            DateTimeOffset.UtcNow);

        var metric = Assert.Single(snapshot.Metrics);
        Assert.Equal("free", snapshot.PlanType);
        Assert.Equal(26, metric.UsedPercent);
        Assert.Equal("13/50 used", metric.UsedLabel);
        Assert.Equal("37 left", metric.RemainingLabel);
    }

    [Fact]
    public void GitHubCopilotIndividualPlanUsesChatAndCompletionQuotas()
    {
        var account = Account with { Provider = AgentProviderKind.GitHubCopilot };
        var service = new GitHubCopilotQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            """
            {
              "login": "free-user",
              "copilot_plan": "individual",
              "quota_reset_date_utc": "2026-06-30T16:00:00.000Z",
              "quota_snapshots": {
                "chat": {
                  "remaining": 189,
                  "quota_remaining": 189.3,
                  "entitlement": 200,
                  "percent_remaining": 94.6,
                  "unlimited": false
                },
                "completions": {
                  "remaining": 2000,
                  "quota_remaining": 2000.0,
                  "entitlement": 2000,
                  "percent_remaining": 100.0,
                  "unlimited": false
                },
                "premium_interactions": {
                  "remaining": 0,
                  "quota_remaining": 0.0,
                  "entitlement": 0,
                  "percent_remaining": 0.0,
                  "unlimited": false
                }
              }
            }
            """u8.ToArray(),
            DateTimeOffset.UtcNow);

        Assert.Equal("individual", snapshot.PlanType);
        Assert.Equal(2, snapshot.Metrics.Count);
        Assert.Equal("github-copilot-chat", snapshot.Metrics[0].Id);
        Assert.Equal(5.5, snapshot.Metrics[0].UsedPercent);
        Assert.Equal("11/200 used", snapshot.Metrics[0].UsedLabel);
        Assert.Equal("189 left", snapshot.Metrics[0].RemainingLabel);
        Assert.Equal("github-copilot-completions", snapshot.Metrics[1].Id);
        Assert.Equal(0, snapshot.Metrics[1].UsedPercent);
        Assert.Equal("0/2000 used", snapshot.Metrics[1].UsedLabel);
        Assert.Equal("github-copilot-chat", snapshot.HighlightMetric?.Id);
    }

    [Fact]
    public void GitHubCopilotDisplaysDynamicQuotaSnapshotBuckets()
    {
        var account = Account with { Provider = AgentProviderKind.GitHubCopilot };
        var service = new GitHubCopilotQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            """
            {
              "login": "dynamic-user",
              "copilot_plan": "individual",
              "quota_reset_date_utc": "2026-06-30T16:00:00.000Z",
              "quota_snapshots": {
                "chat": {
                  "remaining": 189,
                  "entitlement": 200,
                  "percent_remaining": 94.5,
                  "unlimited": false
                },
                "agent_sessions": {
                  "remaining": 12,
                  "entitlement": 20,
                  "percent_remaining": 60,
                  "unlimited": false
                },
                "premium_interactions": {
                  "remaining": 0,
                  "entitlement": 0,
                  "percent_remaining": 0,
                  "unlimited": false
                }
              }
            }
            """u8.ToArray(),
            DateTimeOffset.UtcNow);

        Assert.Collection(snapshot.Metrics,
            metric =>
            {
                Assert.Equal("github-copilot-chat", metric.Id);
                Assert.Equal("Chat messages / month", metric.Title);
            },
            metric =>
            {
                Assert.Equal("github-copilot-agent-sessions", metric.Id);
                Assert.Equal("Agent Sessions / month", metric.Title);
                Assert.Equal(40, metric.UsedPercent);
                Assert.Equal("8/20 used", metric.UsedLabel);
                Assert.Equal("12 left", metric.RemainingLabel);
            });
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
    public void GeminiDisplaysDynamicQuotaBuckets()
    {
        var account = Account with { Provider = AgentProviderKind.Gemini };
        var service = new GeminiQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient());
        var snapshot = service.DecodeSnapshot(
            """
            {
              "cloudaicompanionProject": "test-project",
              "currentTier": {"id": "free-tier", "name": "Free tier"}
            }
            """u8.ToArray(),
            """
            {
              "buckets": [
                {
                  "resetTime": "2026-06-04T07:19:14Z",
                  "tokenType": "REQUESTS",
                  "modelId": "gemini-2.5-flash",
                  "remainingFraction": 1
                },
                {
                  "resetTime": "2026-06-04T07:19:14Z",
                  "tokenType": "REQUESTS",
                  "modelId": "gemini-3-flash-preview",
                  "remainingFraction": 0.75
                },
                {
                  "resetTime": "2026-06-04T07:19:14Z",
                  "tokenType": "REQUESTS",
                  "modelId": "gemini-2.5-flash-lite",
                  "remainingFraction": 0.9
                },
                {
                  "resetTime": "2026-06-04T07:19:14Z",
                  "tokenType": "REQUESTS",
                  "modelId": "gemini-3.1-flash-lite",
                  "remainingFraction": 1
                },
                {
                  "resetTime": "1970-01-01T00:00:00Z",
                  "tokenType": "REQUESTS",
                  "modelId": "gemini-3.1-pro-preview",
                  "remainingFraction": 0
                }
              ]
            }
            """u8.ToArray(),
            "test@example.com",
            DateTimeOffset.UtcNow);

        Assert.Collection(snapshot.Metrics,
            metric =>
            {
                Assert.Equal("gemini-2.5-flash", metric.Id);
                Assert.Equal("Gemini 2.5 Flash", metric.Title);
                Assert.Equal(0, metric.UsedPercent);
            },
            metric =>
            {
                Assert.Equal("gemini-3-flash-preview", metric.Id);
                Assert.Equal("Gemini 3 Flash Preview", metric.Title);
                Assert.Equal(25, metric.UsedPercent);
            },
            metric =>
            {
                Assert.Equal("gemini-2.5-flash-lite", metric.Id);
                Assert.Equal("Gemini 2.5 Flash Lite", metric.Title);
                Assert.Equal(10, metric.UsedPercent, precision: 4);
            },
            metric =>
            {
                Assert.Equal("gemini-3.1-flash-lite", metric.Id);
                Assert.Equal("Gemini 3.1 Flash Lite", metric.Title);
                Assert.Equal(0, metric.UsedPercent);
            },
            metric =>
            {
                Assert.Equal("gemini-3.1-pro-preview", metric.Id);
                Assert.Equal("Gemini 3.1 Pro Preview", metric.Title);
                Assert.Equal(100, metric.UsedPercent);
                Assert.Null(metric.ResetsAt);
            });
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

    [Fact]
    public void JunieDisplaysTopUpQuotaAsAdditionalMetric()
    {
        var cachePath = Path.Combine(Path.GetTempPath(), $"AgentBar-JunieQuota-{Guid.NewGuid():N}.xml");
        File.WriteAllText(cachePath, """
            <application>
              <component name="AIAssistantQuotaManager2">
                <option name="nextRefill" value="{&quot;type&quot;:&quot;Known&quot;,&quot;next&quot;:&quot;2026-06-16T05:53:53.825Z&quot;,&quot;tariff&quot;:{&quot;amount&quot;:&quot;1000000&quot;,&quot;duration&quot;:&quot;PT720H&quot;}}" />
                <option name="quotaInfo" value="{&quot;type&quot;:&quot;Available&quot;,&quot;tariffQuota&quot;:{&quot;current&quot;:&quot;352545.82&quot;,&quot;maximum&quot;:&quot;1000000&quot;,&quot;available&quot;:&quot;647454.18&quot;},&quot;topUpQuota&quot;:{&quot;current&quot;:&quot;50000&quot;,&quot;maximum&quot;:&quot;200000&quot;,&quot;available&quot;:&quot;150000&quot;}}" />
              </component>
            </application>
            """);

        try
        {
            var account = Account with { Provider = AgentProviderKind.Junie };
            var service = new JunieQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient(), [cachePath]);
            var snapshot = service.DecodeSnapshot(
                """
                {
                  "active": true,
                  "balanceLeft": 640078,
                  "balanceUnit": "CREDITS",
                  "licenseType": "AIP",
                  "authType": ""
                }
                """u8.ToArray(),
                null,
                "Junie API Key",
                DateTimeOffset.UtcNow);

            Assert.Equal(2, snapshot.Metrics.Count);
            var metric = snapshot.Metrics[1];
            Assert.Equal("junie-top-up-credits", metric.Id);
            Assert.Equal("Top-up credits", metric.Title);
            Assert.Equal(25, metric.UsedPercent);
            Assert.Equal("0.50 used", metric.UsedLabel);
            Assert.Equal("1.50 / 2.00 credits left", metric.RemainingLabel);
            Assert.Equal(DateTimeOffset.Parse("2026-06-16T05:53:53.825Z"), metric.ResetsAt.GetValueOrDefault());
        }
        finally
        {
            File.Delete(cachePath);
        }
    }

    [Fact]
    public void JuniePrefersLiveAuthBalanceOverStaleJetBrainsCache()
    {
        var cachePath = Path.Combine(Path.GetTempPath(), $"AgentBar-JunieQuota-{Guid.NewGuid():N}.xml");
        File.WriteAllText(cachePath, """
            <application>
              <component name="AIAssistantQuotaManager2">
                <option name="quotaInfo" value="{&quot;type&quot;:&quot;Available&quot;,&quot;tariffQuota&quot;:{&quot;current&quot;:&quot;300000&quot;,&quot;maximum&quot;:&quot;1000000&quot;,&quot;available&quot;:&quot;700000&quot;}}" />
              </component>
            </application>
            """);

        try
        {
            var account = Account with { Provider = AgentProviderKind.Junie };
            var service = new JunieQuotaService(account, new InMemoryAuthSessionStore(), new HttpClient(), [cachePath]);
            var snapshot = service.DecodeSnapshot(
                """
                {
                  "active": true,
                  "balanceLeft": 449161.635,
                  "licenseType": "AIP",
                  "authType": ""
                }
                """u8.ToArray(),
                null,
                "Junie API Key",
                DateTimeOffset.UtcNow);

            Assert.Equal("Active - 4.49 / 10.00 monthly credits left", snapshot.SourceSummary);
            var metric = Assert.Single(snapshot.Metrics);
            Assert.Equal("5.51 used", metric.UsedLabel);
            Assert.Equal("4.49 / 10.00 monthly credits left", metric.RemainingLabel);
        }
        finally
        {
            File.Delete(cachePath);
        }
    }
}
