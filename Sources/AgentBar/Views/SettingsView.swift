import AppKit
import SwiftUI

#if canImport(AgentBarCore)
import AgentBarCore
#endif

struct SettingsView: View {
    let model: AppModel
    let historyManager: QuotaHistoryManager
    let openHistoryAction: () -> Void
    private let providerColumns = [
        GridItem(.adaptive(minimum: 260), alignment: .top)
    ]
    @State private var addAccountProvider: AgentProviderKind?
    @State private var isAddingJunieToken = false
    @State private var isAddingZAICredential = false
    @State private var isClearingHistory = false
    @State private var isConfirmingHistoryRebuild = false

    init(
        model: AppModel,
        historyManager: QuotaHistoryManager = .shared,
        openHistoryAction: @escaping () -> Void = {}
    ) {
        self.model = model
        self.historyManager = historyManager
        self.openHistoryAction = openHistoryAction
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var historyManager = historyManager

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

                GroupBox("History") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Record quota history", isOn: $historyManager.isEnabled)

                        LabeledContent("Sampling", value: "Every 15 minutes + changes")
                            .font(.caption)

                        LabeledContent("Samples", value: historyManager.stats.sampleCount.formatted())
                            .font(.caption)

                        LabeledContent("Oldest sample", value: oldestHistorySampleText)
                            .font(.caption)

                        LabeledContent("Database size", value: historyDatabaseSizeText)
                            .font(.caption)

                        if let error = historyManager.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)

                            Button("Rebuild History Database...") {
                                isConfirmingHistoryRebuild = true
                            }
                            .disabled(historyManager.isMaintaining)
                        }

                        HStack(spacing: 10) {
                            Button("Open History...") {
                                openHistoryAction()
                            }

                            Button("Clear History...") {
                                isClearingHistory = true
                            }
                            .disabled(historyManager.stats.sampleCount == 0 || historyManager.isMaintaining)

                            if historyManager.isMaintaining {
                                ProgressView()
                                    .controlSize(.small)
                            }
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
        .sheet(isPresented: $isAddingJunieToken) {
            AddJunieTokenSheet(model: model)
        }
        .sheet(isPresented: $isAddingZAICredential) {
            AddZAICodingPlanCredentialSheet(model: model)
        }
        .sheet(isPresented: $isClearingHistory) {
            QuotaHistoryCleanupSheet(manager: historyManager)
        }
        .confirmationDialog(
            "Rebuild History Database?",
            isPresented: $isConfirmingHistoryRebuild
        ) {
            Button("Rebuild Database", role: .destructive) {
                Task { await historyManager.rebuildDatabase() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all quota history and creates a new database.")
        }
        .onAppear {
            historyManager.start()
            historyManager.refreshStats()
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
                        model.signInWithBrowser(
                            for: provider,
                            forceAccountSelection: provider == .codex || hasConfiguredAccounts
                        )
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
                } else if provider == .junie {
                    Button(hasConfiguredAccounts ? "Add Another Junie Token..." : "Add Junie Token...") {
                        isAddingJunieToken = true
                    }
                } else if provider == .zai {
                    Button(hasConfiguredAccounts ? "Add Another Coding Plan..." : "Add Coding Plan...") {
                        isAddingZAICredential = true
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
                if let context = accountContext(for: status, snapshot: snapshot) {
                    LabeledContent(context.label, value: context.value)
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

                if status.provider == .codex, status.errorMessage != nil {
                    Button(model.isCodexReconnectInProgress(status.account) ? "Reconnecting…" : "Reconnect") {
                        model.reconnectCodexAccount(status.account)
                    }
                    .disabled(model.isCodexReconnectInProgress(status.account))
                }

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

    private func accountContext(
        for status: AgentAccountStatus,
        snapshot: AgentQuotaSnapshot
    ) -> (label: String, value: String)? {
        if status.provider == .codex,
           let workspace = trimmedSettingValue(snapshot.spaceLabel) {
            return ("Workspace", workspace)
        }

        if let plan = trimmedSettingValue(snapshot.planType) {
            return ("Plan", plan)
        }

        return nil
    }

    private func trimmedSettingValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        return trimmed
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
        case .zai:
            return "Z.ai Coding Plan"
        case .junie:
            return "Junie"
        }
    }

    private func signInButtonTitle(for provider: AgentProviderKind, hasConfiguredAccounts: Bool) -> String {
        guard !model.isLoginInProgress(for: provider) else {
            return "Signing In…"
        }

        return hasConfiguredAccounts ? "Add Another Account…" : "Sign In with Browser…"
    }

    private var oldestHistorySampleText: String {
        guard let oldest = historyManager.stats.oldestSampleAt else { return "None" }
        return oldest.formatted(date: .abbreviated, time: .shortened)
    }

    private var historyDatabaseSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: historyManager.stats.databaseSizeBytes,
            countStyle: .file
        )
    }

}

private struct QuotaHistoryCleanupSheet: View {
    let manager: QuotaHistoryManager

    @Environment(\.dismiss) private var dismiss
    @State private var daysText = "90"
    @State private var isConfirmingOlderDeletion = false
    @State private var isConfirmingAllDeletion = false
    @State private var errorMessage: String?

    private var days: Int? {
        guard let value = Int(daysText), value > 0 else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clear Quota History")
                .font(.title3.weight(.semibold))

            Text("History is kept permanently until you remove it here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("Delete samples older than")

                TextField("Days", text: $daysText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)

                Text("days")

                Spacer()

                Button("Delete...", role: .destructive) {
                    isConfirmingOlderDeletion = true
                }
                .disabled(days == nil || manager.isMaintaining)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delete all history")
                        .fontWeight(.semibold)
                    Text("This cannot be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Delete All...", role: .destructive) {
                    isConfirmingAllDeletion = true
                }
                .disabled(manager.isMaintaining)
            }

            if manager.isMaintaining {
                ProgressView("Compacting database...")
                    .controlSize(.small)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(manager.isMaintaining)
            }
        }
        .padding(20)
        .frame(width: 520)
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .confirmationDialog(
            "Delete Old Quota History?",
            isPresented: $isConfirmingOlderDeletion
        ) {
            Button("Delete", role: .destructive) {
                guard let days else { return }
                perform { await manager.clearHistory(olderThanDays: days) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Samples older than \(days ?? 0) days will be permanently deleted.")
        }
        .confirmationDialog(
            "Delete All Quota History?",
            isPresented: $isConfirmingAllDeletion
        ) {
            Button("Delete All", role: .destructive) {
                perform { await manager.clearAllHistory() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every recorded account and quota window will be permanently deleted.")
        }
    }

    private func perform(_ operation: @escaping @MainActor () async -> Bool) {
        errorMessage = nil
        Task {
            if await operation() {
                dismiss()
            } else {
                errorMessage = manager.lastError ?? "History could not be cleared."
            }
        }
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

private struct AddJunieTokenSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Junie Account")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Junie API token")
                    .font(.caption.weight(.semibold))

                SecureField(
                    "",
                    text: $token,
                    prompt: Text("perm-...")
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Open Token Page") {
                    NSWorkspace.shared.open(URL(string: "https://junie.jetbrains.com/cli")!)
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }

                Button("Add") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func submit() {
        switch model.addJunieAPIToken(token) {
        case .added:
            dismiss()
        case .emptyToken:
            errorMessage = "Enter a Junie API token."
        case .duplicate:
            errorMessage = "That Junie account is already configured."
        case .saveFailed(let message):
            errorMessage = message
        }
    }
}

private struct AddZAICodingPlanCredentialSheet: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Z.ai Coding Plan")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("Coding Plan token")
                    .font(.caption.weight(.semibold))

                SecureField(
                    "",
                    text: $token,
                    prompt: Text("Z.ai Coding Plan token")
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button("Open Usage Page") {
                    NSWorkspace.shared.open(ZAIQuotaService.codingPlanUsagePageURL)
                }

                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }

                Button("Add") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    private func submit() {
        switch model.addZAICodingPlanCredential(token) {
        case .added:
            dismiss()
        case .emptyToken:
            errorMessage = "Enter a Z.ai Coding Plan token."
        case .duplicate:
            errorMessage = "That Z.ai account is already configured."
        case .invalidBaseURL:
            errorMessage = "Only the international Z.ai host is supported."
        case .saveFailed(let message):
            errorMessage = message
        }
    }

}
