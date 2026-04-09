# AgentBar

Minimal macOS menu bar app for tracking coding-agent usage. The current MVP supports:

- one provider at a time
- Codex
- GitHub Copilot personal accounts

## Run

```bash
swift run AgentBar
```

## Test

```bash
swift test --scratch-path .build
```

## How it works

### Codex

The app calls the same backend usage API used by the ChatGPT-backed Codex client:

- `GET https://chatgpt.com/backend-api/wham/usage`
- `Authorization: Bearer <access_token>`
- `ChatGPT-Account-Id: <account_id>`

This mode uses the local Codex login store only for credentials, not for quota data. It reads:

- 5-hour usage percent
- weekly usage percent
- reset timestamps
- detected plan type

Use this when you want the same numbers shown on `https://chatgpt.com/codex/cloud/settings/usage`.
There is no local rollout-file quota fallback in this mode.

### GitHub Copilot

The app calls GitHub's documented billing usage API for one personal account:

- `GET https://api.github.com/users/{username}/settings/billing/premium_request/usage`
- `Authorization: Bearer <fine-grained-token>`
- `X-GitHub-Api-Version: 2026-03-10`

This mode currently tracks:

- monthly premium-request usage
- the configured personal Copilot plan allowance
- the next monthly reset boundary

It requires:

- a GitHub username
- a fine-grained personal access token with `Plan` user permission set to read
- a selected personal Copilot plan: Free, Student, Pro, or Pro+

This first Copilot version is personal-account only and uses the selected plan's documented included premium-request allowance to compute remaining quota.
