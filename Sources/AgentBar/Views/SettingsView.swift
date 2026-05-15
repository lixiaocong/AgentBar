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
                Text("Settings")
                    .font(.title2.weight(.semibold))

                GroupBox("Menu Bar") {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper(
                            value: $model.menuBarMaxDisplayedAccounts,
                            in: AppModel.minimumMenuBarMaxDisplayedAccounts ... AppModel.maximumMenuBarMaxDisplayedAccounts
                        ) {
                            LabeledContent(
                                "Menu bar accounts",
                                value: "\(model.menuBarMaxDisplayedAccounts)"
                            )
                        }

                        if model.hasExplicitMenuBarAccountSelection {
                            Button("Use First Accounts Automatically") {
                                model.resetMenuBarAccountSelection()
                            }
                        }

                        Stepper(
                            value: $model.refreshIntervalSeconds,
                            in: AppModel.minimumRefreshIntervalSeconds ... AppModel.maximumRefreshIntervalSeconds,
                            step: AppModel.refreshIntervalStepSeconds
                        ) {
                            LabeledContent("Update interval", value: "\(model.refreshIntervalSeconds) seconds")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 14) {
                    ForEach(AgentProviderKind.allCases) { provider in
                        providerSettingsSection(provider)
                    }
                }
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
        let hasConfiguredAccounts = !statuses.isEmpty

        GroupBox(groupTitle(for: provider)) {
            VStack(alignment: .leading, spacing: 10) {
                if !statuses.isEmpty {
                    ForEach(statuses) { status in
                        accountRow(status)
                    }
                }

                if model.supportsBrowserSignIn(for: provider) {
                    Button(signInButtonTitle(for: provider, hasConfiguredAccounts: hasConfiguredAccounts)) {
                        model.signInWithBrowser(for: provider, forceAccountSelection: hasConfiguredAccounts)
                    }
                    .disabled(model.isLoginInProgress(for: provider))

                    if let message = model.loginMessage(for: provider) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let error = model.loginError(for: provider) {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if provider == .claude {
                    Button(hasConfiguredAccounts ? "Add Another Auth Directory..." : "Add Claude Auth Directory...") {
                        addAccountProvider = provider
                    }
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
            if let label = status.displayLabel {
                NonHyphenatingLabel(label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let snapshot = status.snapshot {
                if let plan = snapshot.planType {
                    LabeledContent("Plan", value: plan)
                        .font(.caption)
                }
            } else if let error = status.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Toggle(
                    "Menu Bar",
                    isOn: Binding(
                        get: { model.isAccountShownInMenuBar(status.account) },
                        set: { model.setAccount(status.account, shownInMenuBar: $0) }
                    )
                )
                .toggleStyle(.checkbox)

                Button("Sign Out") {
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

    private func signInButtonTitle(for provider: AgentProviderKind, hasConfiguredAccounts: Bool) -> String {
        guard !model.isLoginInProgress(for: provider) else {
            return "Signing In…"
        }

        return hasConfiguredAccounts ? "Add Another Account…" : "Sign In with Browser…"
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
        case .browserLoginRequired:
            errorMessage = "\(provider.title) accounts must be added with browser sign-in."
        case .credentialsFileMissing(let path):
            errorMessage = "No credentials file found at \(path)."
        }
    }
}
