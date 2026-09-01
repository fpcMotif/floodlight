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
}

private final class ScriptedActionEffects: SelectedResultActionEffects {
    let onWrite: (String) -> Bool

    init(onWrite: @escaping (String) -> Bool) {
        self.onWrite = onWrite
    }

    func writeToClipboard(_ value: String) -> Bool {
        onWrite(value)
    }

    func open(_ url: URL, asApplication: Bool) async throws {}

    func revealInFinder(_ url: URL) {}
}
