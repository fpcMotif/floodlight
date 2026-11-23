import AppKit
import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Floodlight

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ConfigurationScopeTests {
    @Test func pendingScopeKeepsCommittedDisplayAndPreferencesThenInvalidatesOnCommit(
    ) async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanUp() }
        let view = try fixture.rootView()
        let changes = AsyncStream<Void>.makeStream()
        var changesIterator = changes.stream.makeAsyncIterator()
        // Track the same read that renders the scope subtitle, not model.rootURL directly.
        withObservationTracking {
            #expect(view.session.rootURL == fixture.original)
        } onChange: {
            changes.continuation.yield(())
        }

        fixture.selection = fixture.first
        view.onChooseScope()
        var pending = fixture.files.pending.makeAsyncIterator()
        #expect(await pending.next() == fixture.first)
        fixture.expectScope(fixture.original, in: view)

        await fixture.files.release(fixture.first)
        _ = await changesIterator.next()
        // Observation fires in willSet; returning to this main-actor test lets the
        // synchronous root and preference writes finish before inspecting either.
        fixture.expectScope(fixture.first, in: view)
        #expect(fixture.pickerCalls == 1)
    }

    @Test func failedScopeKeepsCommittedDisplayAndPreferences() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanUp() }
        let view = try fixture.rootView()
        fixture.selection = fixture.first
        view.onChooseScope()
        var pending = fixture.files.pending.makeAsyncIterator()
        #expect(await pending.next() == fixture.first)
        fixture.expectScope(fixture.original, in: view)

        await fixture.files.release(fixture.first, error: ScopeFailure.rejected)
        await fixture.scopeChanges[0].value
        fixture.expectScope(fixture.original, in: view)
    }

    @Test func cancellingPickerDoesNotRequestAScopeChange() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanUp() }
        let view = try fixture.rootView()
        fixture.selection = nil
        view.onChooseScope()

        #expect(fixture.pickerCalls == 1)
        #expect(fixture.requestedScopes.isEmpty)
        #expect(await fixture.files.requests.isEmpty)
        fixture.expectScope(fixture.original, in: view)
    }

    @Test func overlappingSuccessThenFailureDisplaysLastCommittedScope() async throws {
        let fixture = try ScopeFixture()
        defer { fixture.cleanUp() }
        let view = try fixture.rootView()
        let changes = AsyncStream<Void>.makeStream()
        var changesIterator = changes.stream.makeAsyncIterator()
        withObservationTracking {
            _ = view.session.rootURL
        } onChange: {
            changes.continuation.yield(())
        }
        var pending = fixture.files.pending.makeAsyncIterator()
        fixture.selection = fixture.first
        view.onChooseScope()
        #expect(await pending.next() == fixture.first)
        fixture.selection = fixture.second
        view.onChooseScope()
        fixture.expectScope(fixture.original, in: view)
        #expect(fixture.requestedScopes == [fixture.first, fixture.second])

        await fixture.files.release(fixture.first)
        _ = await changesIterator.next()
        #expect(await pending.next() == fixture.second)
        fixture.expectScope(fixture.first, in: view)

        await fixture.files.release(fixture.second, error: ScopeFailure.rejected)
        await fixture.scopeChanges[1].value
        fixture.expectScope(fixture.first, in: view)
    }
}

@MainActor
private final class ScopeFixture {
    let suiteName = "ConfigurationScopeTests-\(UUID().uuidString)"
    let defaults: UserDefaults
    let original = URL(fileURLWithPath: "/scope/original", isDirectory: true)
    let first = URL(fileURLWithPath: "/scope/first", isDirectory: true)
    let second = URL(fileURLWithPath: "/scope/second", isDirectory: true)
    let files = GatedScopeFileSource()
    let model: SearchCoordinator
    var controller: FloodlightConfigurationWindowController!
    var selection: URL?
    var pickerCalls = 0
    var requestedScopes: [URL] = []
    var scopeChanges: [Task<Void, Never>] = []

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.set(original.path, forKey: "index-root")
        let blocklist = BlocklistStore(defaults: defaults)
        model = SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: files,
                applications: ScriptedCatalog(),
                settings: ScriptedCatalog()
            ),
            recentStore: RecentStore(defaults: defaults),
            blocklistStore: blocklist,
            rootURL: original,
            defaults: defaults,
            onDismiss: {}
        )
        _ = NSApplication.shared
        controller = FloodlightConfigurationWindowController(
            presentation: .settings,
            activeShortcut: .optionSpace,
            activeClipboardShortcut: .shiftCommandSpace,
            launchesAtLogin: false,
            rootURL: { [model] in model.rootURL },
            blocklistStore: blocklist,
            clipboardExclusionStore: ClipboardExclusionStore(defaults: defaults),
            clipboardStore: ClipboardHistoryStore.inMemory(),
            selectShortcut: { _, shortcut in .requestedShortcutActive(shortcut) },
            setLaunchAtLogin: { _ in nil },
            chooseScope: { [weak self] in
                guard let self else { return }
                pickerCalls += 1
                guard let selection else { return }
                requestedScopes.append(selection)
                scopeChanges.append(model.changeRoot(to: selection))
            },
            onFinished: {},
            onDismissed: {}
        )
    }

    func rootView() throws -> OnboardingView {
        let hosting = try #require(
            controller.window?.contentViewController as? NSHostingController<OnboardingView>
        )
        return hosting.rootView
    }

    func expectScope(
        _ expected: URL,
        in view: OnboardingView,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(model.rootURL == expected, sourceLocation: sourceLocation)
        #expect(view.session.rootURL == expected, sourceLocation: sourceLocation)
        #expect(
            defaults.string(forKey: "index-root") == expected.path,
            sourceLocation: sourceLocation
        )
    }

    func cleanUp() {
        controller.close()
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private actor GatedScopeFileSource: FileSource {
    nonisolated let pending: AsyncStream<URL>
    private let pendingContinuation: AsyncStream<URL>.Continuation
    private var gates: [URL: CheckedContinuation<Void, any Error>] = [:]
    private(set) var requests: [URL] = []

    init() {
        let pair = AsyncStream<URL>.makeStream()
        pending = pair.stream
        pendingContinuation = pair.continuation
    }

    func start() async throws {}
    func indexedItems(for query: String, limit: Int) async throws -> [SearchItem] {
        []
    }

    func contentItems(for query: String) async throws -> [SearchItem] {
        []
    }

    func rebuild() async throws {}
    nonisolated func track(query: String, selectedURL: URL) {}

    func changeScope(to url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            gates[url] = continuation
            requests.append(url)
            pendingContinuation.yield(url)
        }
    }

    func release(_ url: URL, error: (any Error)? = nil) {
        guard let continuation = gates.removeValue(forKey: url) else {
            Issue.record("No pending scope request to release")
            return
        }
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

private enum ScopeFailure: Error {
    case rejected
}
