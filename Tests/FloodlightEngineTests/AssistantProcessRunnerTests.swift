import XCTest
@testable import FloodlightEngine

final class AssistantProcessRunnerTests: XCTestCase {
    func testIsAvailableIsTrueForACommandOnTheSystem() async {
        let runner = AssistantProcessRunner()
        let available = await runner.isAvailable(command: "echo")
        XCTAssertTrue(available)
    }

    func testIsAvailableIsFalseForANonsenseCommand() async {
        let runner = AssistantProcessRunner()
        let available = await runner.isAvailable(command: "floodlight-does-not-ship-this-binary")
        XCTAssertFalse(available)
    }

    func testRunCapturesStdoutFromASuccessfulProcess() async throws {
        let runner = AssistantProcessRunner()
        let output = try await runner.run(command: "echo", arguments: ["hello from the assistant"])
        XCTAssertEqual(output, "hello from the assistant")
    }

    /// The query text is a single element of `arguments`, passed straight
    /// to the process — never through a shell — so shell metacharacters in
    /// it are inert.
    func testRunPassesArgumentsDirectlyRatherThanThroughAShell() async throws {
        let runner = AssistantProcessRunner()
        let output = try await runner.run(command: "echo", arguments: ["`echo pwned`", "&&", "rm -rf /tmp/nothing"])
        XCTAssertEqual(output, "`echo pwned` && rm -rf /tmp/nothing")
    }

    func testRunThrowsExecutableNotFoundForAnUnresolvableCommand() async {
        let runner = AssistantProcessRunner()
        do {
            _ = try await runner.run(command: "floodlight-does-not-ship-this-binary", arguments: [])
            XCTFail("expected executableNotFound")
        } catch AssistantProcessError.executableNotFound(let command) {
            XCTAssertEqual(command, "floodlight-does-not-ship-this-binary")
        } catch {
            XCTFail("expected executableNotFound, got \(error)")
        }
    }

    func testRunThrowsNonZeroExitWithStderrWhenTheProcessFails() async {
        let runner = AssistantProcessRunner()
        do {
            _ = try await runner.run(command: "false", arguments: [])
            XCTFail("expected nonZeroExit")
        } catch AssistantProcessError.nonZeroExit(let status, _) {
            XCTAssertNotEqual(status, 0)
        } catch {
            XCTFail("expected nonZeroExit, got \(error)")
        }
    }

    func testRunCancellationTerminatesTheUnderlyingProcess() async throws {
        let runner = AssistantProcessRunner()
        let task = Task {
            try await runner.run(command: "sleep", arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation to surface as an error")
        } catch {
            // A terminated `sleep` reports a non-zero exit; either that or
            // CancellationError is an acceptable outcome of cancelling.
        }
    }
}
