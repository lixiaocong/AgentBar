import AppKit
import Foundation
import Testing
@testable import AgentBar

@Test
@MainActor
func historyWindowUsesNativeSidebarSplitView() throws {
    let testDirectory = FileManager.default.temporaryDirectory
        .appending(path: "AgentBarHistoryWindowTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testDirectory) }

    let suiteName = "AgentBarHistoryWindowTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let manager = QuotaHistoryManager(
        store: QuotaHistoryStore(databaseURL: testDirectory.appending(path: "history.sqlite3")),
        userDefaults: defaults
    )
    let model = AppModel(
        userDefaults: defaults,
        historyRecorder: manager,
        startImmediately: false
    )
    let controller = AgentBarHistoryWindowController(model: model, historyManager: manager)

    let splitViewController = try #require(
        controller.window?.contentViewController as? NSSplitViewController
    )
    #expect(splitViewController.splitViewItems.count == 2)

    let sidebarItem = splitViewController.splitViewItems[0]
    #expect(sidebarItem.behavior == .sidebar)
    #expect(sidebarItem.canCollapse)
    #expect(sidebarItem.collapseBehavior == .preferResizingSiblingsWithFixedSplitView)
    #expect(sidebarItem.minimumThickness == 240)
    #expect(sidebarItem.maximumThickness == 360)

    let toolbar = try #require(controller.window?.toolbar)
    #expect(toolbar.allowsUserCustomization == false)
    #expect(toolbar.displayMode == .iconOnly)
}
