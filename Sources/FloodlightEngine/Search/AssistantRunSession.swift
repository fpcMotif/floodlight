import Observation

/// One immutable request to an installed assistant CLI, tied to the result
/// row that initiated it.
package struct AssistantRequest: Equatable, Sendable {
    package let itemID: SearchItem.ID
    package let command: String
    package let arguments: [String]

    package init(itemID: SearchItem.ID, command: String, arguments: [String]) {
        self.itemID = itemID
        self.command = command
        self.arguments = arguments
    }
}

/// What's happened since a user activated an assistant row.
package enum AssistantAnswerState: Equatable, Sendable {
    case running
    case answered(String)
    case failed(String)
}

/// One coherent publication for the current or most recently completed ask.
package struct AssistantRun: Equatable, Sendable {
    package let itemID: SearchItem.ID
    package let state: AssistantAnswerState

    package init(itemID: SearchItem.ID, state: AssistantAnswerState) {
        self.itemID = itemID
        self.state = state
    }
}

/// Owns the replaceable lifecycle of an explicitly activated assistant ask.
/// Availability discovery remains outside this module because it determines
/// which keyword rows exist rather than what happens after one is activated.
@MainActor
@Observable
package final class AssistantRunSession {
    package private(set) var run: AssistantRun?

    @ObservationIgnored
    private let runner: any AssistantProcessRunning
    @ObservationIgnored
    private var runTask: Task<Void, Never>?
    @ObservationIgnored
    private var generation = 0

    package init(runner: any AssistantProcessRunning) {
        self.runner = runner
    }

    deinit {
        runTask?.cancel()
    }

    package func start(_ request: AssistantRequest) {
        runTask?.cancel()
        generation &+= 1
        let runGeneration = generation
        run = AssistantRun(itemID: request.itemID, state: .running)

        runTask = Task { @MainActor [weak self, runner] in
            guard !Task.isCancelled else { return }
            let state: AssistantAnswerState
            do {
                let output = try await runner.run(
                    command: request.command,
                    arguments: request.arguments
                )
                state = .answered(output)
            } catch is CancellationError {
                return
            } catch let AssistantProcessError.executableNotFound(command) {
                state = .failed("\(command) isn't installed.")
            } catch AssistantProcessError.timedOut {
                state = .failed("That ask took too long and was stopped.")
            } catch let AssistantProcessError.nonZeroExit(_, message) where !message.isEmpty {
                state = .failed(message)
            } catch {
                state = .failed("That ask failed.")
            }

            guard let self,
                  !Task.isCancelled,
                  generation == runGeneration,
                  run?.itemID == request.itemID
            else { return }
            run = AssistantRun(itemID: request.itemID, state: state)
            runTask = nil
        }
    }

    package func cancel() {
        generation &+= 1
        runTask?.cancel()
        runTask = nil
        run = nil
    }

    package func state(for itemID: SearchItem.ID) -> AssistantAnswerState? {
        guard run?.itemID == itemID else { return nil }
        return run?.state
    }

    package func answeredText(for itemID: SearchItem.ID) -> String? {
        guard case let .answered(text) = state(for: itemID) else { return nil }
        return text
    }
}
