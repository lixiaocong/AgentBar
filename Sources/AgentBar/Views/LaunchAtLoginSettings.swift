import AppKit
import ServiceManagement
import SwiftUI

@MainActor
@Observable
final class LaunchAtLoginModel {
    private(set) var status: SMAppService.Status
    private(set) var isUpdating = false
    private(set) var errorMessage: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () async throws -> Void

    init(
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () async throws -> Void = { try await SMAppService.mainApp.unregister() }
    ) {
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
        status = readStatus()
    }

    var isRegistered: Bool {
        status == .enabled || status == .requiresApproval
    }

    func refresh() {
        status = readStatus()
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refresh()
        guard enabled != isRegistered else { return }
        isUpdating = true
        errorMessage = nil
        defer {
            refresh()
            isUpdating = false
        }
        do {
            if enabled {
                try register()
            } else {
                try await unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct LaunchAtLoginSettings: View {
    @State private var model = LaunchAtLoginModel()

    var body: some View {
        GroupBox("Startup") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.isRegistered },
                    set: { enabled in Task { await model.setEnabled(enabled) } }
                ))
                .disabled(model.isUpdating)

                if model.status == .requiresApproval {
                    Text("Approval required in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Open Login Items Settings...") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}
