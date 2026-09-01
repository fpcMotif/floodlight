import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

@MainActor
struct SearchCoordinatorClipboardModeTests {
    private let tree: TemporaryTree

    init() throws {
        tree = try TemporaryTree(label: "CoordinatorClipboardMode")
    }

    private func makeCoordinator(
        clipboardStore: ClipboardHistoryStore = ClipboardHistoryStore.inMemory(),
        actionEffects: any SelectedResultActionEffects = AppKitSelectedResultActionEffects(),
        onDismiss: @escaping @MainActor () -> Void = {}
    ) async throws -> SearchCoordinator {
        try SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: ScriptedCatalog(),
                settings: ScriptedCatalog()
            ),
            recentStore: RecentStore(defaults: IsolatedDefaults().defaults),
            blocklistStore: BlocklistStore(defaults: IsolatedDefaults().defaults),
            clipboardStore: clipboardStore,
            rootURL: tree.root,
            assistantRunner: ScriptedAssistantRunner(),
            actionEffects: actionEffects,
            onDismiss: onDismiss
        )
    }

    // MARK: - Entering clipboard mode

    @Test func tabOnClipEntersClipboardModeAndPublishesHistoryRowsImmediately() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Old copy")
        _ = store.record(text: "New copy")

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(coordinator.query.isEmpty)
        #expect(coordinator.results.count == 2)
        #expect(coordinator.results[0].title == "New copy")
        #expect(coordinator.results[1].title == "Old copy")
        #expect(coordinator.selectedID == coordinator.results[0].id)
    }

    @Test func tabOnClipWithRemainderFiltersImmediately() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Invoice #101")
        _ = store.record(text: "Receipt #202")

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip Invoice"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(coordinator.query == "Invoice")
        #expect(coordinator.results.count == 1)
        #expect(coordinator.results[0].title == "Invoice #101")
    }

    // MARK: - Activation

    @Test func openSelectionRestoresNativeFileReferencesAndDismisses() async throws {
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

        let coordinator = try await makeCoordinator(
            clipboardStore: store,
            actionEffects: effects,
            onDismiss: { dismissed = true }
        )

        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(coordinator.results.count == 1)
        #expect(coordinator.results[0].title == "Invoice_2026.pdf")
        #expect(coordinator.results[0].subtitle == path)

        coordinator.openSelection()

        #expect(writtenFiles == [[path]])
        #expect(writtenText.isEmpty)
        #expect(dismissed)
    }

    @Test func openSelectionRestoresImageDataAndDismisses() async throws {
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

        let coordinator = try await makeCoordinator(
            clipboardStore: store,
            actionEffects: effects,
            onDismiss: { dismissed = true }
        )

        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(coordinator.results.count == 1)
        #expect(coordinator.results[0].title == "CleanShot 2026-09-01 at 15.30.png")
        #expect(coordinator.results[0].subtitle.hasPrefix("2880×1800"))

        coordinator.openSelection()

        #expect(writtenImages.count == 1)
        #expect(writtenImages[0].png == png)
        #expect(writtenImages[0].tiff == tiff)
        #expect(dismissed)
    }

    @Test func copySelectionWritesAbsoluteFilePathWithoutDismissing() async throws {
        let store = ClipboardHistoryStore.inMemory()
        let path = "/Users/f/Movies/ProductDemo_4K.mov"
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

        let coordinator = try await makeCoordinator(
            clipboardStore: store,
            actionEffects: effects,
            onDismiss: { dismissed = true }
        )

        coordinator.query = "clip"
        coordinator.handleTab()
        coordinator.copySelection()

        #expect(writtenText == [path])
        #expect(writtenFiles.isEmpty)
        #expect(!dismissed)
    }

    @Test func openSelectionPutsExactTextOnClipboardAndDismisses() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Exact Multi-line\nText Snippet")

        var dismissed = false
        var writtenToClipboard: [String] = []

        let effects = ScriptedActionEffects(
            onWrite: { value in
                writtenToClipboard.append(value)
                return true
            }
        )

        let coordinator = try await makeCoordinator(
            clipboardStore: store,
            actionEffects: effects,
            onDismiss: { dismissed = true }
        )

        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(coordinator.results.count == 1)

        coordinator.openSelection()

        #expect(writtenToClipboard == ["Exact Multi-line\nText Snippet"])
        #expect(dismissed)
    }

    // MARK: - Administration Commands

    @Test func togglePinSelectionUpdatesPinStatusAndRowPosition() async throws {
        let store = ClipboardHistoryStore.inMemory()
        let e1 = try #require(store.record(text: "First"))
        let e2 = try #require(store.record(text: "Second"))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.results.map(\.id) == ["clipboard:\(e2.id)", "clipboard:\(e1.id)"])

        // Move to second item (e1) and pin it
        coordinator.moveSelection(by: 1)
        #expect(coordinator.selectedID == "clipboard:\(e1.id)")

        coordinator.togglePinSelection()

        // Pinned item (e1) moves to top
        #expect(coordinator.results.map(\.id) == ["clipboard:\(e1.id)", "clipboard:\(e2.id)"])
        #expect(coordinator.results[0].title.hasPrefix("📌 "))

        // Toggle pin again unpins it
        coordinator.togglePinSelection()
        #expect(coordinator.results.map(\.id) == ["clipboard:\(e2.id)", "clipboard:\(e1.id)"])
    }

    @Test func deleteSelectionRemovesEntryFromResults() async throws {
        let store = ClipboardHistoryStore.inMemory()
        let e1 = try #require(store.record(text: "Keep me"))
        let e2 = try #require(store.record(text: "Delete me"))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.results.count == 2)
        #expect(coordinator.selectedID == "clipboard:\(e2.id)")

        coordinator.deleteSelection()

        #expect(coordinator.results.count == 1)
        #expect(coordinator.results[0].id == "clipboard:\(e1.id)")
    }

    @Test func clearHistoryWipesAllRows() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "One")
        _ = store.record(text: "Two")

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.results.count == 2)

        coordinator.clearHistory()

        #expect(coordinator.results.isEmpty)
    }

    // MARK: - Exiting clipboard mode

    @Test func escapeExitsClipboardModeAndRestoresFieldQuery() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Sample")

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip invoice"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(coordinator.query == "invoice")

        coordinator.handleEscape()

        #expect(!coordinator.isClipboardMode)
        #expect(coordinator.query == "clip invoice")
    }

    @Test func secondEscapeDismissesPanel() async throws {
        var dismissed = false
        let coordinator = try await makeCoordinator(onDismiss: { dismissed = true })

        coordinator.query = "clip"
        coordinator.handleTab()

        coordinator.handleEscape()
        #expect(!dismissed, "first escape exits mode only")
        #expect(!coordinator.isClipboardMode)

        coordinator.handleEscape()
        #expect(dismissed, "second escape dismisses panel")
    }

    // MARK: - Category filters

    @Test func clipboardModePublishesTypeChipsAndSelectFilterScopesRows() async throws {
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

        let coordinator = try await makeCoordinator(clipboardStore: store)
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

    @Test func clipboardQueryFiltersWithinTheActiveTypeTab() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Invoice #101")
        _ = store.record(text: "Receipt #202")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"))
        _ = try #require(store.recordFile(path: "/Users/f/Downloads/Receipt.pdf"))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()
        coordinator.selectFilter(.files)
        coordinator.query = "Invoice"

        #expect(coordinator.selectedFilter == .files)
        #expect(coordinator.results.map(\.title) == ["Invoice_Q3_Final.pdf"])
        #expect(!(coordinator.results.contains { $0.title.contains("#101") }))
    }

    @Test func leavingClipboardModeResetsTheTypeFilter() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Snippet")
        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()
        coordinator.selectFilter(.text)
        #expect(coordinator.selectedFilter == .text)

        coordinator.handleEscape()

        #expect(!coordinator.isClipboardMode)
        #expect(coordinator.selectedFilter == .all)
    }

    @Test func enteringClipboardModeStartsOnAllRegardlessOfLocalFilter() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Snippet")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice.pdf"))
        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "xcode"
        coordinator.selectFilter(.files)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(coordinator.selectedFilter == .all)
        #expect(coordinator.results.count == 2)
    }

    @Test func clipboardFileSelectionIsPreviewableAndRevealable() async throws {
        let store = ClipboardHistoryStore.inMemory()
        let path = "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"
        _ = try #require(store.recordFile(path: path))
        var revealed: [URL] = []
        var dismissed = false
        let effects = ScriptedActionEffects(
            onWrite: { _ in true },
            onReveal: { revealed.append($0) }
        )
        let coordinator = try await makeCoordinator(
            clipboardStore: store,
            actionEffects: effects,
            onDismiss: { dismissed = true }
        )
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.previewableSelectionURL == URL(fileURLWithPath: path))
        coordinator.revealSelection()
        #expect(revealed == [URL(fileURLWithPath: path)])
        #expect(dismissed)
    }

    @Test func clipboardInspectorFollowsTheSelectedEntry() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "Acme billing address")
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoices/Invoice_Q3_Final.pdf"))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        guard case let .file(file) = coordinator.clipboardInspector else {
            Issue.record("newest file entry should be inspected first")
            return
        }
        #expect(file.name == "Invoice_Q3_Final.pdf")

        coordinator.moveSelection(by: 1)
        guard case let .text(text) = coordinator.clipboardInspector else {
            Issue.record("moving selection should inspect the text entry")
            return
        }
        #expect(text.body == "Acme billing address")
    }

    @Test func previewableSelectionURLResolvesForClipboardImageAndFileEntries() async throws {
        let store = ClipboardHistoryStore.inMemory()
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let imageEntry = try #require(store.recordImage(
            pngData: pngBytes,
            tiffData: nil,
            thumbnailPNGData: pngBytes,
            width: 100,
            height: 100,
            displayName: "Screenshot"
        ))
        let fileURL = tree.root.appendingPathComponent("sample.mp4")
        try Data("video-bytes".utf8).write(to: fileURL)
        let fileEntry = try #require(store.recordFile(path: fileURL.path))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.results.count == 2)

        // First result is fileEntry (most recent)
        let fileItem = try #require(coordinator.results
            .first { $0.id == "clipboard:\(fileEntry.id)" })
        coordinator.select(fileItem)
        #expect(coordinator.previewableSelectionURL == fileURL)

        // Second result is imageEntry
        let imageItem = try #require(coordinator.results
            .first { $0.id == "clipboard:\(imageEntry.id)" })
        coordinator.select(imageItem)
        let imagePreviewURL = try #require(coordinator.previewableSelectionURL)
        #expect(FileManager.default.fileExists(atPath: imagePreviewURL.path))
        let diskBytes = try Data(contentsOf: imagePreviewURL)
        #expect(diskBytes == pngBytes)
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
