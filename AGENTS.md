# AGENTS.md — AgentBar

Minimal macOS menu-bar app that tracks coding-agent quota usage.
Written in Swift 6 / SwiftUI, targeting macOS 14+.

Codex, GitHub Copilot, and Gemini are displayed **simultaneously** after AgentBar-owned browser sign-in. Tokens are stored in macOS Keychain entries owned by AgentBar, so CLI or IDE profile changes do not silently switch the accounts shown in AgentBar.

---

## Project layout

```
Sources/AgentBar/
├── AgentBarApp.swift          Entry point – MenuBarExtra + Settings scene
├── AppModel.swift             @Observable view-model, tri-provider refresh loop
├── AppLogger.swift            Shared logging helpers (os.Logger + stderr/stdout)
├── Models/
│   └── AgentQuotaModels.swift  AgentProviderKind, AgentQuotaSnapshot, AgentQuotaMetric
├── Codex/
│   └── CodexQuotaService.swift  Uses AgentBar Keychain auth, calls ChatGPT Codex backend API
├── GitHubCopilot/
│   └── GitHubCopilotQuotaService.swift  Uses AgentBar Keychain auth, calls copilot_internal/user API
├── Gemini/
│   └── GeminiQuotaService.swift  Uses AgentBar Keychain auth, calls Google Cloud Code Assist API
├── OpenAI/
│   └── KeychainSecretStore.swift  Generic Keychain read/write/delete helper
└── Views/
    ├── MenuBarView.swift       Tri-provider quota gauges, action buttons
    └── SettingsView.swift      Credential status for all providers, open-config buttons
Tests/AgentBarTests/
├── CodexQuotaServiceTests.swift
├── GitHubCopilotQuotaServiceTests.swift
└── GeminiQuotaServiceTests.swift
```

---

## Providers

All providers are fetched **concurrently** every 30 seconds. Each provider section appears independently in the menu-bar popover — if one fails, the others still display.

### Codex (`AgentProviderKind.codex`)

| Property | Value |
|---|---|
| API endpoint | `GET https://chatgpt.com/backend-api/wham/usage` |
| Auth headers | `Authorization: Bearer <access_token>` `ChatGPT-Account-Id: <account_id>` |
| Credentials source | AgentBar browser login stored in macOS Keychain |
| Displayed metrics | 5-hour usage window, weekly usage window |

The service loads the AgentBar-stored access token and ChatGPT account id from Keychain, refreshes the token when needed, then makes the HTTP request. AgentBar does not read `~/.codex/auth.json`.

### GitHub Copilot (`AgentProviderKind.githubCopilot`)

| Property | Value |
|---|---|
| API endpoint | `GET https://api.github.com/copilot_internal/user` |
| Auth headers | `Authorization: Bearer <oauth_token>` |
| Credentials source | AgentBar GitHub browser login stored in macOS Keychain |
| Displayed metric | Monthly premium-request usage vs. plan allowance |

The app uses GitHub's browser/device authorization flow and stores the resulting OAuth token in AgentBar's Keychain service. AgentBar does not read `~/.config/github-copilot/apps.json` or IDE Copilot keychain entries by default.

The `copilot_internal/user` endpoint returns `quota_snapshots.premium_interactions` with:
- `remaining` — requests remaining this cycle
- `entitlement` — total included requests
- `percent_remaining` — float 0–100
- `unlimited` — true for plans with no cap (e.g. Business)
- `quota_reset_date_utc` — ISO8601 reset timestamp
- `login` — GitHub username
- `copilot_plan` — plan name (e.g. `"pro"`, `"business"`)

### Gemini Code Assist (`AgentProviderKind.gemini`)

| Property | Value |
|---|---|
| API endpoints | `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` (get project ID + tier) → `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` (get per-model quota buckets) |
| Auth headers | `Authorization: Bearer <access_token>` |
| Token refresh | `POST https://oauth2.googleapis.com/token` with `refresh_token` + Gemini CLI client ID/secret |
| Credentials source | AgentBar Google browser login stored in macOS Keychain |
| Account label | Read from the Google OAuth userinfo response |
| Displayed metrics | Per-model request quota (e.g. Gemini 2.5 Flash, Gemini 3 Flash Preview) |

**Shared quota**: Gemini CLI and Antigravity IDE use the same Google account and Cloud Code Assist quota. The Gemini provider covers both tools.

The service:
1. Loads AgentBar-stored `access_token`, `refresh_token`, and expiry from Keychain
2. Refreshes the token via Google OAuth if expired
3. Calls `loadCodeAssist` to get the project ID and user tier (Free, Legacy, Standard)
4. Calls `retrieveUserQuota` to get per-model quota buckets
5. Filters out unavailable models (those with `remainingFraction: 0` and epoch reset time)
6. Builds one `AgentQuotaMetric` per available model

Supported tiers:

| Tier ID | Display name |
|---|---|
| `free-tier` | Free |
| `legacy-tier` | Legacy |
| `standard-tier` | Standard |

---

## Data model

```
AgentQuotaSnapshot
  provider       AgentProviderKind
  accountLabel   String           displayed in header (e.g. "@username")
  planType       String?          e.g. "Pro"
  modelName      String?          (Codex – not currently populated)
  sourceSummary  String           e.g. "GitHub Copilot API"
  metrics        [AgentQuotaMetric]
  updatedAt      Date

AgentQuotaMetric
  id             String           stable identifier for ForEach
  title          String           e.g. "Premium requests / month"
  usedPercent    Double           0–100
  usedLabel      String           e.g. "42/300 used"
  remainingLabel String           e.g. "258 left"
  resetsAt       Date?
```

`highlightMetric` — the metric with the highest `usedPercent` across **all** providers — drives the menu-bar title and icon.

---

## Persistence

Credentials are stored by AgentBar in macOS Keychain. Non-secret account markers live under:
- Codex: `~/Library/Application Support/AgentBar/CodexAccounts`
- GitHub Copilot: `~/Library/Application Support/AgentBar/GitHubCopilotAccounts`
- Gemini: `~/Library/Application Support/AgentBar/GeminiAccounts`
- Claude: `~/.config/claude-code/auth.json` (read-only local Claude Code auth detection)

AgentBar intentionally does not read local CLI login files for Codex, GitHub Copilot, or Gemini by default. Claude is the exception because Claude browser sign-in and quota APIs are not wired yet.

---

## Logging

All log output uses two `os.Logger` instances (subsystem `com.agentbar`):

| Logger | Category | Used for |
|---|---|---|
| `quotaLog` | `quota` | Provider selection, snapshot results, high-level errors |
| `networkLog` | `network` | HTTP request URLs, status codes, error bodies, raw response bodies (debug level) |

Helper functions in `AppLogger.swift`:

| Function | Levels written | Visible in terminal? |
|---|---|---|
| `logError(_:log:)` | `.error` (os) + `stderr` | ✅ yes — `[AgentBar ERROR] …` |
| `logInfo(_:log:)` | `.info` (os) + `stdout` | ✅ yes — `[AgentBar] …` |
| `logDebug(_:log:)` | `.debug` (os only) | ❌ no — use Console.app with debug level enabled |

Raw HTTP response bodies are emitted at `.debug` level only (not printed to the terminal by default, to avoid leaking data in logs).

---

## Build & Install

Build a standalone `.app` bundle you can drag to `/Applications`:

```bash
./scripts/build-app.sh
```

This produces `build/AgentBar.app`. To install:

```bash
cp -R build/AgentBar.app /Applications/
```

Or drag `build/AgentBar.app` into your Applications folder in Finder.

The app runs as a menu-bar-only accessory (`LSUIElement = true`) — no Dock icon.

---

## Run (development)

```bash
swift run AgentBar
```

Errors and key events print directly to the terminal. Example output:

```
[AgentBar] Refreshing all providers…
[AgentBar] Codex → GET https://chatgpt.com/backend-api/wham/usage (account: abcd...efgh)
[AgentBar] Codex ← HTTP 200
[AgentBar] GitHub Copilot → GET https://api.github.com/copilot_internal/user
[AgentBar] GitHub Copilot ← HTTP 200
[AgentBar] Gemini → POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist
[AgentBar] Gemini ← loadCodeAssist HTTP 200
[AgentBar] Gemini → POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota
[AgentBar] Gemini ← retrieveUserQuota HTTP 200
[AgentBar] Codex snapshot loaded — 86% remaining
[AgentBar] GitHub Copilot snapshot loaded — 81% remaining
[AgentBar] Gemini snapshot loaded — 100% remaining
```

On error:

```
[AgentBar ERROR] Gemini loadCodeAssist error 401: ...
[AgentBar ERROR] [AppModel] Gemini refresh failed: Gemini API request failed with HTTP 401: …
```

---

## Test

```bash
swift test --scratch-path .build
```

Test targets:

| Test | What it covers |
|---|---|
| `decodesCodexCloudUsagePayload` | Happy-path JSON → `AgentQuotaSnapshot` for Codex |
| `rejectsUsagePayloadWithoutQuotaWindows` | Missing `rate_limit` throws `noQuotaInResponse` |
| `codexPrefersHumanReadableAccountLabelFromIDToken` | Extracts email/name from JWT id_token |
| `decodesGitHubCopilotUsagePayload` | Happy-path JSON → `AgentQuotaSnapshot` for GitHub Copilot |
| `copilotShowsUnlimitedWhenNoQuotaLimit` | `unlimited: true` → "Unlimited" labels, 0% used |
| `copilotUsageWhenFullyConsumed` | `remaining: 0` → 100% used, 0 left |
| `decodesGeminiQuotaPayload` | Happy-path JSON → `AgentQuotaSnapshot` for Gemini with per-model metrics |
| `geminiQuotaDefaultsToEmptyWhenNoBuckets` | Empty `buckets` → 0 metrics, snapshot still produced |
| `geminiFiltersOutUnavailableModels` | Models with epoch reset + 0 remaining are excluded |

---

## Adding a new provider

1. Add a case to `AgentProviderKind` in `AgentQuotaModels.swift` and fill in `title`, `subtitle`, `menuBarTitlePrefix`.
2. Create a `<Provider>QuotaService.swift` in a new subdirectory under `Sources/AgentBar/`.  Implement `func loadSnapshot() async throws -> AgentQuotaSnapshot`.
3. Add a `<provider>Snapshot` / `<provider>Error` property pair to `AppModel` and call the new service in `refreshNow()`.
4. Add a `providerSection()` call in `MenuBarView` and a `GroupBox` in `SettingsView`.
5. Add unit tests in `Tests/AgentBarTests/`.
