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
            EmptyView()
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            model.start()
        }

        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            logInfo("Launch argument requested settings window")
            showSettings()
        }

        if ProcessInfo.processInfo.arguments.contains("--simulate-settings-button") {
            logInfo("Launch argument requested simulated settings-button flow")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.showSettings()
            }
        }
    }

    func showSettings() {
        logInfo("Opening settings window")
        settingsWindowController?.show()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }
}
