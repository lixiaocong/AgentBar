import AppKit
import SwiftUI

@MainActor
final class AgentBarHistoryWindowController: NSWindowController, NSToolbarDelegate {
    private static let frameAutosaveName = "AgentBarHistoryWindow"
    private static let splitViewAutosaveName = "AgentBarHistorySplitView"
    private static let toolbarIdentifier = NSToolbar.Identifier("AgentBarHistoryToolbar")
    private static let sidebarToggleIdentifier = NSToolbarItem.Identifier("AgentBarHistoryToggleSidebar")
    private static let defaultSize = NSSize(width: 980, height: 700)
    private static let minimumSize = NSSize(width: 760, height: 520)
    private static let sidebarWidth: CGFloat = 288
    private static let screenMargin: CGFloat = 40

    private let splitViewController: NSSplitViewController
    private let toolbar: NSToolbar
    private let viewModel: QuotaHistoryViewModel
    private var hasPositionedWindow = false

    init(model: AppModel, historyManager: QuotaHistoryManager) {
        let viewModel = QuotaHistoryViewModel(model: model, manager: historyManager)
        let sidebarController = NSHostingController(
            rootView: QuotaHistorySidebarView(viewModel: viewModel)
        )
        let detailController = NSHostingController(
            rootView: QuotaHistoryDetailView(manager: historyManager, viewModel: viewModel)
        )

        // The native split view owns both panes' geometry. SwiftUI should fill
        // the assigned frame instead of feeding intrinsic widths back into it.
        sidebarController.sizingOptions = []
        detailController.sizingOptions = []

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 360
        sidebarItem.preferredThicknessFraction = Self.sidebarWidth / Self.defaultSize.width
        sidebarItem.canCollapse = true
        sidebarItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        sidebarItem.allowsFullHeightLayout = true

        let detailItem = NSSplitViewItem(viewController: detailController)
        detailItem.minimumThickness = 440
        detailItem.canCollapse = false

        let splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = Self.splitViewAutosaveName
        splitViewController.addSplitViewItem(sidebarItem)
        splitViewController.addSplitViewItem(detailItem)

        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Quota History"
        window.identifier = NSUserInterfaceItemIdentifier("AgentBarHistoryWindow")
        window.contentViewController = splitViewController
        window.contentMinSize = Self.minimumSize
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        self.splitViewController = splitViewController
        self.toolbar = toolbar
        self.viewModel = viewModel
        super.init(window: window)

        toolbar.delegate = self
        window.toolbar = toolbar
        hasPositionedWindow = window.setFrameUsingName(Self.frameAutosaveName)
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(on preferredScreen: NSScreen?) {
        guard let window else { return }

        if !hasPositionedWindow || !isVisibleOnAnyScreen(window.frame) {
            position(window, on: preferredScreen ?? screenUnderMouse() ?? NSScreen.main)
            hasPositionedWindow = true
        }

        NSRunningApplication.current.activate(options: [])
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleIdentifier]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleIdentifier]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.sidebarToggleIdentifier else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "Toggle Sidebar"
        item.paletteLabel = "Toggle Sidebar"
        item.toolTip = "Show or hide the account sidebar"
        item.image = NSImage(
            systemSymbolName: "sidebar.left",
            accessibilityDescription: "Toggle Sidebar"
        )
        item.target = splitViewController
        item.action = #selector(NSSplitViewController.toggleSidebar(_:))
        item.isNavigational = true
        item.visibilityPriority = .high
        return item
    }

    private func position(_ window: NSWindow, on screen: NSScreen?) {
        guard let screen else {
            window.center()
            return
        }

        let visibleFrame = screen.visibleFrame.insetBy(dx: Self.screenMargin, dy: Self.screenMargin)
        let size = NSSize(
            width: min(Self.defaultSize.width, visibleFrame.width),
            height: min(Self.defaultSize.height, visibleFrame.height)
        )
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func isVisibleOnAnyScreen(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            screen.visibleFrame.intersection(frame).width >= 120 &&
                screen.visibleFrame.intersection(frame).height >= 80
        }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}
