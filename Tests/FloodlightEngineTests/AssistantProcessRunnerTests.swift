import Testing
@testable import FloodlightEngine

struct AssistantProcessRunnerTests {
    @Test func isAvailableIsTrueForACommandOnTheSystem() async {
        let runner = AssistantProcessRunner()
        let available = await runner.isAvailable(command: "echo")
        #expect(available)
    }

    @Test func isAvailableIsFalseForANonsenseCommand() async {
        let runner = AssistantProcessRunner()
        let available = await runner.isAvailable(command: "floodlight-does-not-ship-this-binary")
        #expect(!available)
    }

    @Test func isAvailableRejectsACommandThatEscapesTheSearchDirectory() async {
        let runner = AssistantProcessRunner()

        let available = await runner.isAvailable(command: "../bin/echo")

        #expect(!available)
    }

    @Test(arguments: [
        "", ".", "..", "/bin/echo", "foo/bar", "../echo", "echo\ntrue", "echo true",
        "écho", "echo\u{0000}true",
    ])
    func isAvailableRejectsEveryNonBareCommandShape(command: String) async {
        let runner = AssistantProcessRunner()
        let available = await runner.isAvailable(command: command)
        #expect(!available, "\(String(reflecting: command))")
    }

    @Test func runCapturesStdoutFromASuccessfulProcess() async throws {
        let runner = AssistantProcessRunner()
        let output = try await runner.run(command: "echo", arguments: ["hello from the assistant"])
        #expect(output == "hello from the assistant")
    }

    @Test func runDrainsSuccessfulOutputLargerThanAPipeBuffer() async throws {
        let runner = AssistantProcessRunner(timeout: .seconds(5), maxOutputBytes: 256 * 1_024)

        let output = try await runner.run(command: "jot", arguments: ["-b", "x", "70000"])

        #expect(output.utf8.count == 139_999)
    }

    @Test func runRejectsOutputBeyondTheMemoryLimit() async throws {
        let runner = AssistantProcessRunner(timeout: .seconds(5), maxOutputBytes: 1_024)
        let start = ContinuousClock.now

        do {
            _ = try await runner.run(command: "jot", arguments: ["-b", "x", "10000"])
            Issue.record("expected outputLimitExceeded")
        } catch let AssistantProcessError.outputLimitExceeded(limit) {
            #expect(limit == 1_024)
        } catch {
            Issue.record("expected outputLimitExceeded, got \(error)")
        }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test func runAppliesOneLimitAcrossStdoutAndStderr() async throws {
        let runner = AssistantProcessRunner(timeout: .seconds(5), maxOutputBytes: 1_024)
        let program = """
        BEGIN {
            for (i = 0; i < 400; i++) print "stdout"
            for (i = 0; i < 400; i++) print "stderr" > "/dev/stderr"
        }
        """

        do {
            _ = try await runner.run(command: "awk", arguments: [program])
            Issue.record("expected outputLimitExceeded")
        } catch let AssistantProcessError.outputLimitExceeded(limit) {
            #expect(limit == 1_024)
        } catch {
            Issue.record("expected outputLimitExceeded, got \(error)")
        }
    }

    @Test func concurrentRunsNeverMixTheirOutput() async throws {
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
            #expect(outputs[index] == "assistant-run-\(index)")
        }
    }

    /// The query text is a single element of `arguments`, passed straight
    /// to the process — never through a shell — so shell metacharacters in
    /// it are inert.
    @Test func runPassesArgumentsDirectlyRatherThanThroughAShell() async throws {
        let runner = AssistantProcessRunner()
        let output = try await runner.run(
            command: "echo",
            arguments: ["`echo pwned`", "&&", "rm -rf /tmp/nothing"]
        )
        #expect(output == "`echo pwned` && rm -rf /tmp/nothing")
    }

    @Test func runThrowsExecutableNotFoundForAnUnresolvableCommand() async {
        let runner = AssistantProcessRunner()
        do {
            _ = try await runner.run(command: "floodlight-does-not-ship-this-binary", arguments: [])
            Issue.record("expected executableNotFound")
        } catch let AssistantProcessError.executableNotFound(command) {
            #expect(command == "floodlight-does-not-ship-this-binary")
        } catch {
            Issue.record("expected executableNotFound, got \(error)")
        }
    }

    @Test func runThrowsNonZeroExitWithStderrWhenTheProcessFails() async {
        let runner = AssistantProcessRunner()
        do {
            _ = try await runner.run(command: "false", arguments: [])
            Issue.record("expected nonZeroExit")
        } catch let AssistantProcessError.nonZeroExit(status, _) {
            #expect(status != 0)
        } catch {
            Issue.record("expected nonZeroExit, got \(error)")
        }
    }

    @Test func runThrowsTimedOutAndTerminatesAProcessThatOutlivesTheTimeout() async throws {
        let runner = AssistantProcessRunner(timeout: .milliseconds(100))
        let start = ContinuousClock.now

        do {
            _ = try await runner.run(command: "sleep", arguments: ["30"])
            Issue.record("expected timedOut")
        } catch AssistantProcessError.timedOut {
            // expected — and well under the process's own 30s sleep, so the
            // watchdog (not the process exiting on its own) caused this.
            #expect(start.duration(to: .now) < .seconds(5))
        } catch {
            Issue.record("expected timedOut, got \(error)")
        }
    }

    @Test func runCancellationTerminatesTheUnderlyingProcess() async throws {
        let runner = AssistantProcessRunner()
        let task = Task {
            try await runner.run(command: "sleep", arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("expected cancellation to surface as an error")
        } catch {
            // A terminated `sleep` reports a non-zero exit; either that or
            // CancellationError is an acceptable outcome of cancelling.
        }
    }
}
