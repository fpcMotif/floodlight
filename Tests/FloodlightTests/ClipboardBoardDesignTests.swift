import AppKit
import FloodlightEngine
import FloodlightTestSupport
import Foundation
import os
import SwiftUI
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
            clipboardSearch: ClipboardSearch(store: clipboardStore),
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

    @Test func theListAndTheInspectorAgreeOnTheSourceAppName() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "one", sourceAppBundleID: "com.apple.finder")
        let coordinator = try makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        let row = try #require(coordinator.results.first)
        let inspector = try #require(coordinator.clipboardSearch.inspector)
        #expect(row.subtitle.hasPrefix("Finder · "))
        guard case let .text(detail) = inspector else {
            Issue.record("expected a text inspector snapshot")
            return
        }
        #expect(detail.sourceApp == "Finder")
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
        #expect(coordinator.clipboardSearch.isSelectionPinned)
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
            commands: ClipboardBoardCommands(session: coordinator),
            clipboardSearch: coordinator.clipboardSearch,
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
            commands: ClipboardBoardCommands(session: coordinator),
            clipboardSearch: coordinator.clipboardSearch,
            boardContext: ClipboardBoardContext(),
            pasteLabel: "Paste"
        )
        let byTitle = Dictionary(uniqueKeysWithValues: actions.map { ($0.title, $0) })
        #expect(byTitle["Unpin"] != nil)
        #expect(byTitle["Pin"] == nil)
        #expect(byTitle["Quick Look"]?.isEnabled == true)
        #expect(byTitle["Show in Finder"]?.isEnabled == true)
        #expect(coordinator.clipboardSearch.selectionFileURL == fileURL)
    }

    // MARK: - Materials

    /// Nothing is painted under the 60 pt search row in any mode (#94): the
    /// bar is the shared glass capsule, and the board's opaque well below it
    /// is the only surface clipboard mode adds. Sampled in the row's empty
    /// top strip — clear of the magnifier, the mode token, and the field —
    /// where a mode-conditional fill would be the only thing there.
    @Test func noModePaintsABackgroundUnderTheSearchRow() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Acme billing address")
        let clipboard = try makeCoordinator(clipboardStore: store)
        clipboard.query = "clip"
        clipboard.handleTab()
        #expect(clipboard.isClipboardMode)
        let idle = try makeCoordinator(clipboardStore: ClipboardHistoryStore.inMemory())

        for coordinator in [idle, clipboard] {
            let isClipboardMode = coordinator.isClipboardMode
            let width = FloodlightMetrics.resolvedPanelWidth(isClipboardMode: isClipboardMode)
            let panel = try rasterize(
                SearchView(model: coordinator, usesGlassSlab: true),
                width: width,
                height: isClipboardMode
                    ? FloodlightMetrics.clipboardPanelHeight
                    : FloodlightMetrics.searchHeight
            )
            // Six rows down: inside the 60 pt row, above the 24 pt field's
            // glyphs, and clear of the panel's own rounded top edge.
            for fraction in [0.4, 0.55, 0.7, 0.85] {
                let column = Int(width * fraction)
                #expect(
                    panel.alpha(column: column, row: 6) == 0,
                    "clipboard mode \(isClipboardMode): the search row paints at \(column)"
                )
            }
            // The well's filter bar is opaque where the row is bare — the
            // control that these samples read the row and not the board.
            if isClipboardMode {
                #expect(panel.alpha(
                    column: Int(width) / 2,
                    row: Int(FloodlightMetrics.searchHeight + FloodlightMetrics.filterBarHeight / 2)
                ) == 255)
            }
        }
    }

    /// One rasterized view's pixels, addressable from its top-left corner.
    private struct Raster {
        let bytes: [UInt8]
        let width: Int

        /// 0 where nothing painted, 255 where an opaque surface did.
        func alpha(column: Int, row: Int) -> UInt8 {
            bytes[(row * width + column) * 4 + 3]
        }
    }

    /// Renders `view` over a transparent background at the panel's real size
    /// — the same `ImageRenderer` seam `SearchViewRenderingTests` uses, with
    /// the pixels kept instead of discarded.
    private func rasterize(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Raster {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = 1
        let image = try #require(renderer.cgImage, sourceLocation: sourceLocation)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(
                CGContext(
                    data: buffer.baseAddress,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                sourceLocation: sourceLocation
            )
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
            )
        }
        return Raster(bytes: bytes, width: image.width)
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
