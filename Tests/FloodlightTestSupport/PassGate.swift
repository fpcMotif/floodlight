import Foundation

/// A one-way latch a test opens to let a scripted pass finish.
///
/// It stands in for a wall-clock delay wherever the test must observe a moment
/// *before* the pass completes. A delay is a guess at how slow the runner is,
/// and a loaded sanitizer runner can outlast any guess; a gate holds until the
/// test has seen what it came to see.
///
/// Once open it stays open, so a pass the coordinator re-issues after the test
/// releases it does not park forever. A waiter whose task is cancelled throws
/// `CancellationError`, as `Task.sleep` would, so a superseded pass unwinds
/// instead of leaking a suspended task.
package final class PassGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    package init() {}

    package func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Decided under the lock: `open()` or the cancel handler may
                // run between the check and the registration otherwise, and
                // the waiter would miss both.
                let verdict: Result<Void, any Error>? = lock.withLock {
                    if isOpen { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    waiters[id] = continuation
                    return nil
                }
                if let verdict { continuation.resume(with: verdict) }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    package func open() {
        let released = lock.withLock {
            isOpen = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for waiter in released {
            waiter.resume()
        }
    }
}
