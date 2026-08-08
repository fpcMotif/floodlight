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

    package init(timeout: Duration = .seconds(45)) {
        self.timeout = timeout
    }

    package func isAvailable(command: String) async -> Bool {
        await Self.resolveExecutable(named: command) != nil
    }

    package func run(command: String, arguments: [String]) async throws -> String {
        guard let executableURL = await Self.resolveExecutable(named: command) else {
            throw AssistantProcessError.executableNotFound(command)
        }
        return try await Self.run(executableURL: executableURL, arguments: arguments, timeout: timeout)
    }

    package static func resolveExecutable(named command: String) async -> URL? {
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
            timeout: .seconds(5)
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

    private static func run(executableURL: URL, arguments: [String], timeout: Duration) async throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

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
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
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
                    watchdog.cancel()
                    let output = String(
                        data: stdout.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                    guard finished.terminationStatus == 0 else {
                        let message = String(
                            data: stderr.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8
                        ) ?? ""
                        resumeOnce(
                            continuation,
                            with: .failure(
                                AssistantProcessError.nonZeroExit(
                                    status: finished.terminationStatus,
                                    message: message.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                            )
                        )
                        return
                    }
                    resumeOnce(continuation, with: .success(output.trimmingCharacters(in: .whitespacesAndNewlines)))
                }

                do {
                    try process.run()
                } catch {
                    watchdog.cancel()
                    resumeOnce(continuation, with: .failure(error))
                }
            }
        } onCancel: {
            guard process.isRunning else { return }
            process.terminate()
        }
    }
}
