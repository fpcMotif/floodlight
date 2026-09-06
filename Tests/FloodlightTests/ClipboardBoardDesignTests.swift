import AppKit
import FloodlightEngine
import FloodlightTestSupport
import Foundation
import os
import Testing
@testable import Floodlight

/// The board's design contract after the clipboard design review: a panel
/// tall enough for its footer, one source-app name everywhere, a pin that
/// is state rather than title text, and an Actions menu that only promises
/// chords the panel honours.
@MainActor
struct ClipboardBoardDesignTests {
    private let tree: TemporaryTree

    init() throws {
        tree = try TemporaryTree(label: "ClipboardBoardDesign")
    }

    private func makeCoordinator(
        clipboardStore: ClipboardHistoryStore
    ) throws -> SearchCoordinator {
        try SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: ScriptedCatalog(),
                settings: ScriptedCatalog()
            ),
            recentStore: RecentStore(defaults: IsolatedDefaults().defaults),
            clipboardStore: clipboardStore,
            rootURL: tree.root,
            assistantRunner: ScriptedAssistantRunner(),
            onDismiss: {}
        )
    }

    // MARK: - Geometry

    @Test func clipboardModeAddsTheFooterAndWellInsetToThePanelHeight() {
        // Clipboard mode has no divider under the search row — the well's
        // top edge is the seam — so it does not compose from
        // `expandedPanelHeight`, which still carries that divider for every
        // other mode. It instead adds the well's own bottom inset.
        #expect(FloodlightMetrics.clipboardPanelHeight == FloodlightMetrics.searchHeight
            + FloodlightMetrics.filterBarHeight
            + FloodlightMetrics.resultPadding * 2
            + CGFloat(FloodlightMetrics.maximumVisibleResults) * FloodlightMetrics.resultRowHeight
            + 1
            + FloodlightMetrics.clipboardFooterHeight
            + FloodlightMetrics.clipboardWellInset)
        #expect(FloodlightMetrics.panelHeight(hasQuery: true, isClipboardMode: true)
            == FloodlightMetrics.clipboardPanelHeight)
        #expect(FloodlightMetrics.panelHeight(hasQuery: true, isClipboardMode: false)
            == FloodlightMetrics.expandedPanelHeight)
        #expect(FloodlightMetrics.panelHeight(hasQuery: false, isClipboardMode: true)
            == FloodlightMetrics.searchHeight)
    }

    @Test func clipboardWellGeometryIsConcentricWithThePanel() {
        #expect(FloodlightMetrics.clipboardWellInset == FloodlightMetrics.resultPadding)
        #expect(FloodlightMetrics.clipboardWellCornerRadius
            == FloodlightMetrics.cornerRadius - FloodlightMetrics.clipboardWellInset)
        #expect(FloodlightMetrics.clipboardPanelWidth == FloodlightMetrics.clipboardListWidth
            + 1
            + FloodlightMetrics.clipboardInspectorWidth
            + FloodlightMetrics.clipboardWellInset * 2)
        #expect(FloodlightMetrics.clipboardPanelWidth == 840)
        #expect(FloodlightMetrics.clipboardPanelHeight == 560)
    }

    // MARK: - Source app names

    @Test func sourceAppNamesResolveThroughOneSeam() {
        #expect(ClipboardSourceApp.displayName(for: nil) == "Clipboard")
        #expect(ClipboardSourceApp.displayName(for: "") == "Clipboard")
        #expect(ClipboardSourceApp.displayName(for: "com.apple.finder") == "Finder")
        #expect(ClipboardSourceApp.displayName(for: "com.apple.screencaptureui") == "Screenshot")
        #expect(ClipboardSourceApp.displayName(for: "com.example.NoSuchApp") == "NoSuchApp")
        #expect(ClipboardSourceApp.displayName(for: "singleword") == "singleword")
    }

    @Test func anUnresolvableSourceAppCostsOneLookup() {
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        let resolver = ClipboardSourceApp { _ in
            lookups.withLock { $0 += 1 }
            return nil
        }

        let first = resolver.resolution(for: "com.apple.screencaptureui")
        let second = resolver.resolution(for: "com.apple.screencaptureui")
        let lookupCount = lookups.withLock { $0 }

        #expect(first?.name == "Screenshot")
        #expect(first?.applicationURL == nil)
        #expect(second?.name == "Screenshot")
        #expect(lookupCount == 1)
    }

    @Test func theListAndTheInspectorAgreeOnTheSourceAppName() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "one", sourceAppBundleID: "com.apple.finder")
        let coordinator = try makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        let row = try #require(coordinator.results.first)
        let inspector = try #require(coordinator.clipboardInspector)
        #expect(row.subtitle.hasPrefix("Finder · "))
        #expect(inspector.sourceApp == "Finder")
    }

    // MARK: - Pinned state

    @Test func pinnedEntriesCarryTheirPinDateIntoTheInspector() {
        let pinnedAt = Date(timeIntervalSince1970: 1_785_250_800)
        let snapshot = ClipboardInspector.snapshot(for: ClipboardEntry(
            id: "pinned-text",
            text: "git rebase -i HEAD~3",
            pinnedAt: pinnedAt
        ))
        guard case let .text(detail) = snapshot else {
            Issue.record("expected a text snapshot")
            return
        }
        #expect(detail.pinnedAt == pinnedAt)

        let plain = ClipboardInspector.snapshot(for: ClipboardEntry(id: "plain", text: "x"))
        guard case let .text(plainDetail) = plain else {
            Issue.record("expected a text snapshot")
            return
        }
        #expect(plainDetail.pinnedAt == nil)
    }

    @Test func pinnedRowsKeepTheirContentTypeIconAndTitle() throws {
        let store = ClipboardHistoryStore.inMemory()
        let link = try #require(store.record(text: "https://example.com/a"))
        store.pin(id: link.id)
        let coordinator = try makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        let row = try #require(coordinator.results.first)
        #expect(row.isPinned)
        #expect(row.title == "https://example.com/a")
        #expect(row.iconSource == .engine(symbol: "link", tint: .blue))
        #expect(coordinator.isSelectionPinned)
    }

    // MARK: - Timestamps

    @Test func detailedDatesAreRelativeForTodayAndCarryNoSeconds() {
        let now = Date()
        let today = ClipboardInspector.formattedDetailedDate(now)
        #expect(today.hasPrefix("Today at "))
        #expect(today.filter { $0 == ":" }.count == 1)

        let lastYear = Calendar.current.date(byAdding: .year, value: -1, to: now) ?? now
        let old = ClipboardInspector.formattedDetailedDate(lastYear)
        #expect(!old.hasPrefix("Today"))
        #expect(!old.hasPrefix("Yesterday"))
        #expect(old.filter { $0 == ":" }.count == 1)
    }

    // MARK: - Actions menu

    @Test func theActionsMenuOffersOnlyChordsThePanelHonours() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "plain text")
        let coordinator = try makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        let actions = ClipboardMenuAction.available(
            for: coordinator,
            boardContext: ClipboardBoardContext(pasteTargetAppName: "Safari"),
            pasteLabel: "Paste to Safari"
        )
        #expect(actions.map(\.title) == [
            "Paste to Safari", "Copy", "Quick Look", "Show in Finder", "Pin", "Delete",
        ])

        // Every chord shown must map to a real panel command.
        for action in actions where action.modifiers.contains(.command) {
            let command = FloodlightPanelController.panelCommand(
                for: action.keyEquivalent,
                shiftHeld: false
            )
            #expect(command != .unmatched, "no panel command behind ⌘\(action.keyEquivalent)")
        }

        // A plain text entry has nothing to preview or reveal.
        let byTitle = Dictionary(uniqueKeysWithValues: actions.map { ($0.title, $0) })
        #expect(byTitle["Quick Look"]?.isEnabled == false)
        #expect(byTitle["Show in Finder"]?.isEnabled == false)
        #expect(byTitle["Copy"]?.isEnabled == true)
    }

    @Test func theActionsMenuFlipsPinToUnpinAndEnablesFileActionsForFiles() throws {
        let store = ClipboardHistoryStore.inMemory()
        let fileURL = tree.root.appendingPathComponent("design.png")
        try Data([0x01, 0x02]).write(to: fileURL)
        let entry = try #require(store.recordFile(path: fileURL.path))
        store.pin(id: entry.id)
        let coordinator = try makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        let actions = ClipboardMenuAction.available(
            for: coordinator,
            boardContext: ClipboardBoardContext(),
            pasteLabel: "Paste"
        )
        let byTitle = Dictionary(uniqueKeysWithValues: actions.map { ($0.title, $0) })
        #expect(byTitle["Unpin"] != nil)
        #expect(byTitle["Pin"] == nil)
        #expect(byTitle["Quick Look"]?.isEnabled == true)
        #expect(byTitle["Show in Finder"]?.isEnabled == true)
        #expect(coordinator.selectionFileURL == fileURL)
    }

    @Test func commandKRoutesToTheBoardContextOnlyInClipboardMode() {
        let context = ClipboardBoardContext()
        var opened = 0
        context.actionsHandler = { opened += 1 }
        context.requestActions()
        #expect(opened == 1)
        #expect(FloodlightPanelController.panelCommand(for: "k", shiftHeld: false) == .openActions)
    }
}
