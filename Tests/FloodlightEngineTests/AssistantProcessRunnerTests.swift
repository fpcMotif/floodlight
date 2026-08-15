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

    func testIsAvailableRejectsACommandThatEscapesTheSearchDirectory() async {
        let runner = AssistantProcessRunner()

        let available = await runner.isAvailable(command: "../bin/echo")

        XCTAssertFalse(available)
    }

    func testIsAvailableRejectsEveryNonBareCommandShape() async {
        let runner = AssistantProcessRunner()
        let invalidNames = [
            "", ".", "..", "/bin/echo", "foo/bar", "../echo", "echo\ntrue", "echo true",
            "écho", "echo\u{0000}true",
        ]

        for command in invalidNames {
            let available = await runner.isAvailable(command: command)
            XCTAssertFalse(available, String(reflecting: command))
        }
    }

    func testRunCapturesStdoutFromASuccessfulProcess() async throws {
        let runner = AssistantProcessRunner()
        let output = try await runner.run(command: "echo", arguments: ["hello from the assistant"])
        XCTAssertEqual(output, "hello from the assistant")
    }

    func testRunDrainsSuccessfulOutputLargerThanAPipeBuffer() async throws {
        let runner = AssistantProcessRunner(timeout: .seconds(5), maxOutputBytes: 256 * 1_024)

        let output = try await runner.run(command: "jot", arguments: ["-b", "x", "70000"])

        XCTAssertEqual(output.utf8.count, 139_999)
    }

    func testRunRejectsOutputBeyondTheMemoryLimit() async throws {
        let runner = AssistantProcessRunner(timeout: .seconds(5), maxOutputBytes: 1_024)
        let start = ContinuousClock.now

        do {
            _ = try await runner.run(command: "jot", arguments: ["-b", "x", "10000"])
            XCTFail("expected outputLimitExceeded")
        } catch let AssistantProcessError.outputLimitExceeded(limit) {
            XCTAssertEqual(limit, 1_024)
        } catch {
            XCTFail("expected outputLimitExceeded, got \(error)")
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testRunAppliesOneLimitAcrossStdoutAndStderr() async throws {
        let runner = AssistantProcessRunner(timeout: .seconds(5), maxOutputBytes: 1_024)
        let program = """
        BEGIN {
            for (i = 0; i < 400; i++) print "stdout"
            for (i = 0; i < 400; i++) print "stderr" > "/dev/stderr"
        }
        """

        do {
            _ = try await runner.run(command: "awk", arguments: [program])
            XCTFail("expected outputLimitExceeded")
        } catch let AssistantProcessError.outputLimitExceeded(limit) {
            XCTAssertEqual(limit, 1_024)
        } catch {
            XCTFail("expected outputLimitExceeded, got \(error)")
        }
    }

    func testConcurrentRunsNeverMixTheirOutput() async throws {
        let runner = AssistantProcessRunner(timeout: .seconds(5))

        let outputs = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<32 {
                group.addTask {
                    let marker = "assistant-run-\(index)"
                    let output = try await runner.run(command: "echo", arguments: [marker])
                    return (index, output)
                }
            }

            var collected: [Int: String] = [:]
            for try await (index, output) in group {
                collected[index] = output
            }
            return collected
        }

        for index in 0..<32 {
            XCTAssertEqual(outputs[index], "assistant-run-\(index)")
        }
    }

    /// The query text is a single element of `arguments`, passed straight
    /// to the process — never through a shell — so shell metacharacters in
    /// it are inert.
    func testRunPassesArgumentsDirectlyRatherThanThroughAShell() async throws {
        let runner = AssistantProcessRunner()
        let output = try await runner.run(
            command: "echo",
            arguments: ["`echo pwned`", "&&", "rm -rf /tmp/nothing"]
        )
        XCTAssertEqual(output, "`echo pwned` && rm -rf /tmp/nothing")
    }

    func testRunThrowsExecutableNotFoundForAnUnresolvableCommand() async {
        let runner = AssistantProcessRunner()
        do {
            _ = try await runner.run(command: "floodlight-does-not-ship-this-binary", arguments: [])
            XCTFail("expected executableNotFound")
        } catch let AssistantProcessError.executableNotFound(command) {
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
        } catch let AssistantProcessError.nonZeroExit(status, _) {
            XCTAssertNotEqual(status, 0)
        } catch {
            XCTFail("expected nonZeroExit, got \(error)")
        }
    }

    func testRunThrowsTimedOutAndTerminatesAProcessThatOutlivesTheTimeout() async throws {
        let runner = AssistantProcessRunner(timeout: .milliseconds(100))
        let start = ContinuousClock.now

        do {
            _ = try await runner.run(command: "sleep", arguments: ["30"])
            XCTFail("expected timedOut")
        } catch AssistantProcessError.timedOut {
            // expected — and well under the process's own 30s sleep, so the
            // watchdog (not the process exiting on its own) caused this.
            XCTAssertLessThan(start.duration(to: .now), .seconds(5))
        } catch {
            XCTFail("expected timedOut, got \(error)")
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
