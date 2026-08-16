import FloodlightTestSupport
import Foundation
import Testing
@testable import FloodlightEngine

@MainActor
struct AssistantRunSessionTests {
    @Test func startPublishesRunningThenTheAnswer() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let session = AssistantRunSession(runner: runner)
        let request = makeRequest()

        session.start(request)
        #expect(session.run == AssistantRun(itemID: request.itemID, state: .running))

        try await runner.resolveNext(with: .success("Because it sums the list."))
        try await waitUntil("answer publication") {
            session.run == AssistantRun(
                itemID: request.itemID,
                state: .answered("Because it sums the list.")
            )
        }
    }

    @Test func startingAnotherRequestCancelsAndReplacesTheFirst() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let session = AssistantRunSession(runner: runner)
        let first = makeRequest(itemID: "assistant:first", arguments: ["first"])
        let second = makeRequest(itemID: "assistant:second", arguments: ["second"])

        session.start(first)
        try await runner.waitForPendingRun()
        session.start(second)
        try await waitUntil("superseded process cancellation") {
            await runner.cancellations >= 1
        }
        try await runner.resolveNext(with: .success("new answer"))

        try await waitUntil("replacement answer publication") {
            session.run == AssistantRun(
                itemID: second.itemID,
                state: .answered("new answer")
            )
        }
        let replacementCancellations = await runner.cancellations
        #expect(replacementCancellations >= 1)
    }

    @Test func startingTheSameRequestStillRejectsTheSupersededCompletion() async throws {
        let runner = NonCooperativeAssistantRunner()
        let session = AssistantRunSession(runner: runner)
        let request = makeRequest()

        session.start(request)
        try await waitUntil("first request starts") {
            await runner.pendingCount == 1
        }
        session.start(request)
        try await waitUntil("replacement request starts") {
            await runner.pendingCount == 2
        }

        await runner.resolve(call: 0, with: "stale answer")
        await Task.yield()
        #expect(session.run == AssistantRun(itemID: request.itemID, state: .running))

        await runner.resolve(call: 1, with: "surviving answer")

        try await waitUntil("same-request replacement answer") {
            session.run == AssistantRun(
                itemID: request.itemID,
                state: .answered("surviving answer")
            )
        }
    }

    @Test func immediateCancelPreventsTheRunnerFromStarting() async {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let session = AssistantRunSession(runner: runner)

        session.start(makeRequest())
        session.cancel()
        await Task.yield()

        let recordedRuns = await runner.runs
        #expect(recordedRuns.isEmpty)
        #expect(session.run == nil)
    }

    @Test func cancelSynchronouslyClearsTheRunAndCancelsTheProcess() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let session = AssistantRunSession(runner: runner)

        session.start(makeRequest())
        try await runner.waitForPendingRun()
        session.cancel()

        #expect(session.run == nil)
        try await waitUntil("process cancellation") {
            await runner.cancellations == 1
        }
    }

    @Test func failuresBecomeStableDisplayStates() async throws {
        let cases: [(any Error, String)] = [
            (AssistantProcessError.executableNotFound("claude"), "claude isn't installed."),
            (AssistantProcessError.timedOut, "That ask took too long and was stopped."),
            (
                AssistantProcessError.nonZeroExit(status: 2, message: "runner failed"),
                "runner failed"
            ),
            (AssistantProcessError.nonZeroExit(status: 2, message: ""), "That ask failed."),
            (TestError.scripted("unknown"), "That ask failed."),
        ]

        for (index, testCase) in cases.enumerated() {
            let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
            let session = AssistantRunSession(runner: runner)
            let request = makeRequest(itemID: "assistant:\(index)")

            session.start(request)
            try await runner.resolveNext(with: .failure(testCase.0))
            try await waitUntil("failure publication \(index)") {
                session.run == AssistantRun(
                    itemID: request.itemID,
                    state: .failed(testCase.1)
                )
            }
        }
    }

    @Test func stateAndAnswerTextAreScopedToTheOriginatingRow() async throws {
        let runner = ScriptedAssistantRunner(availableCommands: ["claude"])
        let session = AssistantRunSession(runner: runner)
        let request = makeRequest()

        session.start(request)
        try await runner.resolveNext(with: .success("answer"))
        try await waitUntil("answer publication") {
            session.run?.state == .answered("answer")
        }

        #expect(session.state(for: request.itemID) == .answered("answer"))
        #expect(session.answeredText(for: request.itemID) == "answer")
        #expect(session.state(for: "assistant:other") == nil)
        #expect(session.answeredText(for: "assistant:other") == nil)
    }

    private func makeRequest(
        itemID: SearchItem.ID = "assistant:claude",
        arguments: [String] = ["explain this"]
    ) -> AssistantRequest {
        AssistantRequest(itemID: itemID, command: "claude", arguments: arguments)
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        _ condition: () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("never became true: \(description)")
    }
}

private actor NonCooperativeAssistantRunner: AssistantProcessRunning {
    private var continuations: [Int: CheckedContinuation<String, Never>] = [:]
    private var nextCall = 0

    var pendingCount: Int {
        continuations.count
    }

    func isAvailable(command: String) async -> Bool {
        true
    }

    func run(command: String, arguments: [String]) async throws -> String {
        let call = nextCall
        nextCall += 1
        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func resolve(call: Int, with output: String) {
        continuations.removeValue(forKey: call)?.resume(returning: output)
    }
}
