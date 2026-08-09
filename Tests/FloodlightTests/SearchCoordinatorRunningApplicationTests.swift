import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest
@testable import Floodlight

/// Covers the fast path added by ADR 0004: activating an already-running
/// application must go through `RunningApplicationActivating` instead of
/// `NSWorkspace.openApplication`, and only application rows may ever
/// consult it.
@MainActor
final class SearchCoordinatorRunningApplicationTests: XCTestCase {
    private nonisolated(unsafe) var tree: TemporaryTree!

    override func setUpWithError() throws {
        tree = try TemporaryTree(label: "CoordinatorRunningApplication")
    }

    override func tearDown() {
        tree = nil
    }

    private func makeCoordinator(
        runningApplicationActivator: any RunningApplicationActivating,
        onDismiss: @escaping @MainActor () -> Void = {}
    ) throws -> SearchCoordinator {
        try SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: ScriptedCatalog(),
                settings: ScriptedCatalog()
            ),
            recentStore: RecentStore(defaults: IsolatedDefaults().defaults),
            rootURL: tree.root,
            assistantRunner: ScriptedAssistantRunner(),
            runningApplicationActivator: runningApplicationActivator,
            actionEffects: ScriptedSelectedResultActionEffects(),
            onDismiss: onDismiss,
            onShowSettings: {}
        )
    }

    func testActivatingAnAlreadyRunningApplicationUsesTheFastPathAndDismisses() throws {
        let activator = ScriptedRunningApplicationActivator(activatesEverything: true)
        var dismissed = false
        let coordinator = try makeCoordinator(
            runningApplicationActivator: activator,
            onDismiss: { dismissed = true }
        )
        let item = SearchFixtures.application(name: "TestApp")

        coordinator.activate(item)

        XCTAssertEqual(activator.requestedBundleURLs, [item.fileURL])
        XCTAssertTrue(dismissed)
    }

    func testActivatingAFileOrFolderNeverConsultsTheActivator() throws {
        let activator = ScriptedRunningApplicationActivator(activatesEverything: true)
        var dismissedCount = 0
        let coordinator = try makeCoordinator(
            runningApplicationActivator: activator,
            onDismiss: { dismissedCount += 1 }
        )

        coordinator.activate(SearchFixtures.folder(name: "Documents"))

        XCTAssertTrue(
            activator.requestedBundleURLs.isEmpty,
            "only application rows should ever ask whether they're already running"
        )
        XCTAssertEqual(dismissedCount, 1)
    }
}

/// Records every bundle URL it's asked about and reports back a
/// caller-chosen outcome — never touches AppKit, so tests can exercise the
/// fast path without a real application actually being open.
private final class ScriptedRunningApplicationActivator: RunningApplicationActivating {
    private(set) var requestedBundleURLs: [URL] = []
    private let activatesEverything: Bool

    init(activatesEverything: Bool) {
        self.activatesEverything = activatesEverything
    }

    func activateIfRunning(bundleURL: URL) -> Bool {
        requestedBundleURLs.append(bundleURL)
        return activatesEverything
    }
}

@MainActor
private struct ScriptedSelectedResultActionEffects: SelectedResultActionEffects {
    func writeToClipboard(_ value: String) -> Bool {
        true
    }

    func open(_ url: URL, asApplication: Bool) async throws {}

    func revealInFinder(_ url: URL) {}
}
