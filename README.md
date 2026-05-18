# AgentBar

Minimal macOS menu bar app for tracking local coding-agent usage and account status, with a desktop widget for quick at-a-glance viewing.

> This app was generated entirely by coding agents.

AgentBar uses app-owned sign-in for browser/API-token providers, stores tokens in its own macOS Keychain vault, and displays signed-in accounts side by side in the menu bar popover.

## Desktop Widget

AgentBar now bundles a native macOS desktop widget. After installing `build/AgentBar.app`, add it from the widget gallery and place it on the desktop to see one selected Codex, GitHub Copilot, Gemini, Claude, or Junie account without opening the menu bar popover.

For the most reliable widget discovery flow, use:

```bash
./scripts/install-app.sh
```

That builds the app, installs it to `/Applications/AgentBar.app`, registers it with LaunchServices, and opens it once so macOS can pick up the embedded widget extension.

## Main UI

The popover shows all detected providers side by side, and each provider column can include multiple configured accounts. The preview below uses the original screenshot, with personal details masked.

![AgentBar main UI preview with masked account details](Resources/Screenshots/main-ui-screenshot-masked.png)

Current providers:

- Codex
- GitHub Copilot
- Gemini Code Assist
- Claude Code
- Junie by JetBrains

## Run

```bash
swift run AgentBar
```

## Test

```bash
swift test --scratch-path .build
```

## How It Works

### Codex

AgentBar signs in with the browser, stores Codex credentials in the macOS Keychain, then calls:

- `GET https://chatgpt.com/backend-api/wham/usage`

It displays:

- 5-hour usage
- 7-day usage
- reset timestamps
- detected plan type

### GitHub Copilot

AgentBar signs in with the browser through GitHub's device authorization flow, stores GitHub Copilot credentials in the macOS Keychain, then calls:

- `GET https://api.github.com/copilot_internal/user`

It displays:

- monthly premium-request usage
- plan allowance
- reset timestamp

### Gemini Code Assist

AgentBar signs in with the browser through Google's OAuth flow, stores Gemini credentials in the macOS Keychain, refreshes the OAuth token when needed, then calls:

- `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
- `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`

It displays:

- detected Google account
- tier name
- per-model request quota buckets

### Claude Code

AgentBar reads Claude Code auth from `~/.config/claude-code/auth.json` by default. You can also add another directory that contains `auth.json` from Settings.

AgentBar does not currently show Claude quota windows because the app does not have a confirmed quota endpoint wired for Claude yet. The Claude card shows the detected local account and auth type.

### Junie

AgentBar stores a Junie API token in its own macOS Keychain vault. Add the token from Settings after generating it at `junie.jetbrains.com/cli`.

It displays:

- detected Junie account
- license/auth type
- current AI Assistant monthly credits when JetBrains exposes them
- remaining quota progress bar and renewal time when the JetBrains AI Assistant quota cache is present
