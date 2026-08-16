import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

@MainActor
struct SelectedResultActionPerformerTests {
    @Test func copyActivationDismissesOnlyAfterSuccessfulWrite() {
        let successful = makeHarness()
        let item = copyItem(value: "42")

        successful.performer.activate(item, query: "6 * 7")

        #expect(successful.effects.clipboardValues == ["42"])
        #expect(successful.presentation.events == [.dismiss])
        #expect(successful.events.events == [.clipboard("42"), .dismiss])

        let failed = makeHarness(clipboardSucceeds: false)
        failed.performer.activate(item, query: "6 * 7")

        #expect(failed.effects.clipboardValues == ["42"])
        #expect(failed.presentation.events.isEmpty)
        #expect(failed.events.events == [.clipboard("42")])
    }

    @Test func explicitCopyUsesTheResultRepresentationAndKeepsSearchOpen() throws {
        let harness = makeHarness()
        let fileURL = URL(fileURLWithPath: "/tmp/Annual Report.pdf")
        let file = SearchItem(
            id: "file:report",
            title: "Annual Report.pdf",
            subtitle: "/tmp",
            kind: .file,
            action: .open(fileURL),
            score: 1,
            fileURL: fileURL
        )
        let webURL = try #require(URL(string: "https://example.com/report"))
        let web = SearchItem(
            id: "web:report",
            title: "Report",
            subtitle: webURL.absoluteString,
            kind: .web,
            action: .open(webURL),
            score: 1
        )

        harness.performer.copy(file)
        harness.performer.copy(web)

        #expect(harness.effects.clipboardValues == [fileURL.path, webURL.absoluteString])
        #expect(harness.presentation.events.isEmpty)
    }

    @Test func explicitCopyUsesAssistantTitleBeforeAnAnswerExists() {
        let harness = makeHarness()
        let item = assistantItem()

        harness.performer.copy(item)

        #expect(harness.effects.clipboardValues == [item.title])
        #expect(harness.presentation.events.isEmpty)
    }

    @Test func explicitCopyUsesAssistantTitleAfterTheRunFails() async throws {
        let runner = ScriptedAssistantRunner(mode: .immediate(.failure(TestFailure.openFailed)))
        let harness = makeHarness(assistantRunner: runner)
        let item = assistantItem()

        harness.performer.activate(item, query: "claude explain")
        try await waitUntil {
            guard case .failed = harness.assistantRunSession.state(for: item.id) else {
                return false
            }
            return true
        }
        harness.performer.copy(item)

        #expect(harness.effects.clipboardValues == [item.title])
        #expect(harness.presentation.events.isEmpty)
    }

    @Test func explicitCopyUsesACompletedAssistantAnswer() async throws {
        let runner = ScriptedAssistantRunner(mode: .immediate(.success("The answer.")))
        let harness = makeHarness(assistantRunner: runner)
        let item = assistantItem()

        harness.performer.activate(item, query: "claude explain")
        try await waitUntil {
            harness.assistantRunSession.state(for: item.id) == .answered("The answer.")
        }
        harness.performer.copy(item)

        #expect(harness.effects.clipboardValues == ["The answer."])
        #expect(harness.presentation.events.isEmpty)
    }

    @Test func runningApplicationSuccessRecordsRecencyAndLearningWithoutOpening() async throws {
        let harness = makeHarness(activatesRunningApplication: true)
        let item = SearchFixtures.application(name: "Calendar")
        let url = try #require(item.fileURL)

        harness.performer.activate(item, query: "cal")

        try await waitUntil {
            await harness.learning.count == 1
                && harness.recentStore.boost(for: item.id) > 0
        }
        #expect(harness.activator.requestedURLs == [url])
        #expect(harness.effects.openRequests.isEmpty)
        #expect(harness.presentation.events == [.dismiss])
        let learned = await harness.learning.snapshot()
        #expect(learned == [.init(itemID: item.id, url: url, query: "cal")])
    }

    @Test func successfulFileOpenLearnsWithoutApplicationRecency() async throws {
        let harness = makeHarness()
        let item = SearchFixtures.file(name: "report.pdf")
        let url = try #require(item.fileURL)

        harness.performer.activate(item, query: "rep")

        try await waitUntil { await harness.learning.count == 1 }
        #expect(harness.effects.openRequests == [.init(url: url, asApplication: false)])
        #expect(harness.recentStore.boost(for: item.id) == 0)
        #expect(harness.presentation.events == [.dismiss])
        let learned = await harness.learning.snapshot()
        #expect(learned == [.init(itemID: item.id, url: url, query: "rep")])
    }

    @Test func successfulApplicationFallbackRecordsRecencyAndLearningAfterOpen() async throws {
        let openGate = OpenGate()
        let harness = makeHarness(openGate: openGate)
        let item = SearchFixtures.application(name: "Calendar")
        let url = try #require(item.fileURL)

        harness.performer.activate(item, query: "cal")

        #expect(harness.presentation.events == [.dismiss])
        try await waitUntil { harness.effects.openRequests.count == 1 }
        #expect(harness.recentStore.boost(for: item.id) == 0)
        let learningBeforeCompletion = await harness.learning.snapshot()
        #expect(learningBeforeCompletion.isEmpty)
        #expect(harness.events.events == [
            .runningApplicationActivationRequested(url),
            .dismiss,
            .openRequested(url, asApplication: true),
        ])

        await openGate.resume()
        try await waitUntil {
            await harness.learning.count == 1
                && harness.recentStore.boost(for: item.id) > 0
        }
        #expect(harness.effects.openRequests == [.init(url: url, asApplication: true)])
        #expect(harness.events.events == [
            .runningApplicationActivationRequested(url),
            .dismiss,
            .openRequested(url, asApplication: true),
            .openSucceeded(url),
            .learned(item.id, url, "cal"),
        ])
        let learned = await harness.learning.snapshot()
        #expect(learned == [.init(itemID: item.id, url: url, query: "cal")])
    }

    @Test func failedApplicationOpenDoesNotRecordOrLearn() async throws {
        let openGate = OpenGate()
        let harness = makeHarness(openError: TestFailure.openFailed, openGate: openGate)
        let item = SearchFixtures.application(name: "Calendar")
        let url = try #require(item.fileURL)

        harness.performer.activate(item, query: "cal")

        try await waitUntil { harness.effects.openRequests.count == 1 }
        #expect(harness.recentStore.boost(for: item.id) == 0)
        let learningBeforeCompletion = await harness.learning.snapshot()
        #expect(learningBeforeCompletion.isEmpty)
        #expect(harness.events.events == [
            .runningApplicationActivationRequested(url),
            .dismiss,
            .openRequested(url, asApplication: true),
        ])

        await openGate.resume()
        try await waitUntil { harness.effects.completedOpenCount == 1 }
        await Task.yield()
        #expect(harness.recentStore.boost(for: item.id) == 0)
        let learned = await harness.learning.snapshot()
        #expect(learned.isEmpty)
        #expect(harness.presentation.events == [.dismiss])
        #expect(harness.events.events == [
            .runningApplicationActivationRequested(url),
            .dismiss,
            .openRequested(url, asApplication: true),
            .openFailed(url),
        ])
    }

    @Test func assistantRunKeepsSearchOpen() {
        let harness = makeHarness()
        let item = assistantItem()

        harness.performer.activate(item, query: "claude explain")

        #expect(harness.assistantRunSession.state(for: item.id) == .running)
        #expect(harness.presentation.events.isEmpty)
    }

    @Test func revealRequiresAFileURLAndDismissesOnlyWhenDispatched() throws {
        let harness = makeHarness()
        let file = SearchFixtures.file(name: "report.pdf")
        let web = try SearchItem(
            id: "web",
            title: "Web",
            subtitle: "",
            kind: .web,
            action: .open(#require(URL(string: "https://example.com"))),
            score: 1
        )

        let app = SearchFixtures.application(name: "Ghostty")

        harness.performer.reveal(web)
        harness.performer.reveal(file)
        harness.performer.reveal(app)

        #expect(harness.effects.revealedURLs == [file.fileURL, app.fileURL])
        #expect(harness.presentation.events == [.dismiss, .dismiss])
        let fileURL = try #require(file.fileURL)
        let appURL = try #require(app.fileURL)
        #expect(harness.events.events == [
            .revealed(fileURL),
            .dismiss,
            .revealed(appURL),
            .dismiss,
        ])
    }

    @Test func independentOpensKeepTheirOwnItemAndQuery() async throws {
        let harness = makeHarness()
        let first = SearchFixtures.file(name: "first.txt")
        let second = SearchFixtures.file(name: "second.txt")

        harness.performer.activate(first, query: "first query")
        harness.performer.activate(second, query: "second query")

        try await waitUntil { await harness.learning.count == 2 }
        let learned = await harness.learning.snapshot()
        let firstURL = try #require(first.fileURL)
        let secondURL = try #require(second.fileURL)
        #expect(Set(learned) == Set([
            .init(itemID: first.id, url: firstURL, query: "first query"),
            .init(itemID: second.id, url: secondURL, query: "second query"),
        ]))
    }

    private func makeHarness(
        clipboardSucceeds: Bool = true,
        openError: (any Error)? = nil,
        openGate: OpenGate? = nil,
        activatesRunningApplication: Bool = false,
        assistantRunner: any AssistantProcessRunning = ScriptedAssistantRunner()
    ) -> Harness {
        Harness(
            clipboardSucceeds: clipboardSucceeds,
            openError: openError,
            openGate: openGate,
            activatesRunningApplication: activatesRunningApplication,
            assistantRunner: assistantRunner
        )
    }

    private func copyItem(value: String) -> SearchItem {
        SearchItem(
            id: "calculator",
            title: value,
            subtitle: "Copy",
            kind: .calculator,
            action: .copy(value),
            score: 1
        )
    }

    private func assistantItem() -> SearchItem {
        SearchItem(
            id: "keyword-engine:claude",
            title: "Ask Claude",
            subtitle: "",
            kind: .assistant,
            action: .askAssistant(command: "claude", arguments: ["explain"]),
            score: 1
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was never satisfied within \(timeout)s")
    }
}

@MainActor
private final class Harness {
    let events = EventRecorder()
    let effects: ScriptedSelectedResultActionEffects
    let assistantRunSession: AssistantRunSession
    let activator: ScriptedRunningApplicationActivator
    let recentStore: RecentStore
    let learning = LearningRecorder()
    let presentation = PresentationRecorder()
    let performer: SelectedResultActionPerformer

    init(
        clipboardSucceeds: Bool,
        openError: (any Error)?,
        openGate: OpenGate?,
        activatesRunningApplication: Bool,
        assistantRunner: any AssistantProcessRunning
    ) {
        effects = ScriptedSelectedResultActionEffects(
            clipboardSucceeds: clipboardSucceeds,
            openError: openError,
            openGate: openGate,
            events: events
        )
        assistantRunSession = AssistantRunSession(runner: assistantRunner)
        activator = ScriptedRunningApplicationActivator(
            activatesEverything: activatesRunningApplication,
            events: events
        )
        let suiteName = "SelectedResultActionPerformerTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("could not create isolated defaults")
        }
        recentStore = RecentStore(defaults: defaults)
        let learning = learning
        let presentation = presentation
        let events = events
        performer = SelectedResultActionPerformer(
            effects: effects,
            assistantRunSession: assistantRunSession,
            runningApplicationActivator: activator,
            recentStore: recentStore,
            trackSelection: { itemID, url, query in
                await learning.record(itemID: itemID, url: url, query: query)
                await events.record(.learned(itemID, url, query))
            },
            onDismiss: {
                presentation.events.append(.dismiss)
                events.record(.dismiss)
            }
        )
    }
}

@MainActor
private final class ScriptedSelectedResultActionEffects: SelectedResultActionEffects {
    struct OpenRequest: Equatable {
        let url: URL
        let asApplication: Bool
    }

    private let clipboardSucceeds: Bool
    private let openError: (any Error)?
    private let openGate: OpenGate?
    private let events: EventRecorder
    private(set) var clipboardValues: [String] = []
    private(set) var openRequests: [OpenRequest] = []
    private(set) var completedOpenCount = 0
    private(set) var revealedURLs: [URL] = []

    init(
        clipboardSucceeds: Bool,
        openError: (any Error)?,
        openGate: OpenGate?,
        events: EventRecorder
    ) {
        self.clipboardSucceeds = clipboardSucceeds
        self.openError = openError
        self.openGate = openGate
        self.events = events
    }

    func writeToClipboard(_ value: String) -> Bool {
        clipboardValues.append(value)
        events.record(.clipboard(value))
        return clipboardSucceeds
    }

    func open(_ url: URL, asApplication: Bool) async throws {
        openRequests.append(.init(url: url, asApplication: asApplication))
        events.record(.openRequested(url, asApplication: asApplication))
        if let openGate {
            await openGate.wait()
        }
        defer { completedOpenCount += 1 }
        if let openError {
            events.record(.openFailed(url))
            throw openError
        }
        events.record(.openSucceeded(url))
    }

    func revealInFinder(_ url: URL) {
        revealedURLs.append(url)
        events.record(.revealed(url))
    }
}

private final class ScriptedRunningApplicationActivator: RunningApplicationActivating {
    private let activatesEverything: Bool
    private let events: EventRecorder
    private(set) var requestedURLs: [URL] = []

    init(activatesEverything: Bool, events: EventRecorder) {
        self.activatesEverything = activatesEverything
        self.events = events
    }

    func activateIfRunning(bundleURL: URL) -> Bool {
        requestedURLs.append(bundleURL)
        events.record(.runningApplicationActivationRequested(bundleURL))
        return activatesEverything
    }
}

private actor LearningRecorder {
    struct Entry: Hashable {
        let itemID: SearchItem.ID
        let url: URL
        let query: String
    }

    private(set) var entries: [Entry] = []

    var count: Int {
        entries.count
    }

    func record(itemID: SearchItem.ID, url: URL, query: String) {
        entries.append(.init(itemID: itemID, url: url, query: query))
    }

    func snapshot() -> [Entry] {
        entries
    }
}

@MainActor
private final class PresentationRecorder {
    enum Event: Equatable {
        case dismiss
        case showSettings
    }

    var events: [Event] = []
}

@MainActor
private final class EventRecorder {
    private(set) var events: [ActionEvent] = []

    func record(_ event: ActionEvent) {
        events.append(event)
    }
}

private enum ActionEvent: Equatable {
    case clipboard(String)
    case runningApplicationActivationRequested(URL)
    case openRequested(URL, asApplication: Bool)
    case openSucceeded(URL)
    case openFailed(URL)
    case revealed(URL)
    case dismiss
    case showSettings
    case learned(SearchItem.ID, URL, String)
}

private actor OpenGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private enum TestFailure: Error {
    case openFailed
}
