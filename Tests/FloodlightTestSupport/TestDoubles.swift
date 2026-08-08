import FloodlightEngine
import Foundation

/// A fully programmable `Catalog`.
///
/// The real catalogs walk the filesystem, so a coordinator test driven by
/// them can only assert on whatever happens to be installed. This one lets
/// a test state exactly what each pass returns, how slow it is, and whether
/// it fails — including the combinations that only happen under load: the
/// indexed pass finishing before the immediate pass, a refresh reporting a
/// change mid-query, or `start()` throwing.
package final class ScriptedCatalog: Catalog, @unchecked Sendable {
    package struct Behavior: Sendable {
        package var immediate: [SearchItem]
        package var totalMatched: Int?
        package var indexed: [SearchItem]
        package var indexedDelay: Duration
        package var startError: (any Error)?
        package var indexedError: (any Error)?
        package var refreshReportsChange: Bool
        package var refreshError: (any Error)?

        package init(
            immediate: [SearchItem] = [],
            totalMatched: Int? = nil,
            indexed: [SearchItem] = [],
            indexedDelay: Duration = .zero,
            startError: (any Error)? = nil,
            indexedError: (any Error)? = nil,
            refreshReportsChange: Bool = false,
            refreshError: (any Error)? = nil
        ) {
            self.immediate = immediate
            self.totalMatched = totalMatched
            self.indexed = indexed
            self.indexedDelay = indexedDelay
            self.startError = startError
            self.indexedError = indexedError
            self.refreshReportsChange = refreshReportsChange
            self.refreshError = refreshError
        }
    }

    private let lock = NSLock()
    private var behavior: Behavior
    private var perQuery: [String: Behavior] = [:]
    private var recordedQueries: [String] = []
    private var recordedTracks: [(query: String, url: URL)] = []
    private var startCount = 0
    private var refreshCount = 0
    private var indexedCount = 0

    package init(_ behavior: Behavior = Behavior()) {
        self.behavior = behavior
    }

    package convenience init(immediate: [SearchItem], indexed: [SearchItem] = []) {
        self.init(Behavior(immediate: immediate, indexed: indexed))
    }

    // MARK: Programming

    package func setBehavior(_ behavior: Behavior) {
        lock.lock()
        self.behavior = behavior
        lock.unlock()
    }

    package func setBehavior(_ behavior: Behavior, forQuery query: String) {
        lock.lock()
        perQuery[query] = behavior
        lock.unlock()
    }

    private func behavior(for query: String) -> Behavior {
        lock.lock()
        defer { lock.unlock() }
        return perQuery[query] ?? behavior
    }

    // MARK: Observation

    package var queries: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedQueries
    }

    package var tracked: [(query: String, url: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return recordedTracks
    }

    package var starts: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCount
    }

    package var refreshes: Int {
        lock.lock()
        defer { lock.unlock() }
        return refreshCount
    }

    package var indexedSearches: Int {
        lock.lock()
        defer { lock.unlock() }
        return indexedCount
    }

    // MARK: Catalog

    package func start() async throws {
        if let error = recordStart() { throw error }
    }

    private func recordStart() -> (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        startCount += 1
        return behavior.startError
    }

    package func refreshIfNeeded(
        minimumInterval: TimeInterval,
        forceDiscovery: Bool
    ) async throws -> Bool {
        let current = recordRefresh()
        if let error = current.refreshError { throw error }
        return current.refreshReportsChange
    }

    private func recordRefresh() -> Behavior {
        lock.lock()
        defer { lock.unlock() }
        refreshCount += 1
        return behavior
    }

    package func immediatePage(for query: String, limit: Int) -> SearchItemPage {
        let current = behavior(for: query)
        lock.lock()
        recordedQueries.append(query)
        lock.unlock()
        let matches = current.immediate
        return SearchItemPage(
            items: Array(matches.prefix(limit)),
            totalMatched: current.totalMatched ?? matches.count
        )
    }

    package func indexedItems(for query: String, limit: Int) async throws -> [SearchItem] {
        let current = recordIndexedSearch(query: query)
        if current.indexedDelay > .zero {
            try await Task.sleep(for: current.indexedDelay)
        }
        if let error = current.indexedError { throw error }
        return Array(current.indexed.prefix(limit))
    }

    private func recordIndexedSearch(query: String) -> Behavior {
        lock.lock()
        defer { lock.unlock() }
        indexedCount += 1
        return perQuery[query] ?? behavior
    }

    package func track(query: String, selectedURL: URL) {
        lock.lock()
        recordedTracks.append((query, selectedURL))
        lock.unlock()
    }
}

/// An `AssistantProcessRunning` whose every call is scripted and counted.
///
/// Two modes: `.immediate` resolves as soon as it's called (for tests that
/// only care about the end state), and `.suspending` parks until the test
/// resolves it (for tests that need to observe `.running`, cancel mid-flight,
/// or interleave two asks).
package actor ScriptedAssistantRunner: AssistantProcessRunning {
    package enum Mode: Sendable {
        case immediate(Result<String, any Error>)
        case suspending
    }

    private var availableCommands: Set<String>
    private var mode: Mode
    /// Keyed by call, so cancelling one in-flight ask resolves only that
    /// ask. A single shared list would let a cancelled call drain a live
    /// one's continuation, which deadlocks the test instead of failing it.
    private var pending: [Int: CheckedContinuation<String, any Error>] = [:]
    private var nextCallID = 0
    private var recordedRuns: [(command: String, arguments: [String])] = []
    private var availabilityChecks: [String] = []
    private(set) package var cancellations = 0

    package init(
        availableCommands: Set<String> = [],
        mode: Mode = .suspending
    ) {
        self.availableCommands = availableCommands
        self.mode = mode
    }

    package func setMode(_ mode: Mode) {
        self.mode = mode
    }

    package func setAvailableCommands(_ commands: Set<String>) {
        availableCommands = commands
    }

    package var runs: [(command: String, arguments: [String])] { recordedRuns }
    package var checkedCommands: [String] { availabilityChecks }
    package var pendingCount: Int { pending.count }

    package func isAvailable(command: String) async -> Bool {
        availabilityChecks.append(command)
        return availableCommands.contains(command)
    }

    package func run(command: String, arguments: [String]) async throws -> String {
        recordedRuns.append((command, arguments))
        switch mode {
        case .immediate(let result):
            return try result.get()
        case .suspending:
            let callID = nextCallID
            nextCallID += 1
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending[callID] = continuation
                }
            } onCancel: {
                Task { await self.cancelCall(callID) }
            }
        }
    }

    /// Mirrors the real runner: cancelling terminates the process, which
    /// resolves that call. Without this a cancelled `run` would leak a
    /// suspended task and the test would hang instead of failing.
    private func cancelCall(_ callID: Int) {
        cancellations += 1
        pending.removeValue(forKey: callID)?.resume(throwing: CancellationError())
    }

    /// Resolves the oldest pending call, waiting for one to arrive — a
    /// `Task` is only scheduled when it is created, so a test can otherwise
    /// race ahead of the code it is driving.
    ///
    /// Throws rather than spinning forever: a runner that is never called
    /// should fail its test, not wedge the whole suite.
    package func resolveNext(
        with result: Result<String, any Error>,
        timeout: TimeInterval = 5
    ) async throws {
        try await waitForPendingRun(timeout: timeout)
        guard let callID = pending.keys.min() else {
            throw TestError.scripted("no pending assistant run to resolve")
        }
        pending.removeValue(forKey: callID)?.resume(with: result)
    }

    /// Resolves every currently-pending call with the same result. Use this
    /// when more than one ask may be in flight and the test does not care
    /// which one the coordinator kept.
    package func resolveAll(
        with result: Result<String, any Error>,
        timeout: TimeInterval = 5
    ) async throws {
        try await waitForPendingRun(timeout: timeout)
        let continuations = pending
        pending.removeAll()
        for (_, continuation) in continuations {
            continuation.resume(with: result)
        }
    }

    package func waitForPendingRun(timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while pending.isEmpty {
            if Date() >= deadline {
                throw TestError.scripted("no assistant run started within \(timeout)s")
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

/// A discovery provider whose contents a test can swap between refreshes,
/// standing in for applications being installed, renamed, and deleted.
package final class MutableDiscovery<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [Element]
    private var readCount = 0

    package init(_ elements: [Element]) {
        self.elements = elements
    }

    package func snapshot() -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return elements
    }

    package func replace(with elements: [Element]) {
        lock.lock()
        self.elements = elements
        lock.unlock()
    }

    package var reads: Int {
        lock.lock()
        defer { lock.unlock() }
        return readCount
    }
}

package enum TestError: LocalizedError, Equatable {
    case scripted(String)

    package var errorDescription: String? {
        switch self {
        case .scripted(let message): message
        }
    }
}
