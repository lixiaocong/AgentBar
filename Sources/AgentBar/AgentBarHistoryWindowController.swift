import AppKit
import SwiftUI

@MainActor
final class AgentBarHistoryWindowController: NSWindowController {
    private static let frameAutosaveName = "AgentBarHistoryWindow"
    private static let defaultSize = NSSize(width: 980, height: 700)
    private static let minimumSize = NSSize(width: 760, height: 520)
    private static let screenMargin: CGFloat = 40

    private var hasPositionedWindow = false

    init(model: AppModel, historyManager: QuotaHistoryManager) {
        let hostingController = NSHostingController(
            rootView: QuotaHistoryView(model: model, manager: historyManager)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Quota History"
        window.identifier = NSUserInterfaceItemIdentifier("AgentBarHistoryWindow")
        window.contentViewController = hostingController
        window.contentMinSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenNone)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
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
