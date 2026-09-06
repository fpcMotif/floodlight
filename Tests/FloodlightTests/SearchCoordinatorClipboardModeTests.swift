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
        // The row's subtitle is "App · age · ParentFolder", not the full
        // path — that lives in the inspector beside the list.
        #expect(coordinator.results[0].subtitle == "Clipboard · just now · Invoices")

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
        // The row's subtitle is "App · age · dimensions"; the dimensions
        // are the trailing detail, not the leading one.
        #expect(coordinator.results[0].subtitle.hasSuffix("2880×1800"))

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
        #expect(coordinator.results[0].isPinned)

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

    @Test func previewableSelectionURLResolvesForLocalPathTextEntries() async throws {
        let store = ClipboardHistoryStore.inMemory()
        let shotURL = tree.root.appendingPathComponent("shot.png")
        try Data("shot-bytes".utf8).write(to: shotURL)
        let existingEntry = try #require(store.record(text: shotURL.path))
        let missingEntry = try #require(store.record(text: "/definitely/missing/file.png"))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.results.count == 2)

        let existingItem = try #require(coordinator.results
            .first { $0.id == "clipboard:\(existingEntry.id)" })
        coordinator.select(existingItem)
        #expect(coordinator.previewableSelectionURL == URL(fileURLWithPath: shotURL.path))

        let missingItem = try #require(coordinator.results
            .first { $0.id == "clipboard:\(missingEntry.id)" })
        coordinator.select(missingItem)
        #expect(coordinator.previewableSelectionURL == nil)
    }

    // MARK: - Published inspector snapshot and previewability (#72)

    @Test func imageSelectionPublishesItsSnapshotWithoutTouchingThePayload() async throws {
        let store = ClipboardHistoryStore.inMemory()
        let entry = try #require(store.recordImage(
            pngData: ClipboardImageTestData.png,
            tiffData: nil,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 2_880,
            height: 1_800,
            displayName: "Screenshot"
        ))
        let previewURL = ClipboardImageTestData.previewURL(entryID: entry.id)
        try? FileManager.default.removeItem(at: previewURL)

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        guard case let .image(detail) = coordinator.clipboardInspector else {
            Issue.record("selecting an image entry should publish an image snapshot")
            return
        }
        #expect(detail.entryID == entry.id)
        #expect(detail.width == 2_880)
        #expect(detail.height == 1_800)
        #expect(detail.thumbnailPNG == ClipboardImageTestData.thumbnail)
        #expect(detail.hasFullImage)
        #expect(coordinator.isSelectionPreviewable)

        // Browsing writes nothing. The temporary file belongs to the preview
        // action, and only once the user actually takes it.
        #expect(!FileManager.default.fileExists(atPath: previewURL.path))

        #expect(coordinator.previewableSelectionURL == previewURL)
        #expect(FileManager.default.fileExists(atPath: previewURL.path))
        try? FileManager.default.removeItem(at: previewURL)
    }

    @Test func anImageWithNoStoredPayloadPublishesItsThumbnailAlone() async throws {
        let store = ClipboardHistoryStore.inMemory()
        // Only a TIFF representation was captured, so `hasFullImage` has to
        // come from the store rather than from the entry's own metadata.
        _ = try #require(store.recordImage(
            pngData: nil,
            tiffData: ClipboardImageTestData.tiff,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 64,
            height: 32,
            displayName: "Screenshot"
        ))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        guard case let .image(detail) = coordinator.clipboardInspector else {
            Issue.record("selecting an image entry should publish an image snapshot")
            return
        }
        #expect(detail.hasFullImage)
        #expect(detail.thumbnailPNG == ClipboardImageTestData.thumbnail)
    }

    @Test func previewabilityAgreesWithWhatThePreviewActionCanOpen() async throws {
        let store = ClipboardHistoryStore.inMemory()
        let shotURL = tree.root.appendingPathComponent("shot.png")
        try Data("shot-bytes".utf8).write(to: shotURL)
        _ = try #require(store.record(text: "just some copied words"))
        _ = try #require(store.record(text: "/definitely/missing/file.png"))
        _ = try #require(store.record(text: shotURL.path))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        // The Actions menu reads the published flag and Space materializes
        // the URL; the two must never disagree about the same row.
        for _ in 0..<coordinator.results.count {
            #expect(
                coordinator.isSelectionPreviewable == (coordinator.previewableSelectionURL != nil)
            )
            coordinator.moveSelection(by: 1)
        }
    }

    @Test func pinningTheSelectionRepublishesItsInspectorSnapshot() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.record(text: "Acme billing address"))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        guard case let .text(before) = coordinator.clipboardInspector else {
            Issue.record("the text entry should be inspected")
            return
        }
        #expect(before.pinnedAt == nil)

        coordinator.togglePinSelection()
        guard case let .text(after) = coordinator.clipboardInspector else {
            Issue.record("pinning should leave the entry inspected")
            return
        }
        #expect(after.pinnedAt != nil)
    }

    @Test func leavingClipboardModeClearsThePublishedSelectionFacts() async throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = try #require(store.recordFile(path: "/Users/f/Documents/Invoice.pdf"))

        let coordinator = try await makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()
        #expect(coordinator.clipboardInspector != nil)
        #expect(coordinator.isSelectionPreviewable)

        coordinator.handleEscape()
        #expect(!coordinator.isClipboardMode)
        #expect(coordinator.clipboardInspector == nil)
        #expect(!coordinator.isSelectionPreviewable)
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
