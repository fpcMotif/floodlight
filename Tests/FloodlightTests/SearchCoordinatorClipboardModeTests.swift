import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// The session's side of Clipboard mode: Search Mode transitions, and that
/// the query, filter, and selection reach Clipboard Search and its answers
/// come back. What those answers contain is Clipboard Search's suite.
@MainActor
struct SearchCoordinatorClipboardModeTests {
    private let tree: TemporaryTree

    init() throws {
        tree = try TemporaryTree(label: "CoordinatorClipboardMode")
    }

    private func makeCoordinator(
        clipboardSearch: ClipboardSearch = ClipboardSearch(store: ClipboardHistoryStore.inMemory()),
        actionEffects: any SelectedResultActionEffects = AppKitSelectedResultActionEffects(),
        onDismiss: @escaping @MainActor () -> Void = {}
    ) throws -> SearchCoordinator {
        try SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: ScriptedCatalog(),
                settings: ScriptedCatalog()
            ),
            recentStore: RecentStore(defaults: IsolatedDefaults().defaults),
            blocklistStore: BlocklistStore(defaults: IsolatedDefaults().defaults),
            clipboardSearch: clipboardSearch,
            rootURL: tree.root,
            assistantRunner: ScriptedAssistantRunner(),
            actionEffects: actionEffects,
            onDismiss: onDismiss
        )
    }

    private func makeSearch(over store: ClipboardHistoryStore) -> ClipboardSearch {
        ClipboardSearch(
            store: store,
            previewDirectory: tree.root.appendingPathComponent("previews", isDirectory: true)
        )
    }

    // MARK: - Entering clipboard mode

    @Test func tabOnClipEntersClipboardModeAndPublishesHistoryRowsImmediately() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Old copy")
        _ = store.record(text: "New copy")

        let coordinator = try makeCoordinator(clipboardSearch: makeSearch(over: store))
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(coordinator.query.isEmpty)
        #expect(coordinator.results.map(\.title) == ["New copy", "Old copy"])
        #expect(coordinator.selectedID == coordinator.results[0].id)
    }

    @Test func enteringClipboardModePublishesWhatClipboardSearchReturns() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Acme billing address")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"))
        let clock = Date()
        let search = ClipboardSearch(store: store, now: { clock })
        let reference = ClipboardSearch(store: store, now: { clock })

        let coordinator = try makeCoordinator(clipboardSearch: search)
        coordinator.query = "clip"
        coordinator.handleTab()

        let expected = reference.publication(query: "", selectedFilter: .all, selection: nil)
        #expect(coordinator.results == expected.visibleRows)
        #expect(coordinator.filterOptions == expected.filterOptions)
        #expect(coordinator.selectedID == expected.selection?.id)
        #expect(search.inspector == reference.inspector)
        #expect(search.inspector != nil)
    }

    @Test func tabOnClipWithRemainderFiltersImmediately() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Invoice #101")
        _ = store.record(text: "Receipt #202")

        let coordinator = try makeCoordinator(clipboardSearch: makeSearch(over: store))
        coordinator.query = "clip Invoice"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(coordinator.query == "Invoice")
        #expect(coordinator.results.map(\.title) == ["Invoice #101"])
    }

    // MARK: - Query, filter, and selection reach Clipboard Search

    @Test func clipboardModePublishesTypeChipsAndSelectFilterScopesRows() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Acme billing address")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"))
        _ = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 32,
            height: 16,
            displayName: "Screenshot 2026-09-01.png"
        ))

        let coordinator = try makeCoordinator(clipboardSearch: makeSearch(over: store))
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.filterOptions.map(\.filter) == [.all, .text, .files, .images])
        #expect(coordinator.filterOptions.map(\.count) == [3, 1, 1, 1])
        #expect(coordinator.selectedFilter == .all)
        #expect(coordinator.results.count == 3)

        coordinator.selectFilter(.text)
        #expect(coordinator.selectedFilter == .text)
        #expect(coordinator.results.map(\.title) == ["Acme billing address"])

        coordinator.selectFilter(.files)
        #expect(coordinator.results.map(\.title) == ["Invoice_Q3_Final.pdf"])

        coordinator.selectFilter(.images)
        #expect(coordinator.results.map(\.title) == ["Screenshot 2026-09-01.png"])

        coordinator.selectFilter(.all)
        #expect(coordinator.results.count == 3)
    }

    @Test func clipboardQueryFiltersWithinTheActiveTypeTab() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Invoice #101")
        _ = store.record(text: "Receipt #202")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"))
        _ = try #require(store.recordFile(path: "/Users/f/Downloads/Receipt.pdf"))

        let coordinator = try makeCoordinator(clipboardSearch: makeSearch(over: store))
        coordinator.query = "clip"
        coordinator.handleTab()
        coordinator.selectFilter(.files)
        coordinator.query = "Invoice"

        #expect(coordinator.selectedFilter == .files)
        #expect(coordinator.results.map(\.title) == ["Invoice_Q3_Final.pdf"])
    }

    @Test func enteringClipboardModeStartsOnAllRegardlessOfLocalFilter() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Snippet")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice.pdf"))
        let coordinator = try makeCoordinator(clipboardSearch: makeSearch(over: store))
        coordinator.query = "xcode"
        coordinator.selectFilter(.files)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(coordinator.selectedFilter == .all)
        #expect(coordinator.results.count == 2)
    }

    @Test func movingTheSelectionReachesClipboardSearch() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Acme billing address")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"))
        let search = makeSearch(over: store)

        let coordinator = try makeCoordinator(clipboardSearch: search)
        coordinator.query = "clip"
        coordinator.handleTab()

        guard case .file = search.inspector else {
            Issue.record("the newest file entry should be inspected first")
            return
        }

        coordinator.moveSelection(by: 1)
        guard case let .text(text) = search.inspector else {
            Issue.record("moving the selection should inspect the text entry")
            return
        }
        #expect(text.body == "Acme billing address")

        let file = try #require(coordinator.results.first { $0.title == "Invoice_Q3_Final.pdf" })
        coordinator.select(file)
        guard case .file = search.inspector else {
            Issue.record("selecting a row should inspect it")
            return
        }
    }

    // MARK: - Clipboard Search's commands republish through the session

    @Test func pinningThroughClipboardSearchRepublishesTheRows() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "First"))
        _ = try #require(store.record(text: "Second"))
        let search = makeSearch(over: store)

        let coordinator = try makeCoordinator(clipboardSearch: search)
        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(coordinator.results.map(\.title) == ["Second", "First"])

        coordinator.moveSelection(by: 1)
        search.togglePinSelection()

        // The pinned entry leads the list and stays selected.
        #expect(coordinator.results.map(\.title) == ["First", "Second"])
        #expect(coordinator.results[0].isPinned)
        #expect(coordinator.selectedID == coordinator.results[0].id)
        #expect(search.isSelectionPinned)

        search.togglePinSelection()
        #expect(coordinator.results.map(\.title) == ["Second", "First"])
        #expect(!search.isSelectionPinned)
    }

    @Test func deletingThroughClipboardSearchRepublishesTheRows() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "Keep me"))
        _ = try #require(store.record(text: "Delete me"))
        let search = makeSearch(over: store)

        let coordinator = try makeCoordinator(clipboardSearch: search)
        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(coordinator.results.map(\.title) == ["Delete me", "Keep me"])

        search.deleteSelection()

        #expect(coordinator.results.map(\.title) == ["Keep me"])
        #expect(coordinator.selectedID == coordinator.results[0].id)
        guard case let .text(remaining) = search.inspector else {
            Issue.record("the remaining entry should be inspected")
            return
        }
        #expect(remaining.body == "Keep me")
    }

    // MARK: - Activation

    /// A captured image row names its entry rather than carrying the bytes,
    /// so this is the activation that reaches Clipboard Search for its
    /// restore payload; file and text rows carry theirs in the action.
    @Test func openSelectionRestoresImageDataAndDismisses() throws {
        let store = ClipboardHistoryStore.inMemory()
        let png = ClipboardImageTestData.png
        let tiff = ClipboardImageTestData.tiff
        _ = try #require(store.recordImage(
            pngData: png,
            tiffData: tiff,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 2_880,
            height: 1_800,
            displayName: "CleanShot 2026-09-01 at 15.30.png"
        ))

        var dismissed = false
        var writtenImages: [(png: Data?, tiff: Data?)] = []

        let effects = ScriptedActionEffects(
            onWrite: { _ in true },
            onWriteImage: { pngData, tiffData in
                writtenImages.append((pngData, tiffData))
                return true
            }
        )

        let coordinator = try makeCoordinator(
            clipboardSearch: makeSearch(over: store),
            actionEffects: effects,
            onDismiss: { dismissed = true }
        )

        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(coordinator.results.map(\.title) == ["CleanShot 2026-09-01 at 15.30.png"])

        coordinator.openSelection()

        #expect(writtenImages.count == 1)
        #expect(writtenImages[0].png == png)
        #expect(writtenImages[0].tiff == tiff)
        #expect(dismissed)
    }

    @Test func openSelectionRestoresNativeFileReferencesAndDismisses() throws {
        let store = ClipboardHistoryStore.inMemory()
        let path = "/Users/f/Documents/Invoices/Invoice_2026.pdf"
        _ = try #require(store.recordFile(path: path))

        var dismissed = false
        var writtenFiles: [[String]] = []
        var writtenText: [String] = []

        let effects = ScriptedActionEffects(
            onWrite: { value in
                writtenText.append(value)
                return true
            },
            onWriteFiles: { paths in
                writtenFiles.append(paths)
                return true
            }
        )

        let coordinator = try makeCoordinator(
            clipboardSearch: makeSearch(over: store),
            actionEffects: effects,
            onDismiss: { dismissed = true }
        )

        coordinator.query = "clip"
        coordinator.handleTab()
        coordinator.openSelection()

        #expect(writtenFiles == [[path]])
        #expect(writtenText.isEmpty)
        #expect(dismissed)
    }

    // MARK: - Preview and Finder delegate to Clipboard Search

    @Test func previewAndFinderFollowClipboardSearchWhileInClipboardMode() throws {
        let store = ClipboardHistoryStore.inMemory()
        let fileURL = tree.root.appendingPathComponent("sample.mp4")
        try Data("video-bytes".utf8).write(to: fileURL)
        _ = try #require(store.record(text: "just some copied words"))
        _ = try #require(store.recordFile(path: fileURL.path))
        let search = makeSearch(over: store)
        var revealed: [URL] = []
        let effects = ScriptedActionEffects(
            onWrite: { _ in true },
            onReveal: { revealed.append($0) }
        )

        let coordinator = try makeCoordinator(clipboardSearch: search, actionEffects: effects)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.isSelectionPreviewable == search.isSelectionPreviewable)
        #expect(coordinator.isSelectionPreviewable)
        #expect(coordinator.previewableSelectionURL == fileURL)
        #expect(coordinator.previewableSelectionURL == search.materializePreviewURL())
        coordinator.revealSelection()
        #expect(revealed == [fileURL])

        coordinator.moveSelection(by: 1)
        #expect(coordinator.isSelectionPreviewable == search.isSelectionPreviewable)
        #expect(!coordinator.isSelectionPreviewable)
        #expect(coordinator.previewableSelectionURL == nil)
    }

    // MARK: - Exiting clipboard mode

    @Test func escapeExitsClipboardModeAndRestoresFieldQuery() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Sample")

        let coordinator = try makeCoordinator(clipboardSearch: makeSearch(over: store))
        coordinator.query = "clip invoice"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(coordinator.query == "invoice")

        coordinator.handleEscape()

        #expect(!coordinator.isClipboardMode)
        #expect(coordinator.query == "clip invoice")
    }

    @Test func secondEscapeDismissesPanel() throws {
        var dismissed = false
        let coordinator = try makeCoordinator(onDismiss: { dismissed = true })

        coordinator.query = "clip"
        coordinator.handleTab()

        coordinator.handleEscape()
        #expect(!dismissed, "first escape exits mode only")
        #expect(!coordinator.isClipboardMode)

        coordinator.handleEscape()
        #expect(dismissed, "second escape dismisses panel")
    }

    @Test func leavingClipboardModeResetsTheTypeFilter() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Snippet")
        let coordinator = try makeCoordinator(clipboardSearch: makeSearch(over: store))
        coordinator.query = "clip"
        coordinator.handleTab()
        coordinator.selectFilter(.text)
        #expect(coordinator.selectedFilter == .text)

        coordinator.handleEscape()

        #expect(!coordinator.isClipboardMode)
        #expect(coordinator.selectedFilter == .all)
    }

    /// A copied path stays a path row after the file is gone (#73); acting
    /// on it is where existence is decided, so Finder is asked for nothing.
    @Test func revealingACopiedPathToAMissingFileShowsNothing() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "/definitely/missing/report.pdf"))
        let search = makeSearch(over: store)
        var revealed: [URL] = []
        let effects = ScriptedActionEffects(
            onWrite: { _ in true },
            onReveal: { revealed.append($0) }
        )

        let coordinator = try makeCoordinator(clipboardSearch: search, actionEffects: effects)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.results.first?.fileURL != nil)
        #expect(search.selectionFileURL == nil)
        #expect(!coordinator.isSelectionPreviewable)
        coordinator.revealSelection()
        #expect(revealed.isEmpty)
    }

    @Test func leavingClipboardModePublishesIdleLocalResultsAndClearsTheFacts() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoice.pdf"))
        let search = makeSearch(over: store)

        let coordinator = try makeCoordinator(clipboardSearch: search)
        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(search.inspector != nil)
        #expect(coordinator.isSelectionPreviewable)

        coordinator.handleEscape()

        // Esc restores the field text, so the local publication for "clip"
        // is what shows now — never a stale clipboard row or chip.
        #expect(!coordinator.isClipboardMode)
        #expect(coordinator.query == "clip")
        #expect(!coordinator.results.contains { $0.kind == .clipboard })
        #expect(!coordinator.filterOptions.contains { $0.filter == .text })
        #expect(search.inspector == nil)
        #expect(!search.isSelectionPreviewable)
        #expect(!coordinator.isSelectionPreviewable)
        #expect(coordinator.previewableSelectionURL == nil)
    }

    @Test func resettingTheSessionLeavesClipboardModeAndClearsTheFacts() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "Snippet"))
        let search = makeSearch(over: store)

        let coordinator = try makeCoordinator(clipboardSearch: search)
        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(search.inspector != nil)

        coordinator.reset()

        #expect(!coordinator.isClipboardMode)
        #expect(coordinator.query.isEmpty)
        #expect(coordinator.results.isEmpty)
        #expect(search.inspector == nil)

        // A command with nothing selected changes nothing and republishes
        // nothing: the idle local publication stays.
        #expect(!search.togglePinSelection())
        #expect(coordinator.results.isEmpty)
    }
}

private final class ScriptedActionEffects: SelectedResultActionEffects {
    let onWrite: (String) -> Bool
    let onWriteFiles: ([String]) -> Bool
    let onWriteImage: (Data?, Data?) -> Bool
    let onReveal: (URL) -> Void

    init(
        onWrite: @escaping (String) -> Bool,
        onWriteFiles: @escaping ([String]) -> Bool = { _ in true },
        onWriteImage: @escaping (Data?, Data?) -> Bool = { _, _ in true },
        onReveal: @escaping (URL) -> Void = { _ in }
    ) {
        self.onWrite = onWrite
        self.onWriteFiles = onWriteFiles
        self.onWriteImage = onWriteImage
        self.onReveal = onReveal
    }

    func writeToClipboard(_ value: String) -> Bool {
        onWrite(value)
    }

    func writeFilesToClipboard(_ paths: [String]) -> Bool {
        onWriteFiles(paths)
    }

    func writeImageDataToClipboard(png: Data?, tiff: Data?) -> Bool {
        onWriteImage(png, tiff)
    }

    func open(_ url: URL, asApplication: Bool) async throws {}

    func revealInFinder(_ url: URL) {
        onReveal(url)
    }
}
