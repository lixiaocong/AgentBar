import AppKit
import Foundation
import Testing
@testable import AgentBar
@testable import AgentBarCore

@Test
@MainActor
func settingsAccountsReorderThroughNativeListCallbacks() async throws {
    let suiteName = "SettingsAccountReorderingTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let manager = QuotaHistoryManager(
        store: QuotaHistoryStore(databaseURL: directory.appendingPathComponent("history.sqlite3")),
        userDefaults: defaults
    )
    manager.isEnabled = false
    let model = AppModel(userDefaults: defaults, historyRecorder: manager, startImmediately: false)
    for accountID in ["reorder-first", "reorder-second", "reorder-third"] {
        model.addConfiguredAccountDirectory(CodexAppAuthStore.accountDirectory(for: accountID), for: .codex)
    }
    for accountID in ["reorder-gemini-first", "reorder-gemini-second"] {
        model.addConfiguredAccountDirectory(
            AgentProviderAppAuthStore.accountDirectory(for: .gemini, accountID: accountID),
            for: .gemini
        )
    }
    model.addConfiguredAccountDirectory(
        AgentProviderAppAuthStore.accountDirectory(for: .claude, accountID: "single-account"),
        for: .claude
    )
    let codexAccounts = model.configuredAccounts(for: .codex)
    let geminiAccounts = model.configuredAccounts(for: .gemini)
    model.providerAvailability = .all
    model.menuBarMaxDisplayedAccounts = 3
    for remaining in [90.0, 60.0, 30.0] {
        model.codexSnapshot = AgentQuotaSnapshot(
            provider: .codex,
            accountLabel: "Account \(Int(remaining))",
            planType: nil,
            modelName: nil,
            sourceSummary: "Test",
            metrics: [AgentQuotaMetric(
                id: "five-hour",
                title: "5 hour window",
                usedPercent: 100 - remaining,
                usedLabel: "\(Int(100 - remaining))% used",
                remainingLabel: "\(Int(remaining))% left",
                resetsAt: nil
            )],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        model.moveAccounts(for: .codex, fromOffsets: IndexSet(integer: 0), toOffset: 3)
    }
    for status in model.accountStatuses(for: .codex).reversed() {
        model.setAccount(status.account, shownInMenuBar: true)
    }
    #expect(model.statusIconQuotaBars.map(\.remainingPercent) == [90, 60, 30])

    let controller = AgentBarSettingsWindowController(
        model: model,
        historyManager: manager,
        openHistoryAction: {}
    )
    let contentView = try #require(controller.window?.contentView)
    contentView.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    contentView.layoutSubtreeIfNeeded()

    let outline = try #require(descendantOutline(in: contentView))
    let dataSource = try #require(outline.dataSource)
    let draggableRows = (0..<outline.numberOfRows).filter { row in
        guard let item = outline.item(atRow: row) else { return false }
        return dataSource.outlineView?(outline, pasteboardWriterForItem: item) != nil
    }
    // Only the two groups with multiple accounts expose native drag sources.
    #expect(draggableRows.count == 5)

    let firstRow = try #require(draggableRows.first)
    let lastCodexRow = firstRow + 2
    let lastGeminiRow = try #require(draggableRows.last)
    let firstItem = try #require(outline.item(atRow: firstRow))
    let writer = try #require(dataSource.outlineView?(outline, pasteboardWriterForItem: firstItem))
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    #expect(pasteboard.writeObjects([writer]))
    let session = AccountReorderDraggingSession(pasteboard: pasteboard)
    dataSource.outlineView?(outline, draggingSession: session, willBeginAt: .zero, forItems: [firstItem])
    let info = AccountReorderDraggingInfo(source: outline, pasteboard: pasteboard)
    #expect(dataSource.outlineView?(
        outline, validateDrop: info, proposedItem: nil, proposedChildIndex: lastGeminiRow
    ) == [])
    let operation = dataSource.outlineView?(
        outline, validateDrop: info, proposedItem: nil, proposedChildIndex: lastCodexRow + 1
    )
    #expect(operation == .move)
    let accepted = dataSource.outlineView?(
        outline, acceptDrop: info, item: nil, childIndex: lastCodexRow + 1
    )
    #expect(accepted == true)
    let expectedOrder = [codexAccounts[1], codexAccounts[2], codexAccounts[0]]
    #expect(model.configuredAccounts(for: .codex) == expectedOrder)
    #expect(model.accountStatuses(for: .codex).map(\.account.directory) == expectedOrder)
    #expect(model.visibleAccountStatuses(for: .codex).map(\.account.directory) == expectedOrder)
    #expect(model.statusIconQuotaBars.map(\.remainingPercent) == [60, 30, 90])
    #expect(model.menuBarAccessibilityTitle ==
        "Account 60 Codex 60% remaining, Account 30 Codex 30% remaining, Account 90 Codex 90% remaining")
    #expect(model.configuredAccounts(for: .gemini) == geminiAccounts)
    let reloaded = AppModel(userDefaults: defaults, historyRecorder: manager, startImmediately: false)
    #expect(reloaded.configuredAccounts(for: .codex) == expectedOrder)
    dataSource.outlineView?(outline, draggingSession: session, endedAt: .zero, operation: .move)
}

@MainActor
private func descendantOutline(in view: NSView) -> NSOutlineView? {
    if let outline = view as? NSOutlineView { return outline }
    return view.subviews.lazy.compactMap { descendantOutline(in: $0) }.first
}

private final class AccountReorderDraggingSession: NSDraggingSession {
    let pasteboard: NSPasteboard
    override var draggingPasteboard: NSPasteboard { pasteboard }
    override var draggingSequenceNumber: Int { 1 }

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init()
    }
}

@MainActor
private final class AccountReorderDraggingInfo: NSObject, NSDraggingInfo {
    let source: NSOutlineView
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { source.window }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(source: NSOutlineView, pasteboard: NSPasteboard) {
        self.source = source
        self.draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        for (index, item) in (draggingPasteboard.pasteboardItems ?? []).enumerated() {
            var stop: ObjCBool = false
            block(NSDraggingItem(pasteboardWriter: item), index, &stop)
            if stop.boolValue { break }
        }
    }
}
