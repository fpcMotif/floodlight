import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// Covers the fast path added by ADR 0004: activating an already-running
/// application must go through `RunningApplicationActivating` instead of
/// `NSWorkspace.openApplication`, and only application rows may ever
/// consult it.
@MainActor
struct SearchCoordinatorRunningApplicationTests {
    private let tree: TemporaryTree

    init() throws {
        tree = try TemporaryTree(label: "CoordinatorRunningApplication")
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
            onDismiss: onDismiss
        )
    }

    @Test func activatingAnAlreadyRunningApplicationUsesTheFastPathAndDismisses() throws {
        let activator = ScriptedRunningApplicationActivator(activatesEverything: true)
        var dismissed = false
        let coordinator = try makeCoordinator(
            runningApplicationActivator: activator,
            onDismiss: { dismissed = true }
        )
        let item = SearchFixtures.application(name: "TestApp")

        coordinator.activate(item)

        #expect(activator.requestedBundleURLs == [item.fileURL])
        #expect(dismissed)
    }

    @Test func activatingAFileOrFolderNeverConsultsTheActivator() throws {
        let activator = ScriptedRunningApplicationActivator(activatesEverything: true)
        var dismissedCount = 0
        let coordinator = try makeCoordinator(
            runningApplicationActivator: activator,
            onDismiss: { dismissedCount += 1 }
        )

        coordinator.activate(SearchFixtures.folder(name: "Documents"))

        #expect(
            activator.requestedBundleURLs.isEmpty,
            "only application rows should ever ask whether they're already running"
        )
        #expect(dismissedCount == 1)
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
