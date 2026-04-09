import AppKit
import Observation
import SwiftUI

@MainActor
final class AgentBarStatusController: NSObject {
    private let model: AppModel
    private let settingsWindowController: AgentBarSettingsWindowController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(
        model: AppModel,
        settingsWindowController: AgentBarSettingsWindowController
    ) {
        self.model = model
        self.settingsWindowController = settingsWindowController
        super.init()
        configureStatusItem()
        configurePopover()
        startObservation()
        updateStatusItem()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover)
        button.sendAction(on: [.leftMouseUp])
        button.imagePosition = .imageLeading
        button.imageScaling = .scaleProportionallyDown
        button.lineBreakMode = .byClipping
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 340, height: 500)
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(
                model: model,
                openSettingsAction: { [weak self] in
                    self?.showSettings()
                }
            )
        )
    }

    private func startObservation() {
        withObservationTracking {
            _ = model.menuBarTitle
            _ = model.menuBarAccessibilityTitle
            _ = model.statusIconUsedPercents
            _ = model.menuBarIconEmphasis
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
                self?.startObservation()
            }
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        button.title = model.menuBarTitle
        button.image = MenuBarStatusImage.make(
            usedPercents: model.statusIconUsedPercents,
            emphasis: model.menuBarIconEmphasis
        )
        button.setAccessibilityTitle(model.menuBarAccessibilityTitle)
        button.toolTip = model.menuBarAccessibilityTitle
    }

    @objc
    private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func openSettingsForTesting() {
        showSettings()
    }

    private func showSettings() {
        logInfo("Opening settings window from status popover")
        popover.performClose(nil)
        let settingsWindowController = settingsWindowController
        DispatchQueue.main.async {
            settingsWindowController.show()
        }
    }
}
