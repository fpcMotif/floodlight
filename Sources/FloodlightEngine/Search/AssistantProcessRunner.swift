import Darwin
import Foundation
import os

/// Runs an already-installed CLI and reports back whether it's runnable at
/// all, and what it printed. The seam `SearchCoordinator` calls through so
/// tests never spawn a real `codex`/`claude` process.
package protocol AssistantProcessRunning: Sendable {
    /// Whether `command` resolves to a runnable executable on this Mac.
    /// Checked once at startup so an uninstalled CLI's keyword row never
    /// appears in the first place.
    func isAvailable(command: String) async -> Bool

    /// Runs `command` with `arguments` and returns its trimmed stdout.
    /// `arguments` are passed directly to the process, never through a
    /// shell — nothing in them can be interpreted as shell syntax.
    func run(command: String, arguments: [String]) async throws -> String
}

package enum AssistantProcessError: Error, Equatable, Sendable {
    case executableNotFound(String)
    case nonZeroExit(status: Int32, message: String)
    case outputLimitExceeded(limit: Int)
    case timedOut
}

/// The real `AssistantProcessRunning`, backed by `Foundation.Process`.
///
/// GUI apps on macOS don't inherit a login shell's `$PATH` — Homebrew, nvm,
/// and asdf shims live in directories a plain `Process` launch never sees —
/// so resolution checks common install locations first, then falls back to
/// asking a login shell for its own `$PATH`.
package struct AssistantProcessRunner: AssistantProcessRunning {
    private static let commonDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]
    /// How long an escalated SIGTERM gets to land before this resorts to
    /// SIGKILL — a CLI that traps SIGTERM would otherwise hang forever past
    /// `timeout`.
    private static let terminationGracePeriod: Duration = .seconds(2)

    private let timeout: Duration
    private let maxOutputBytes: Int

    private struct CapturedOutput: Sendable {
        var stdout = Data()
        var stderr = Data()
        var storedByteCount = 0
        var exceededLimit = false

        mutating func append(
            _ chunk: Data,
            toStdout: Bool,
            limit: Int
        ) -> Bool {
            guard !exceededLimit else { return false }
            let remaining = max(0, limit - storedByteCount)
            let storedCount = min(remaining, chunk.count)
            if storedCount > 0 {
                if toStdout {
                    stdout.append(contentsOf: chunk.prefix(storedCount))
                } else {
                    stderr.append(contentsOf: chunk.prefix(storedCount))
                }
                storedByteCount += storedCount
            }
            guard storedCount < chunk.count else { return false }
            exceededLimit = true
            return true
        }
    }

    private struct OutputDrainer: Sendable {
        let process: Process
        let capturedOutput: OSAllocatedUnfairLock<CapturedOutput>
        let limit: Int
        let group: DispatchGroup
        let queue: DispatchQueue

        func start(_ handle: FileHandle, toStdout: Bool) {
            queue.async {
                defer { group.leave() }
                while let chunk = try? handle.read(upToCount: 16 * 1_024),
                      !chunk.isEmpty
                {
                    let exceeded = capturedOutput.withLock { captured in
                        captured.append(chunk, toStdout: toStdout, limit: limit)
                    }
                    if exceeded, process.isRunning {
                        process.terminate()
                    }
                }
            }
        }
    }

    package init(
        timeout: Duration = .seconds(45),
        maxOutputBytes: Int = 256 * 1_024
    ) {
        self.timeout = timeout
        self.maxOutputBytes = max(1, maxOutputBytes)
    }

    package func isAvailable(command: String) async -> Bool {
        await Self.resolveExecutable(named: command) != nil
    }

    package func run(command: String, arguments: [String]) async throws -> String {
        guard let executableURL = await Self.resolveExecutable(named: command) else {
            throw AssistantProcessError.executableNotFound(command)
        }
        return try await Self.run(
            executableURL: executableURL,
            arguments: arguments,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
    }

    package static func resolveExecutable(named command: String) async -> URL? {
        guard isBareExecutableName(command) else { return nil }
        let fileManager = FileManager.default
        for directory in commonDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        // No user input reaches this shell invocation — it only echoes
        // $PATH, so there's nothing here for a query to inject into.
        guard let loginPath = try? await run(
            executableURL: URL(fileURLWithPath: "/bin/zsh"),
            arguments: ["-l", "-c", "echo -n \"$PATH\""],
            timeout: .seconds(5),
            maxOutputBytes: 64 * 1_024
        ) else {
            return nil
        }

        for directory in loginPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func isBareExecutableName(_ command: String) -> Bool {
        !command.isEmpty && command != "." && command != ".." && command.utf8.allSatisfy { byte in
            byte >= 0x41 && byte <= 0x5A
                || byte >= 0x61 && byte <= 0x7A
                || byte >= 0x30 && byte <= 0x39
                || byte == 0x2D
                || byte == 0x2E
                || byte == 0x5F
                || byte == 0x2B
        }
    }

    private static func run(
        executableURL: URL,
        arguments: [String],
        timeout: Duration,
        maxOutputBytes: Int
    ) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let capturedOutput = OSAllocatedUnfairLock(initialState: CapturedOutput())
        let drains = DispatchGroup()
        let drainQueue = DispatchQueue(
            label: "com.floodlight.assistant-output",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let drainer = OutputDrainer(
            process: process,
            capturedOutput: capturedOutput,
            limit: maxOutputBytes,
            group: drains,
            queue: drainQueue
        )

        // `Process.terminate()` raises on a process that was never
        // launched, and both the watchdog and cancellation can reach for it
        // concurrently — every call site checks `isRunning` first, and only
        // the first resolution actually resumes the continuation.
        let resolved = OSAllocatedUnfairLock(initialState: false)
        @Sendable func resumeOnce(
            _ continuation: CheckedContinuation<String, Error>,
            with result: Result<String, Error>
        ) {
            let shouldResume = resolved.withLock { alreadyResolved in
                guard !alreadyResolved else { return false }
                alreadyResolved = true
                return true
            }
            guard shouldResume else { return }
            continuation.resume(with: result)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<
                String,
                Error
            >) in
                let watchdog = Task {
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, process.isRunning else { return }
                    process.terminate()
                    resumeOnce(continuation, with: .failure(AssistantProcessError.timedOut))

                    // Best-effort escalation for a CLI that traps SIGTERM —
                    // doesn't block the caller, who already has their answer.
                    try? await Task.sleep(for: terminationGracePeriod)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }

                process.terminationHandler = { finished in
                    drains.notify(queue: drainQueue) {
                        watchdog.cancel()
                        let captured = capturedOutput.withLock { $0 }
                        resumeOnce(
                            continuation,
                            with: processResult(
                                status: finished.terminationStatus,
                                captured: captured,
                                limit: maxOutputBytes
                            )
                        )
                    }
                }

                do {
                    drains.enter()
                    drains.enter()
                    try process.run()

                    drainer.start(stdout.fileHandleForReading, toStdout: true)
                    drainer.start(stderr.fileHandleForReading, toStdout: false)
                } catch {
                    drains.leave()
                    drains.leave()
                    watchdog.cancel()
                    resumeOnce(continuation, with: .failure(error))
                }
            }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
        }
    }

    private static func processResult(
        status: Int32,
        captured: CapturedOutput,
        limit: Int
    ) -> Result<String, Error> {
        if captured.exceededLimit {
            return .failure(AssistantProcessError.outputLimitExceeded(limit: limit))
        }
        guard status == 0 else {
            let message = String(data: captured.stderr, encoding: .utf8) ?? ""
            return .failure(
                AssistantProcessError.nonZeroExit(
                    status: status,
                    message: message.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
        let output = String(data: captured.stdout, encoding: .utf8) ?? ""
        return .success(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
