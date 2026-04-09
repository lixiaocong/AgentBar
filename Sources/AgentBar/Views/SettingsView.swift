import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        @Bindable var model = model
        let visibleProviders = model.availableProviders

        VStack(alignment: .leading, spacing: 14) {
            Text("Agent Bar")
                .font(.title2.weight(.semibold))

            Text("Tracks quota usage for detected local coding agents. Providers without local credentials are hidden automatically.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Menu Bar") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Display format", selection: $model.menuBarDisplayMode) {
                        ForEach(MenuBarDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Text(model.menuBarDisplayMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Preview", value: model.menuBarDisplayMode.example)

                    Stepper(
                        value: $model.refreshIntervalSeconds,
                        in: AppModel.minimumRefreshIntervalSeconds ... AppModel.maximumRefreshIntervalSeconds,
                        step: AppModel.refreshIntervalStepSeconds
                    ) {
                        LabeledContent("Update interval", value: "\(model.refreshIntervalSeconds) seconds")
                    }

                    Text("Applies to all providers. Lower values make more frequent API requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            if visibleProviders.isEmpty {
                GroupBox("Detected Providers") {
                    Text("No supported providers were detected on this Mac yet. Sign in with a supported CLI or IDE extension first, then refresh.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }
            } else {
                ForEach(visibleProviders) { provider in
                    providerSettingsSection(provider)
                }
            }

            Button(model.isRefreshing ? "Refreshing…" : "Refresh Now") {
                model.refreshNow()
            }
            .disabled(model.isRefreshing)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func providerSettingsSection(_ provider: AgentProviderKind) -> some View {
        switch provider {
        case .codex:
            GroupBox("Codex") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reads credentials from `~/.codex/auth.json` — populated by the Codex CLI after `codex` login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let snap = model.snapshot(for: .codex) {
                        LabeledContent("Account", value: snap.accountLabel)
                        if let plan = snap.planType {
                            LabeledContent("Plan", value: plan)
                        }
                    } else if let err = model.errorMessage(for: .codex) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Open ~/.codex") {
                        model.openCodexRoot()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        case .githubCopilot:
            GroupBox("GitHub Copilot") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reads credentials from `~/.config/github-copilot/apps.json` — populated by any Copilot IDE extension (VS Code, JetBrains, etc.).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let snap = model.snapshot(for: .githubCopilot) {
                        LabeledContent("Account", value: snap.accountLabel)
                        if let plan = snap.planType {
                            LabeledContent("Plan", value: plan == plan.lowercased() ? plan.capitalized : plan)
                        }
                    } else if let err = model.errorMessage(for: .githubCopilot) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Open ~/.config/github-copilot") {
                        model.openCopilotConfigDirectory()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        case .gemini:
            GroupBox("Gemini Code Assist") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Reads credentials from `~/.gemini/oauth_creds.json` — populated by the Gemini CLI after `gemini` login. Quota is shared with Antigravity IDE.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let snap = model.snapshot(for: .gemini) {
                        LabeledContent("Account", value: snap.accountLabel)
                        if let plan = snap.planType {
                            LabeledContent("Plan", value: plan)
                        }
                    } else if let err = model.errorMessage(for: .gemini) {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Open ~/.gemini") {
                        model.openGeminiConfigDirectory()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }
    }
}
