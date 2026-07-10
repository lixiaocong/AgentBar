# AGENTS.md — AgentBar

Minimal macOS menu-bar app that tracks coding-agent quota usage.
Written in Swift 6 / SwiftUI, targeting macOS 14+.

Codex, GitHub Copilot, and Gemini are displayed **simultaneously** after AgentBar-owned browser sign-in. Tokens are stored in macOS Keychain entries owned by AgentBar, so CLI or IDE profile changes do not silently switch the accounts shown in AgentBar.

---

## Project layout

```
Sources/AgentBar/
├── AgentBarApp.swift          Entry point and app-delegate controller wiring
├── AppModel.swift             @Observable view-model, multi-provider refresh loop
├── AgentBarHistoryWindowController.swift  Singleton, multi-display History window lifecycle
├── History/
│   ├── QuotaHistoryStore.swift      SQLite schema, sampling, reset classification, queries
│   ├── QuotaHistoryManager.swift    Shared recording preference, stats, maintenance state
│   ├── QuotaHistoryModels.swift     History records, ranges, event types, downsampling
│   └── QuotaHistoryViewModel.swift  Account/window selection and range loading
└── Views/
    ├── MenuBarView.swift       Provider quota gauges and History/Settings actions
    ├── QuotaHistoryView.swift  Account sidebar and per-window Swift Charts
    └── SettingsView.swift      Credentials plus history recording and cleanup controls
Sources/AgentBarCore/
├── Models/AgentQuotaModels.swift        Shared provider, snapshot, and metric models
├── Codex/CodexQuotaService.swift        ChatGPT Codex quota API
├── GitHubCopilot/GitHubCopilotQuotaService.swift  Copilot quota API
├── Gemini/GeminiQuotaService.swift      Code Assist quota API
└── Widget/
    ├── AgentWidgetState.swift            Shared state model + AgentWidgetStateStore (App Group container)
    └── AgentAccountSnapshotLoader.swift  Loads each provider's snapshot for the widget timeline
Sources/AgentBarWidgetExtension/
└── AgentBarWidgetExtension.swift  Widget, timeline provider, view, and WidgetConfigurationIntent
Tests/AgentBarTests/
├── CodexQuotaServiceTests.swift
├── GitHubCopilotQuotaServiceTests.swift
├── GeminiQuotaServiceTests.swift
└── QuotaHistoryStoreTests.swift
```

---

## Providers

All providers are fetched **concurrently** on the configured update interval, defaulting to 10 seconds. Each provider section appears independently in the menu-bar popover — if one fails, the others still display.

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
| Token refresh | `POST https://oauth2.googleapis.com/token` with `refresh_token` + Gemini CLI OAuth client metadata loaded at runtime |
| Credentials source | AgentBar Google browser login stored in macOS Keychain |
| Account label | Read from the Google OAuth userinfo response |
| Displayed metrics | Per-model request quota (e.g. Gemini 2.5 Flash, Gemini 3 Flash Preview) |

**Shared quota**: Gemini CLI and Antigravity IDE use the same Google account and Cloud Code Assist quota. The Gemini provider covers both tools.

The service:
1. Loads AgentBar-stored `access_token`, `refresh_token`, and expiry from Keychain
2. Loads the Gemini OAuth client ID/secret from the installed Gemini CLI JavaScript bundle at runtime. Do not commit those values.
3. Refreshes the token via Google OAuth if expired
4. Calls `loadCodeAssist` to get the project ID and user tier (Free, Legacy, Standard)
5. Calls `retrieveUserQuota` to get per-model quota buckets
6. Filters out unavailable models (those with `remainingFraction: 0` and epoch reset time)
7. Builds one `AgentQuotaMetric` per available model

Supported tiers:

| Tier ID | Display name |
|---|---|
| `free-tier` | Free |
| `legacy-tier` | Legacy |
| `standard-tier` | Standard |

### Z.ai Coding Plan (`AgentProviderKind.zai`)

| Property | Value |
|---|---|
| API endpoint | `GET https://api.z.ai/api/monitor/usage/quota/limit` |
| Auth headers | `Authorization: Bearer <coding_plan_token>` with raw-token retry for compatibility |
| Credentials source | AgentBar Z.ai Coding Plan credential stored in macOS Keychain |
| Displayed metrics | Dynamic `limits[]` list returned by the usage monitor API, including 5-hour token, weekly token, and MCP/monthly limits when present |

Only the international Z.ai host is supported. The service uses `https://api.z.ai` for monitor data and the settings link opens `https://z.ai/manage-apikey/coding-plan/personal/usage`. Do not call the general pay-as-you-go endpoint for quota data.

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
- Z.ai: `~/Library/Application Support/AgentBar/ZAIAccounts`
- Junie: `~/Library/Application Support/AgentBar/JunieAccounts`

Quota history is stored separately at `~/Library/Application Support/AgentBar/quota-history.sqlite3` using SQLite WAL mode. The database contains normalized account/window metadata and quota samples, never credentials or complete API responses.

History rules:

- Record the first successful snapshot for every `provider + account + metric.id`.
- Record meaningful changes immediately: at least 0.1 percentage point, changed labels, changed reset time, or Unlimited state changes.
- Record an unchanged heartbeat after 15 minutes since the last sample.
- Mark a balance increase as `Reset` when the previous reset time passed or the reset schedule advanced; use `Likely reset` for an increase of at least 1 percentage point without explicit reset evidence.
- Keep disappeared dynamic metrics and removed accounts until the user clears their history.
- History errors are additive and must never replace or fail the live provider snapshot.
- Keep history macOS-only for v1; do not add it to the widget state or Windows project without a dedicated parity change.

AgentBar intentionally does not read local CLI login files for Codex, GitHub Copilot, Gemini, Z.ai, or Junie by default. Claude is the exception because Claude browser sign-in and quota APIs are not wired yet.

---

## Security rules

Never commit secrets or user tokens. This includes OAuth client secrets, API keys, access tokens, refresh tokens, private keys, `.env` files, `auth.json`, local Keychain exports, and copied CLI credential JSON.

Runtime credentials must stay in macOS Keychain or user-local config paths. Public constants such as OAuth client IDs may exist only when they are truly public and not paired with a client secret. Gemini OAuth client metadata is loaded from the installed Gemini CLI bundle at runtime; do not paste the client ID/secret into source, tests, docs, or fixtures.

Before pushing, run:

```bash
swift test
rg -n --hidden --pcre2 \
  --glob '!/.git/**' --glob '!/.build/**' --glob '!/build/**' --glob '!/.xcodebuild/**' \
  'GOCSPX-[A-Za-z0-9_-]{20,}|AIza[0-9A-Za-z_-]{30,}|sk-[A-Za-z0-9_-]{20,}|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16}|-----BEGIN (RSA |DSA |EC |OPENSSH |)?PRIVATE KEY-----|ya29\\.[A-Za-z0-9_-]{20,}' .
```

If a secret is committed by mistake, remove it, amend or rewrite the offending commit, then run:

```bash
git reflog expire --expire=now --expire-unreachable=now --all
git gc --prune=now
```

Do not unblock GitHub push protection for a real secret. Rotate any secret that ever appeared in terminal output, logs, screenshots, or rejected push messages.

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
| `quotaHistoryRecordsInitialChangesAndFifteenMinuteHeartbeat` | Sampling threshold, deduplication, and label carry-forward |
| `quotaHistoryDistinguishesConfirmedLikelyAndScheduleEvents` | Reset and schedule event classification |
| `quotaHistoryHandlesUnlimitedAndDeletesByCutoff` | Unlimited state and explicit retention cleanup |

---

## Widget extension

The macOS desktop widget (`Sources/AgentBarWidgetExtension/AgentBarWidgetExtension.swift`) shows **one** agent account per widget instance. The list of available accounts is materialized into a shared `AgentWidgetState` blob written by the host app into an App Group container, and read back by the widget timeline provider through `AgentWidgetStateStore`.

Each widget instance is configured via a `WidgetConfigurationIntent`:

```swift
struct AgentBarWidgetConfigurationIntent: WidgetConfigurationIntent {
    @Parameter(
        title: "Agent",
        description: "The AgentBar account to show in this widget.",
        optionsProvider: AgentBarWidgetAgentOptionsProvider()
    )
    var agentID: String?
}
```

The parameter is the **stable account identifier string** (`AgentWidgetProviderState.id`, of the form `"<provider>::<directory.path>"`). The options for the Edit screen come from a `DynamicOptionsProvider` that reads the current shared state:

```swift
struct AgentBarWidgetAgentOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> [String] {
        (AgentWidgetStateStore().loadIfPresent()?.sortedProviders ?? [])
            .map(\.id)
    }
}
```

In the timeline provider, `configuration.agentID` is trimmed and used to look up the matching `AgentWidgetProviderState`. If the configured ID is missing or no longer present in the latest shared state, the widget falls back to the first provider in `AgentProviderKind.sortOrder` (codex → copilot → gemini → claude). The same ID also drives the debug `Edit Agent` / `Resolved` pills.

### Why this matters: AppEntity parameters don't persist on ad‑hoc builds

The widget previously declared its parameter as an `AppEntity` (`AgentWidgetSelection`) backed by an `EntityQuery`. On macOS WidgetKit, that pattern only round‑trips reliably when the app is signed with a real Apple Developer identity. AgentBar is built ad‑hoc (`CODE_SIGNING_ALLOWED: NO` in `project.yml`), so `configuration.agent` always came back as `nil` after a timeline reload — every widget instance silently fell through to `providers.first?.id` and therefore showed the **same** account (whichever sorted first), regardless of what the user picked in the Edit screen. The sibling project `computer-bar` documents the same limitation in `SelectComputerBarHostIntent`.

### The fix

Mirror the working `computer-bar` pattern: replace the `AppEntity` parameter with a plain `String?` parameter backed by a `DynamicOptionsProvider`. Plain‑value parameters (`String`, `Int`, `Bool`, …) are persisted directly by WidgetKit per widget instance and survive timeline reloads even without a Developer ID signing certificate, because there is no entity round‑trip that can fail.

What changed in `AgentBarWidgetExtension.swift`:

- Removed `AgentWidgetSelection: AppEntity` and `AgentWidgetSelectionQuery: EntityQuery`.
- Added `AgentBarWidgetAgentOptionsProvider: DynamicOptionsProvider` returning `[String]` IDs from the shared state.
- Replaced `@Parameter var agent: AgentWidgetSelection?` with `@Parameter var agentID: String?`, wired to the new options provider; updated `parameterSummary` to `Show \(\.$agentID)`.
- Reworked the timeline provider so `loadEntry` reads `configuration.agentID` and `resolvedConfiguredAgentID` returns the trimmed non‑empty raw string (no more `configuration.agent?.id`). `resolvedAgentID` keeps the “first provider” fallback only when the configured ID is missing or no longer present in the latest shared state.

Existing widget instances configured under the old `AppEntity` parameter land on the fallback until the user re‑edits each widget and picks the desired agent — that is the same behaviour as a fresh install and is unavoidable when the parameter type changes.

If richer per‑instance Edit UI (with subtitles, multiple copies on the desktop, etc.) is ever needed, the alternative is the interactive‑intent + file‑based persistence pattern documented in `computer-bar`'s `SelectComputerBarHostIntent` comment. Do not reintroduce an `AppEntity`‑typed configuration parameter as long as the build remains ad‑hoc signed.

---

## Adding a new provider

1. Add a case to `AgentProviderKind` in `AgentQuotaModels.swift` and fill in `title`, `subtitle`, `menuBarTitlePrefix`.
2. Create a `<Provider>QuotaService.swift` in a new subdirectory under `Sources/AgentBar/`.  Implement `func loadSnapshot() async throws -> AgentQuotaSnapshot`.
3. Add a `<provider>Snapshot` / `<provider>Error` property pair to `AppModel` and call the new service in `refreshNow()`.
4. Add a `providerSection()` call in `MenuBarView` and a `GroupBox` in `SettingsView`.
5. Add unit tests in `Tests/AgentBarTests/`.
