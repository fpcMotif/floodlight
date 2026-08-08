import Foundation

package struct SearchSnapshot: Sendable, Equatable {
    package let candidates: [SearchItem]
    package let totalMatches: [SearchItemKind: Int]
    package let pendingKinds: Set<SearchItemKind>
    package let isSettled: Bool
    // periphery:ignore - Snapshot contract carries degradation while visible UI is deferred.
    package let isDegraded: Bool

    package init(
        candidates: [SearchItem],
        totalMatches: [SearchItemKind: Int],
        pendingKinds: Set<SearchItemKind>,
        isDegraded: Bool
    ) {
        self.candidates = candidates
        self.totalMatches = totalMatches
        self.pendingKinds = pendingKinds
        isSettled = pendingKinds.isEmpty
        self.isDegraded = isDegraded
    }
}

package protocol SourceSearching: Sendable {
    func warmUp() async
    func search(_ query: String, immediate: Bool) async -> AsyncStream<SearchSnapshot>
    // periphery:ignore - Explicit Search Execution lifecycle seam.
    func cancel() async
    func changeScope(to url: URL) async throws
    func rebuild() async throws
    func trackSelection(
        of candidateID: SearchItem.ID,
        selectedURL: URL,
        for query: String
    ) async
}

/// The deliberately specialised file-source seam. Unlike catalogs, a file
/// source has scope mutation, content search, and rebuild capabilities.
package protocol FileSource: Sendable {
    func start() async throws
    func indexedItems(for query: String, limit: Int) async throws -> [SearchItem]
    func contentItems(for query: String) async throws -> [SearchItem]
    func changeScope(to url: URL) async throws
    func rebuild() async throws
    func track(query: String, selectedURL: URL)
}

package actor SourceSearchEngine: SourceSearching {
    private enum Provenance: Sendable { case files, applications, settings }

    private struct Execution {
        let token: UInt64
        let query: String
        let immediate: Bool
        let continuation: AsyncStream<SearchSnapshot>.Continuation
        var task: Task<Void, Never>?
    }

    private struct SourceMutation {
        let token: UInt64
        let task: Task<Result<Void, any Error>, Never>
    }

    private struct Startup {
        let token: UInt64
        let task: Task<Result<Void, any Error>, Never>
    }

    private let files: any FileSource
    private let applications: any Catalog
    private let settings: any Catalog
    private var filesReady = false
    private var applicationsReady = false
    private var settingsReady = false
    private var filesStartup: Startup?
    private var applicationsStartup: Startup?
    private var settingsStartup: Startup?
    private var sourceMutation: SourceMutation?
    private var execution: Execution?
    private var selectionProvenance: [String: [SearchItem.ID: Provenance]] = [:]
    private var provenanceQueries: [String] = []
    private var pendingSearchToken: UInt64?
    private var nextToken: UInt64 = 0
    private var nextMutationToken: UInt64 = 0
    private var nextStartupToken: UInt64 = 0

    package init(
        files: any FileSource,
        applications: any Catalog,
        settings: any Catalog
    ) {
        self.files = files
        self.applications = applications
        self.settings = settings
    }

    package func warmUp() async {
        let readinessBefore = (filesReady, applicationsReady, settingsReady)
        _ = await ensureStarted()
        async let applicationRefresh = isolatedRefresh("applications") {
            try await self.applications.refreshIfNeeded()
        }
        async let settingsRefresh = isolatedRefresh("settings") {
            try await self.settings.refreshIfNeeded()
        }
        let refreshes = await (applicationRefresh, settingsRefresh)
        let readinessChanged = readinessBefore.0 != filesReady
            || readinessBefore.1 != applicationsReady
            || readinessBefore.2 != settingsReady
        guard readinessChanged
            || refreshes.0.changed || refreshes.1.changed
            || refreshes.0.failed || refreshes.1.failed,
            let active = invalidateActiveExecution()
        else { return }
        restart(active)
    }

    package func search(
        _ query: String,
        immediate: Bool = false
    ) async -> AsyncStream<SearchSnapshot> {
        guard !Task.isCancelled else { return finishedStream() }
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        nextToken &+= 1
        let token = nextToken
        pendingSearchToken = token
        if let sourceMutation {
            _ = await sourceMutation.task.value
        }
        guard !Task.isCancelled else {
            if pendingSearchToken == token {
                pendingSearchToken = nil
                resumeInvalidatedExecutionIfNeeded()
            }
            return finishedStream()
        }
        guard pendingSearchToken == token else { return finishedStream() }
        pendingSearchToken = nil
        finishActiveExecution()
        guard !normalized.isEmpty else { return finishedStream() }

        var continuation: AsyncStream<SearchSnapshot>.Continuation!
        let stream = AsyncStream<SearchSnapshot>(bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        execution = Execution(
            token: token,
            query: normalized,
            immediate: immediate,
            continuation: continuation
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(token: token) }
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await execute(token: token, query: normalized, immediate: immediate)
        }
        execution?.task = task
        return stream
    }

    // periphery:ignore - Explicit Search Execution lifecycle seam.
    package func cancel() async {
        guard !Task.isCancelled else { return }
        pendingSearchToken = nil
        finishActiveExecution()
    }

    package func changeScope(to url: URL) async throws {
        let active = invalidateActiveExecution()
        let files = files
        let predecessor = sourceMutation?.task
        nextMutationToken &+= 1
        let token = nextMutationToken
        let mutation = Task<Result<Void, any Error>, Never> { [weak self] in
            guard let self else { return .failure(CancellationError()) }
            if let predecessor { _ = await predecessor.value }
            do {
                try await ensureFilesReady()
                try await files.changeScope(to: url)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        sourceMutation = SourceMutation(token: token, task: mutation)
        let result = await mutation.value
        if sourceMutation?.token == token {
            sourceMutation = nil
            if let active { restart(active) }
        }
        try result.get()
    }

    package func rebuild() async throws {
        let active = invalidateActiveExecution()
        let files = files
        let predecessor = sourceMutation?.task
        nextMutationToken &+= 1
        let token = nextMutationToken
        let mutation = Task<Result<Void, any Error>, Never> { [weak self] in
            guard let self else { return .failure(CancellationError()) }
            if let predecessor { _ = await predecessor.value }
            do {
                try await ensureFilesReady()
                try await files.rebuild()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        sourceMutation = SourceMutation(token: token, task: mutation)
        let result = await mutation.value
        if sourceMutation?.token == token {
            sourceMutation = nil
            if let active { restart(active) }
        }
        try result.get()
    }

    package func trackSelection(
        of candidateID: SearchItem.ID,
        selectedURL: URL,
        for query: String
    ) async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source = selectionProvenance[normalized]?[candidateID] else { return }
        switch source {
        case .files: files.track(query: query, selectedURL: selectedURL)
        case .applications: applications.track(query: query, selectedURL: selectedURL)
        case .settings: settings.track(query: query, selectedURL: selectedURL)
        }
    }

    private func execute(token: UInt64, query: String, immediate: Bool) async {
        let searchSignpost = FloodlightPerformance.begin("SourceSearch")
        defer { FloodlightPerformance.end("SourceSearch", id: searchSignpost) }

        if let sourceMutation { _ = await sourceMutation.task.value }
        guard isCurrent(token), !Task.isCancelled else { return }
        let appPage = applications.immediatePage(for: query, limit: 12)
        let settingsPage = settings.immediatePage(for: query, limit: 24)
        let immediateCandidates = merge([
            (appPage.items, Provenance.applications),
            (settingsPage.items, Provenance.settings),
        ])
        var initialPending: Set<SearchItemKind> = [.application, .file, .folder]
        if !settingsReady { initialPending.insert(.systemSetting) }
        publish(
            token: token,
            snapshot: SearchSnapshot(
                candidates: immediateCandidates.items,
                totalMatches: totals(for: immediateCandidates.items, overrides: [
                    .application: appPage.totalMatched,
                    .systemSetting: settingsPage.totalMatched,
                ]),
                pendingKinds: initialPending,
                isDegraded: false
            ),
            provenance: immediateCandidates.provenance
        )

        if !immediate {
            try? await Task.sleep(for: .milliseconds(appPage.items.isEmpty ? 15 : 20))
        }
        guard isCurrent(token), !Task.isCancelled else { return }
        var degraded = await ensureStarted()
        guard isCurrent(token), !Task.isCancelled else { return }

        async let applicationRefresh = isolatedRefresh("applications") {
            try await self.applications.refreshIfNeeded()
        }
        async let settingsRefresh = isolatedRefresh("settings") {
            try await self.settings.refreshIfNeeded()
        }
        let refreshes = await (applicationRefresh, settingsRefresh)
        degraded = degraded || refreshes.0.failed || refreshes.1.failed
        guard isCurrent(token), !Task.isCancelled else { return }

        // Both real catalogs can acquire their first snapshot in start(), and
        // refresh may replace it again. Never carry the pre-start pages into
        // an indexed or settled snapshot.
        let currentAppPage = applications.immediatePage(for: query, limit: 12)
        let currentSettingsPage = settings.immediatePage(for: query, limit: 24)

        let indexedSignpost = FloodlightPerformance.begin("IndexedSourceSearch")
        async let fileResult = isolated { try await self.files.indexedItems(for: query, limit: 12) }
        async let appResult = isolated { try await self.applications.indexedItems(
            for: query,
            limit: 12
        ) }
        let (indexedFiles, indexedApps) = await (fileResult, appResult)
        FloodlightPerformance.end("IndexedSourceSearch", id: indexedSignpost)
        degraded = degraded || indexedFiles.failed || indexedApps.failed
        guard isCurrent(token), !Task.isCancelled else { return }

        let indexedCandidates = merge([
            (currentAppPage.items, .applications),
            (indexedApps.value, .applications),
            (currentSettingsPage.items, .settings),
            (indexedFiles.value, .files),
        ])
        let contentEligible = query.count >= 3 && indexedFiles.value.count < 12
        publish(
            token: token,
            snapshot: SearchSnapshot(
                candidates: indexedCandidates.items,
                totalMatches: totals(for: indexedCandidates.items, overrides: [
                    .application: max(currentAppPage.totalMatched, indexedApps.value.count),
                    .systemSetting: currentSettingsPage.totalMatched,
                ]),
                pendingKinds: contentEligible ? [.file] : [],
                isDegraded: degraded
            ),
            provenance: indexedCandidates.provenance
        )
        guard contentEligible else { return }
        try? await Task.sleep(for: .milliseconds(30))
        guard isCurrent(token), !Task.isCancelled else { return }
        let contentSignpost = FloodlightPerformance.begin("ContentSourceSearch")
        let content = await isolated { try await self.files.contentItems(for: query) }
        FloodlightPerformance.end("ContentSourceSearch", id: contentSignpost)
        degraded = degraded || content.failed
        guard isCurrent(token), !Task.isCancelled else { return }
        let complete = merge([
            (currentAppPage.items, .applications),
            (indexedApps.value, .applications),
            (currentSettingsPage.items, .settings),
            (indexedFiles.value, .files),
            (content.value, .files),
        ])
        publish(
            token: token,
            snapshot: SearchSnapshot(
                candidates: complete.items,
                totalMatches: totals(for: complete.items, overrides: [
                    .application: max(currentAppPage.totalMatched, indexedApps.value.count),
                    .systemSetting: currentSettingsPage.totalMatched,
                ]),
                pendingKinds: [],
                isDegraded: degraded
            ),
            provenance: complete.provenance
        )
    }

    private func isolated(_ operation: @escaping @Sendable () async throws -> [SearchItem]) async
        -> (value: [SearchItem], failed: Bool)
    {
        do {
            return try await (operation(), false)
        } catch is CancellationError {
            return ([], false)
        } catch {
            log(error, source: "search source")
            return ([], true)
        }
    }

    private func isolatedRefresh(
        _ source: String,
        _ operation: @escaping @Sendable () async throws -> Bool
    ) async -> (changed: Bool, failed: Bool) {
        do {
            return try await (operation(), false)
        } catch is CancellationError {
            return (false, false)
        } catch {
            log(error, source: "\(source) refresh")
            return (false, true)
        }
    }

    private func ensureStarted() async -> Bool {
        async let fileResult = startFiles()
        async let applicationResult = startApplications()
        async let settingsResult = startSettings()
        let results = await (fileResult, applicationResult, settingsResult)
        if case (.success, .success, .success) = results { return false }
        return true
    }

    private func ensureFilesReady() async throws {
        try await startFiles().get()
    }

    private func startFiles() async -> Result<Void, any Error> {
        guard !filesReady else { return .success(()) }
        let startup = filesStartup ?? makeStartup { try await self.files.start() }
        if filesStartup == nil { filesStartup = startup }
        let result = await startup.task.value
        if filesStartup?.token == startup.token {
            filesStartup = nil
            if case .success = result { filesReady = true }
            if case let .failure(error) = result { log(error, source: "files startup") }
        }
        return result
    }

    private func startApplications() async -> Result<Void, any Error> {
        guard !applicationsReady else { return .success(()) }
        let startup = applicationsStartup ?? makeStartup {
            try await self.applications.start()
        }
        if applicationsStartup == nil { applicationsStartup = startup }
        let result = await startup.task.value
        if applicationsStartup?.token == startup.token {
            applicationsStartup = nil
            if case .success = result { applicationsReady = true }
            if case let .failure(error) = result { log(error, source: "applications startup") }
        }
        return result
    }

    private func startSettings() async -> Result<Void, any Error> {
        guard !settingsReady else { return .success(()) }
        let startup = settingsStartup ?? makeStartup { try await self.settings.start() }
        if settingsStartup == nil { settingsStartup = startup }
        let result = await startup.task.value
        if settingsStartup?.token == startup.token {
            settingsStartup = nil
            if case .success = result { settingsReady = true }
            if case let .failure(error) = result { log(error, source: "settings startup") }
        }
        return result
    }

    private func makeStartup(
        _ operation: @escaping @Sendable () async throws -> Void
    ) -> Startup {
        nextStartupToken &+= 1
        let token = nextStartupToken
        return Startup(
            token: token,
            task: Task {
                do {
                    try await operation()
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }
        )
    }

    private nonisolated func log(_ error: any Error, source: String) {
        NSLog("Floodlight %@ failed: %@", source, String(describing: error))
    }

    private func merge(_ sources: [([SearchItem], Provenance)])
        -> (items: [SearchItem], provenance: [SearchItem.ID: Provenance])
    {
        var seen = Set<SearchItem.ID>(), items: [SearchItem] = [],
            provenance: [SearchItem.ID: Provenance] = [:]
        for (candidates, source) in sources {
            for candidate in candidates where seen.insert(candidate.id).inserted {
                items.append(candidate)
                provenance[candidate.id] = source
            }
        }
        // The shell owns the final command/calculator/web merge and ranks the
        // complete list once. Sorting this partial list would repeat that work
        // for every progressive snapshot.
        return (items, provenance)
    }

    private func totals(
        for candidates: [SearchItem],
        overrides: [SearchItemKind: Int]
    ) -> [SearchItemKind: Int] {
        var result: [SearchItemKind: Int] = [:]
        for candidate in candidates {
            result[candidate.kind, default: 0] += 1
        }
        for (kind, count) in overrides {
            result[kind] = max(result[kind, default: 0], count)
        }
        return result
    }

    private func publish(
        token: UInt64,
        snapshot: SearchSnapshot,
        provenance: [SearchItem.ID: Provenance]
    ) {
        guard let execution, execution.token == token else { return }
        selectionProvenance[execution.query] = provenance
        provenanceQueries.removeAll { $0 == execution.query }
        provenanceQueries.append(execution.query)
        while provenanceQueries.count > 2 {
            selectionProvenance.removeValue(forKey: provenanceQueries.removeFirst())
        }
        execution.continuation.yield(snapshot)
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        execution?.token == token
            && (pendingSearchToken == nil || pendingSearchToken == token)
    }

    private func finishedStream() -> AsyncStream<SearchSnapshot> {
        AsyncStream { $0.finish() }
    }

    private func cancel(token: UInt64) {
        if execution?.token == token { finishActiveExecution() }
    }

    private func invalidateActiveExecution() -> (token: UInt64, query: String, immediate: Bool)? {
        guard let execution else { return nil }
        execution.task?.cancel()
        self.execution?.task = nil
        self.execution?.continuation.yield(SearchSnapshot(
            candidates: [],
            totalMatches: [:],
            pendingKinds: [.application, .file, .folder, .systemSetting],
            isDegraded: false
        ))
        return (execution.token, execution.query, execution.immediate)
    }

    private func restart(_ active: (token: UInt64, query: String, immediate: Bool)) {
        guard execution?.token == active.token,
              execution?.task == nil,
              pendingSearchToken == nil
        else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await execute(token: active.token, query: active.query, immediate: active.immediate)
        }
        execution?.task = task
    }

    private func resumeInvalidatedExecutionIfNeeded() {
        guard pendingSearchToken == nil, let execution, execution.task == nil else { return }
        restart((execution.token, execution.query, execution.immediate))
    }

    private func finishActiveExecution() {
        execution?.task?.cancel()
        execution?.continuation.finish()
        execution = nil
    }
}
