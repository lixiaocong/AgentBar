import AppKit
import SwiftUI

#if canImport(AgentBarCore)
import AgentBarCore
#endif

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AgentBarAppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        appDelegate.configure(model: model)
    }

    var body: some Scene {
        Settings {
            SettingsView(model: model)
                .frame(width: 900, height: 680)
                .padding(20)
        }
    }
}

@MainActor
final class AgentBarAppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var settingsWindowController: AgentBarSettingsWindowController?
    private var statusController: AgentBarStatusController?

    func configure(model: AppModel) {
        self.model = model
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let model else { return }
        let settingsWindowController = AgentBarSettingsWindowController(model: model)
        self.settingsWindowController = settingsWindowController
        statusController = AgentBarStatusController(
            model: model,
            settingsWindowController: settingsWindowController
        )

        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            logInfo("Launch argument requested settings window")
            settingsWindowController.show()
        }

        if ProcessInfo.processInfo.arguments.contains("--simulate-settings-button"),
           let statusController {
            logInfo("Launch argument requested simulated settings-button flow")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                statusController.openSettingsForTesting()
            }
        }
    }
}
