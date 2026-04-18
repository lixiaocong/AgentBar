import SwiftUI

#if canImport(AgentBarCore)
import AgentBarCore
#endif

struct SettingsView: View {
    let model: AppModel
    private let providerColumns = [
        GridItem(.adaptive(minimum: 260), alignment: .top)
    ]
    @State private var addAccountProvider: AgentProviderKind?

    var body: some View {
        @Bindable var model = model

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Agent Bar")
                    .font(.title2.weight(.semibold))

                Text("Tracks quota usage for local coding agents. Each provider starts with its standard config directory, and you can add extra account directories below.")
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

                LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 14) {
                    ForEach(AgentProviderKind.allCases) { provider in
                        providerSettingsSection(provider)
                    }
                }

                Button(model.isRefreshing ? "Refreshing…" : "Refresh Now") {
                    model.refreshNow()
                }
                .disabled(model.isRefreshing)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .sheet(item: $addAccountProvider) { provider in
            AddAccountSheet(provider: provider, model: model)
        }
    }

    @ViewBuilder
    private func providerSettingsSection(_ provider: AgentProviderKind) -> some View {
        let statuses = model.accountStatuses(for: provider)

        GroupBox(groupTitle(for: provider)) {
            VStack(alignment: .leading, spacing: 10) {
                Text(description(for: provider))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if statuses.isEmpty {
                    Text("No configured account directories for \(provider.title).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(statuses) { status in
                        accountRow(status)
                    }
                }

                Button("Add Account…") {
                    addAccountProvider = provider
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func accountRow(_ status: AgentAccountStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let snapshot = status.snapshot {
                Text(snapshot.accountLabel)
                    .font(.subheadline.weight(.semibold))

                if let plan = snapshot.planType {
                    LabeledContent("Plan", value: formattedPlan(plan))
                        .font(.caption)
                }
            } else if let error = status.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if status.credentialsDetected {
                Text("Credentials detected. Refresh to load account details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No \(status.provider.credentialsFileDescription) found in this directory yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(status.displayPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 10) {
                Button("Open") {
                    model.openConfiguredAccountDirectory(status.account)
                }

                Button("Remove") {
                    model.removeConfiguredAccount(status.account)
                }
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func groupTitle(for provider: AgentProviderKind) -> String {
        switch provider {
        case .codex:
            return "Codex"
        case .githubCopilot:
            return "GitHub Copilot"
        case .gemini:
            return "Gemini Code Assist"
        case .claude:
            return "Claude Code"
        }
    }

    private func description(for provider: AgentProviderKind) -> String {
        switch provider {
        case .codex:
            return "Uses \(provider.defaultAccountDirectoryDisplayPath) by default and reads `auth.json` from each configured directory."
        case .githubCopilot:
            return "Uses \(provider.defaultAccountDirectoryDisplayPath) by default and reads `apps.json` from each configured directory."
        case .gemini:
            return "Uses \(provider.defaultAccountDirectoryDisplayPath) by default and reads `oauth_creds.json` from each configured directory. Gemini CLI and Antigravity IDE share the same quota."
        case .claude:
            return "Uses \(provider.defaultAccountDirectoryDisplayPath) by default and reads `auth.json` from each configured directory."
        }
    }

    private func formattedPlan(_ planType: String) -> String {
        planType == planType.lowercased() ? planType.capitalized : planType
    }
}

private struct AddAccountSheet: View {
    let provider: AgentProviderKind
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(provider.title) Account")
                .font(.title3.weight(.semibold))

            Text("Paste a directory path directly or browse to it. Hidden folders like \(provider.defaultAccountDirectoryDisplayPath) work here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Directory path")
                    .font(.caption.weight(.semibold))

                TextField(
                    "",
                    text: $path,
                    prompt: Text(provider.defaultAccountDirectoryDisplayPath)
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Browse…") {
                    if let directoryURL = model.selectAccountDirectory(for: provider) {
                        path = NSString(string: directoryURL.path).abbreviatingWithTildeInPath
                        errorMessage = nil
                    }
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }

                Button("Add") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func submit() {
        switch model.addConfiguredAccountDirectory(path: path, for: provider) {
        case .added:
            dismiss()
        case .emptyPath:
            errorMessage = "Enter a directory path."
        case .duplicate:
            errorMessage = "That directory is already configured."
        }
    }
}
