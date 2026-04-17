import AppKit
import Observation
import SwiftUI

#if canImport(AgentBarCore)
import AgentBarCore
#endif

@MainActor
final class AgentBarStatusController: NSObject {
    private static let popoverMaximumContentSize = CGSize(width: 1440, height: 1040)
    private static let popoverScreenMargin: CGFloat = 80

    private let model: AppModel
    private let settingsWindowController: AgentBarSettingsWindowController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var hostingController: NSHostingController<MenuBarView>?
    private var preferredPopoverContentSize = MenuBarView.minimumContentSize

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
        let hostingController = NSHostingController(
            rootView: MenuBarView(
                model: model,
                openSettingsAction: { [weak self] in
                    self?.showSettings()
                },
                onPreferredSizeChange: { [weak self] size in
                    self?.updatePopoverContentSize(preferredSize: size)
                }
            )
        )
        self.hostingController = hostingController
        popover.contentViewController = hostingController
        updatePopoverContentSize(preferredSize: preferredPopoverContentSize)
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
                self?.updatePopoverContentSize()
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
            updatePopoverContentSize(screen: button.window?.screen)
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

    private func updatePopoverContentSize(
        preferredSize: CGSize? = nil,
        screen: NSScreen? = nil
    ) {
        if let preferredSize {
            preferredPopoverContentSize = preferredSize
        } else if let hostingController {
            hostingController.view.layoutSubtreeIfNeeded()
            let fittedSize = hostingController.view.fittingSize
            preferredPopoverContentSize = CGSize(
                width: max(fittedSize.width, MenuBarView.minimumContentSize.width),
                height: max(fittedSize.height, MenuBarView.minimumContentSize.height)
            )
        }

        let constrainedSize = constrainedPopoverContentSize(
            for: preferredPopoverContentSize,
            screen: screen ?? statusItem.button?.window?.screen
        )
        popover.contentSize = constrainedSize
    }

    private func constrainedPopoverContentSize(
        for preferredSize: CGSize,
        screen: NSScreen?
    ) -> CGSize {
        let visibleFrame = (screen ?? NSScreen.main)?.visibleFrame
        let maximumWidth = min(
            Self.popoverMaximumContentSize.width,
            max(
                MenuBarView.minimumContentSize.width,
                (visibleFrame?.width ?? Self.popoverMaximumContentSize.width) - Self.popoverScreenMargin
            )
        )
        let maximumHeight = min(
            Self.popoverMaximumContentSize.height,
            max(
                MenuBarView.minimumContentSize.height,
                (visibleFrame?.height ?? Self.popoverMaximumContentSize.height) - Self.popoverScreenMargin
            )
        )

        return CGSize(
            width: min(max(preferredSize.width, MenuBarView.minimumContentSize.width), maximumWidth),
            height: min(max(preferredSize.height, MenuBarView.minimumContentSize.height), maximumHeight)
        )
    }
}
