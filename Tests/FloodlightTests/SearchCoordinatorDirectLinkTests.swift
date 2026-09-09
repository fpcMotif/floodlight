import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// The session's side of Direct Link: that pasting an address and pressing
/// Return is two actions rather than four, that the row leaves as soon as the
/// query stops being an address, and that neither of the other two modes
/// grows one.
@MainActor
final class SearchCoordinatorDirectLinkTests: SearchCoordinatorIntegrationTestCase {
    @Test func typingAnAddressSelectsTheRowThatOpensIt() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "x.com/fddddfdf"
        try await settle(coordinator)

        #expect(coordinator.selectedID == "direct-link")
        let selected = coordinator.results.first { $0.id == "direct-link" }
        #expect(try selected?.action == .open(#require(URL(string: "https://x.com/fddddfdf"))))
    }

    @Test func editingAnAddressIntoOrdinaryTextTakesTheRowAway() async throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(id: "app:xcode", name: "Xcode", score: 120_000)]
        )
        let coordinator = try await makeCoordinator(applications: applications)

        coordinator.query = "abd.com"
        try await settle(coordinator)
        #expect(coordinator.selectedID == "direct-link")

        coordinator.query = "xcode"
        try await settle(coordinator)

        #expect(!coordinator.results.contains { $0.id == "direct-link" })
        #expect(coordinator.selectedID == "app:xcode")
    }

    @Test func webModePublishesItsEngineListAndNoAddressRow() async throws {
        let coordinator = try await makeCoordinator()

        coordinator.query = "abd.com"
        try await settle(coordinator)
        coordinator.handleTab()

        #expect(coordinator.activeWebEngine != nil)
        #expect(!coordinator.results.contains { $0.id == "direct-link" })
    }

    @Test func clipboardModePublishesItsBoardAndNoAddressRow() throws {
        let store = ClipboardHistoryStore.inMemory()
        _ = store.record(text: "https://abd.com/copied", sourceAppBundleID: "com.apple.Safari")
        let isolated = try IsolatedDefaults()
        let coordinator = SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: ScriptedCatalog(),
                settings: ScriptedCatalog()
            ),
            recentStore: RecentStore(defaults: isolated.defaults),
            blocklistStore: BlocklistStore(defaults: isolated.defaults),
            clipboardSearch: ClipboardSearch(store: store),
            rootURL: tree.root,
            assistantRunner: ScriptedAssistantRunner(),
            onDismiss: {}
        )

        coordinator.query = "clip"
        coordinator.handleTab()

        #expect(coordinator.isClipboardMode)
        #expect(!coordinator.results.contains { $0.id == "direct-link" })
    }
}
