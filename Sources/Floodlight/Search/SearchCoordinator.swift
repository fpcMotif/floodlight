import FloodlightEngine
import Foundation
import Observation

/// One query's worth of deep path navigation, resolved off the main actor
/// and reused by every projection of that query. Not to be confused with
/// the engine's `ResolvedPath`, which is what a single lookup returns: this
/// is that lookup's folder row plus the query and scope it is only valid
/// for.
private struct CachedPathResolution: Sendable {
    let query: String
    let rootURL: URL
    let folderRow: SearchItem?

    func matches(query: String, rootURL: URL) -> Bool {
        self.query == query && self.rootURL == rootURL
    }
}

@MainActor
@Observable
final class SearchCoordinator {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            assistantRunSession.cancel()
            guard !isResetting else { return }
            scheduleSearch()
        }
    }

    /// Local fuzzy search, or web mode scoped to one engine (entered with
    /// Tab, shown as the field's token). All transitions run through
    /// `SearchMode.transition` — this only publishes what it decides.
    private(set) var mode: SearchMode = .local
    var results: [SearchItem] {
        publication.visibleRows
    }

    var selectedFilter: SearchResultFilter {
        publication.selectedFilter
    }

    var selectedID: SearchItem.ID? {
        publication.selection?.id
    }

    // periphery:ignore - Test-visible Search Execution progress.
    var isSearching: Bool {
        publication.progress.isSearching
    }

    private(set) var rootURL: URL
    var focusGeneration = 0
    // The in-flight or completed state of the last "Ask Codex"/"Ask
    // Claude" the user triggered, or `nil` if none is active.
    // periphery:ignore - Test-visible Assistant Run integration publication.
    var assistantRun: AssistantRun? {
        assistantRunSession.run
    }

    /// The actually-registered summon shortcut ("⌘ Space"), set by
    /// `AppDelegate` once it knows whether the preferred combo registered
    /// or Carbon fell back to the alternate one — `nil` until then, or if
    /// registration failed outright. The idle capsule's hotkey chip reads
    /// this directly rather than re-deriving a preference that might not
    /// match what's actually active.
    var activeShortcutDisplayName: String?

    var filterOptions: [SearchFilterOption] {
        publication.filterOptions
    }

    /// The engine web mode is scoped to, or `nil` in local mode — what the
    /// search field's token renders.
    var activeWebEngine: KeywordEngine? {
        guard case let .web(context) = mode else { return nil }
        return keywordRegistry.webEngine(id: context.engineID)
    }

    var isClipboardMode: Bool {
        if case .clipboard = mode { return true }
        return false
    }

    @ObservationIgnored
    private let sourceSearch: any SourceSearching
    @ObservationIgnored
    package let blocklistStore: BlocklistStore
    @ObservationIgnored
    package let clipboardStore: ClipboardHistoryStore
    @ObservationIgnored
    private let assistantRunner: any AssistantProcessRunning
    @ObservationIgnored
    private let assistantRunSession: AssistantRunSession
    @ObservationIgnored
    private let actionPerformer: SelectedResultActionPerformer
    @ObservationIgnored
    private let onDismiss: @MainActor () -> Void
    @ObservationIgnored
    private let pathResolver: any PathResolving
    /// The one path resolution the current query paid for, tagged with the
    /// query and the committed scope it belongs to. Every projection of that
    /// query reads it instead of listing directories again.
    @ObservationIgnored
    private var pathResolution: CachedPathResolution?
    private var publication: SearchResultPublication
    @ObservationIgnored
    private var sourceWarmUpComplete = false
    @ObservationIgnored
    private var keywordRegistry: KeywordEngineRegistry
    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var startupTask: Task<Void, Never>?
    @ObservationIgnored
    private var isResetting = false

    /// Builds a coordinator over an already-constructed Source Search seam.
    init(
        sourceSearch: any SourceSearching,
        recentStore: RecentStore,
        blocklistStore: BlocklistStore = BlocklistStore(),
        clipboardStore: ClipboardHistoryStore = (try? ClipboardHistoryStore()) ??
            ClipboardHistoryStore.inMemory(),
        rootURL: URL,
        assistantRunner: any AssistantProcessRunning = AssistantProcessRunner(),
        runningApplicationActivator: any RunningApplicationActivating =
            WorkspaceRunningApplicationActivator(),
        actionEffects: any SelectedResultActionEffects = AppKitSelectedResultActionEffects(),
        pathResolver: any PathResolving = FileSystemPathResolver(),
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.sourceSearch = sourceSearch
        self.blocklistStore = blocklistStore
        self.clipboardStore = clipboardStore
        self.rootURL = rootURL
        self.assistantRunner = assistantRunner
        self.pathResolver = pathResolver
        self.onDismiss = onDismiss
        let assistantRunSession = AssistantRunSession(runner: assistantRunner)
        self.assistantRunSession = assistantRunSession
        actionPerformer = SelectedResultActionPerformer(
            effects: actionEffects,
            assistantRunSession: assistantRunSession,
            runningApplicationActivator: runningApplicationActivator,
            recentStore: recentStore,
            clipboardImagePayload: { [clipboardStore] id in
                clipboardStore.imageData(for: id)
            },
            trackSelection: { candidateID, selectedURL, query in
                await sourceSearch.trackSelection(
                    of: candidateID,
                    selectedURL: selectedURL,
                    for: query
                )
            },
            onDismiss: onDismiss
        )
        let keywordRegistry = KeywordEngineCatalog.initialRegistry
        self.keywordRegistry = keywordRegistry
        publication = SearchResultProjection.project(
            .local(.init(
                query: "",
                candidates: [],
                keywordRegistry: keywordRegistry,
                selectedFilter: .all,
                selection: nil,
                progress: SearchResultProgress(
                    isSearching: false,
                    totalMatches: [:],
                    pendingKinds: [.application, .systemSetting]
                )
            ))
        )
    }

    /// The live wiring: search scope from preferences, index and catalogs over
    /// the real filesystem. `assistantRunner` is overridable so tests can
    /// exercise the "Ask Codex"/"Ask Claude" seam without spawning a real
    /// process or depending on what's installed on the test machine.
    convenience init(
        assistantRunner: any AssistantProcessRunning = AssistantProcessRunner(),
        onDismiss: @escaping @MainActor () -> Void
    ) {
        let fileManager = FileManager.default
        let savedRoot = UserDefaults.standard.string(forKey: "index-root")
        let defaultRoot = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads", isDirectory: true)
        let initialRoot = savedRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? defaultRoot
        let fallbackStorage = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Floodlight",
                isDirectory: true
            )
        let indexStorage = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Floodlight", isDirectory: true))
            ?? fallbackStorage
        let environment = ProcessInfo.processInfo.environment
        let recentStore = RecentStore()
        let blocklistStore = BlocklistStore()
        let fileIndexStorage = indexStorage.appendingPathComponent("FileIndex", isDirectory: true)
        try? fileManager.createDirectory(at: fileIndexStorage, withIntermediateDirectories: true)

        self.init(
            sourceSearch: SourceSearchEngine(
                rootURL: initialRoot,
                storageURL: fileIndexStorage,
                applications: ApplicationCatalog(
                    recentStore: recentStore,
                    blocklistStore: blocklistStore,
                    deferDiscovery: true
                ),
                settings: SystemCatalog(),
                logFilePath: environment["FLOODLIGHT_FFF_LOG"],
                logLevel: environment["FLOODLIGHT_FFF_LOG_LEVEL"] ?? "info"
            ),
            recentStore: recentStore,
            blocklistStore: blocklistStore,
            clipboardStore: (try? ClipboardHistoryStore(databaseURL: indexStorage
                    .appendingPathComponent(
                        "clipboard.sqlite3",
                        isDirectory: false
                    ))) ?? ClipboardHistoryStore.inMemory(),
            rootURL: initialRoot,
            assistantRunner: assistantRunner,
            onDismiss: onDismiss
        )
    }

    deinit {
        searchTask?.cancel()
        startupTask?.cancel()
    }

    func start() {
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            let signpost = FloodlightPerformance.begin("IndexStartup")
            defer {
                FloodlightPerformance.end("IndexStartup", id: signpost)
            }
            async let sourceWarmUp: Void = sourceSearch.warmUp()
            async let resolvedKeywordRegistry = KeywordEngineCatalog
                .availableRegistry(runner: assistantRunner)
            await sourceWarmUp
            guard !Task.isCancelled else { return }
            sourceWarmUpComplete = true
            if case .local = mode,
               query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                publication = idleLocalPublication()
            }
            let resolvedRegistry = await resolvedKeywordRegistry
            guard !Task.isCancelled else { return }
            keywordRegistry = resolvedRegistry
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                scheduleSearch(immediate: true)
            }
        }
    }

    func prepareForPresentation() {
        focusGeneration += 1
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch(immediate: true)
        }
    }

    func reset() {
        searchTask?.cancel()
        searchTask = nil
        assistantRunSession.cancel()
        mode = .local
        isResetting = true
        query = ""
        isResetting = false
        pathResolution = nil
        publication = idleLocalPublication()
    }

    // MARK: - Web mode (Tab ↔ Esc)

    func handleTab() {
        applyModeEvent(.tab)
    }

    func handleShiftTab() {
        applyModeEvent(.shiftTab)
    }

    /// Esc's layering lives here, not in the field: in web mode the first
    /// Esc only exits the mode; in local mode Esc dismisses the panel
    /// exactly as it always has.
    func handleEscape() {
        switch mode {
        case .web, .clipboard:
            applyModeEvent(.escape)
        case .local:
            onDismiss()
        }
    }

    func handleBackspaceOnEmptyQuery() {
        applyModeEvent(.backspaceOnEmptyQuery)
    }

    /// The engine title for the "⇥ Search <Engine>" affordance on a ranked
    /// keyword row — non-nil only for `item` itself, only in local mode,
    /// and only when the matched engine is a URL engine Tab can complete
    /// into (assistant keywords fall through to plain-query Tab instead).
    func tabCompletionHint(for item: SearchItem) -> String? {
        guard
            case .local = mode,
            let title = keywordRegistry.tabCompletionTitle(for: query, resultID: item.id)
        else {
            return nil
        }
        return title
    }

    private func applyModeEvent(_ event: SearchModeEvent) {
        let next = SearchMode.transition(
            from: mode,
            query: query,
            event: event,
            registry: keywordRegistry
        )
        guard next.mode != mode || next.query != query else { return }
        let leavingClipboard = isClipboardMode && next.mode != mode
        let enteringClipboard: Bool = if case .clipboard = next.mode {
            !isClipboardMode
        } else {
            false
        }
        mode = next.mode
        if leavingClipboard {
            publication = idleLocalPublication()
        }
        if enteringClipboard {
            publishClipboardModeResults(selectedFilter: .all, selection: nil)
        }
        if query != next.query {
            // The observer republishes for the new mode.
            query = next.query
        } else if !enteringClipboard {
            scheduleSearch(immediate: true)
        }
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = selectedID
            .flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), results.count - 1)
        publication = publication.selecting(
            SearchResultSelection(id: results[nextIndex].id, origin: .user)
        )
    }

    func activate(_ item: SearchItem) {
        select(item)
        guard webModeReturnIsArmed else { return }
        performAction(for: item)
    }

    func select(_ item: SearchItem) {
        publication = publication.selecting(
            SearchResultSelection(id: item.id, origin: .user)
        )
    }

    func selectFilter(_ filter: SearchResultFilter) {
        guard filter != selectedFilter else {
            focusGeneration += 1
            return
        }
        if case .clipboard = mode {
            publishClipboardModeResults(selectedFilter: filter, selection: nil)
            focusGeneration += 1
            return
        }
        publication = projectLocal(
            candidates: publication.sourceCandidates,
            selectedFilter: filter,
            selection: nil,
            progress: publication.progress,
            filterContinuity: .preserve
        )
        focusGeneration += 1
    }

    func openSelection() {
        guard webModeReturnIsArmed, let item = selectedItem else { return }
        performAction(for: item)
    }

    /// Web mode's Return has exactly one meaning — open the engine's results
    /// page — so with nothing to search for it must do nothing at all, from
    /// the keyboard and the mouse alike. Local mode is never gated.
    private var webModeReturnIsArmed: Bool {
        guard case .web = mode else { return true }
        return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func performAction(for item: SearchItem) {
        actionPerformer.activate(item, query: query)
    }

    func excludeFromSearch(_ item: SearchItem) {
        blocklistStore.block(id: item.id)
        blocklistStore.block(name: item.title)
        let updatedCandidates = publication.sourceCandidates.filter {
            !blocklistStore.isBlocked(name: $0.title, id: $0.id)
        }
        publication = projectLocal(
            candidates: updatedCandidates,
            selectedFilter: selectedFilter,
            selection: publication.selection?.id == item.id ? nil : publication.selection,
            progress: publication.progress
        )
    }

    func revealSelection() {
        guard let selectedItem else { return }
        actionPerformer.reveal(selectedItem)
    }

    func copySelection() {
        guard let item = selectedItem else { return }
        actionPerformer.copy(item)
    }

    /// The previewable file URL of the current selection, or `nil` if the
    /// selection has no file URL or isn't previewable. The shell uses this to
    /// drive QuickLook without re-deriving previewability itself.
    var previewableSelectionURL: URL? {
        guard let selectedItem else { return nil }
        if selectedItem.isPreviewable, let fileURL = selectedItem.fileURL {
            return fileURL
        }
        if case let .copyImage(id) = selectedItem.action {
            return clipboardImagePreviewURL(for: id)
        }
        if case let .copy(text) = selectedItem.action,
           let localURL = ClipboardInspector.parseLocalPath(text),
           FileManager.default.fileExists(atPath: localURL.path)
        {
            return localURL
        }
        return nil
    }

    private func clipboardImagePreviewURL(for id: String) -> URL? {
        guard let payload = clipboardStore.imageData(for: id) ?? clipboardStore.entry(id: id)
            .flatMap({ entry in
                entry.image.flatMap { image in
                    image.thumbnailPNGData.isEmpty ? nil : ClipboardImagePayload(
                        png: image.thumbnailPNGData,
                        tiff: nil
                    )
                }
            })
        else {
            return nil
        }
        let data = payload.png ?? payload.tiff
        guard let data, !data.isEmpty else { return nil }
        let ext = payload.png != nil ? "png" : "tiff"
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FloodlightClipboardPreviews", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("\(id).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
        }
        return fileURL
    }

    /// `assistantRun`'s state, but only if it belongs to `item` — every
    /// other row gets `nil`. The view asks for this instead of comparing
    /// `assistantRun?.itemID` against its own item at the call site.
    func assistantAnswerState(for item: SearchItem) -> AssistantAnswerState? {
        assistantRunSession.state(for: item.id)
    }

    func rebuildIndex() {
        Task {
            do {
                try await sourceSearch.rebuild()
            } catch {
                NSLog("Floodlight index rebuild failed: %@", error.localizedDescription)
            }
        }
    }

    private var selectedItem: SearchItem? {
        guard let selectedID else { return results.first }
        return results.first { $0.id == selectedID }
    }

    func changeRoot(to url: URL) {
        Task {
            do {
                try await sourceSearch.changeScope(to: url)
                rootURL = url.standardizedFileURL
                UserDefaults.standard.set(rootURL.path, forKey: "index-root")
                await reresolvePathForCommittedScope()
            } catch {
                NSLog("Floodlight search-scope update failed: %@", error.localizedDescription)
            }
        }
    }

    private var currentQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleSearch(immediate: Bool = false) {
        if case let .web(context) = mode {
            searchTask?.cancel()
            searchTask = nil
            publishWebModeResults(context: context)
            return
        }

        if case .clipboard = mode {
            searchTask?.cancel()
            searchTask = nil
            publishClipboardModeResults()
            return
        }

        let requestQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !requestQuery.isEmpty else {
            searchTask = nil
            publication = idleLocalPublication()
            return
        }

        // Stale-while-revalidate: the previous publication's rows stay on
        // screen until the new Search Execution's first snapshot lands.
        // Clearing them here collapsed the list to the handful of synthetic
        // rows for a frame or two on every keystroke — and, under a narrow
        // filter, swapped the whole list for the empty state and back —
        // which read as a jump. The synthetic rows (calculator, keyword,
        // web fallback) still rebuild for the new query in this pass, so
        // they stay live; only the source rows wait for their snapshot.
        publication = projectLocal(
            candidates: publication.sourceCandidates,
            selectedFilter: selectedFilter,
            selection: publication.selection,
            progress: SearchResultProgress(
                isSearching: true,
                totalMatches: publication.progress.totalMatches,
                pendingKinds: sourceWarmUpComplete
                    ? [.application]
                    : [.application, .systemSetting]
            ),
            filterContinuity: .preserve
        )
        let resolver = pathResolver
        let scopeRoot = rootURL
        let previousResolution = pathResolution
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            // The path lookup and the Source Search pass start together and
            // are both awaited before the first snapshot publishes, so the
            // folder row still lands with the first results — the listings
            // just no longer happen on the main actor, four times over.
            async let resolution = Self.resolvePath(
                reusing: previousResolution,
                query: requestQuery,
                rootURL: scopeRoot,
                resolver: resolver
            )
            let snapshots = await sourceSearch.search(requestQuery, immediate: immediate)
            let resolved = await resolution
            guard !Task.isCancelled else { return }
            // Cancellation alone does not make the store safe — a superseded
            // task can still be scheduled onto the main actor before it
            // observes the flag — so only a resolution still answering the
            // live query under the committed scope is kept, and every read
            // re-checks the same pair. A scope committed since this pass
            // started has already resolved the query itself.
            if resolved.matches(query: currentQuery, rootURL: rootURL) {
                pathResolution = resolved
            }
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                publish(snapshot, query: requestQuery)
            }
        }
    }

    private func publish(
        _ snapshot: SearchSnapshot,
        query: String
    ) {
        publication = projectLocal(
            query: query,
            candidates: snapshot.candidates,
            selectedFilter: selectedFilter,
            selection: publication.selection,
            progress: SearchResultProgress(
                isSearching: !snapshot.isSettled,
                totalMatches: snapshot.totalMatches,
                pendingKinds: snapshot.pendingKinds
            ),
            filterContinuity: snapshot.isSettled ? .reconcileWhenSettled : .preserve
        )
    }

    /// The whole list while web mode is active: one row per preset URL
    /// engine, nothing else. The local passes stay paused — no catalog or
    /// index is touched — and any in-flight pass is cancelled so it can't
    /// land its results over the engine rows.
    private func publishWebModeResults(context: SearchMode.WebContext) {
        searchTask?.cancel()
        searchTask = nil
        publication = SearchResultProjection.project(
            .web(.init(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                activeEngineID: context.engineID,
                keywordRegistry: keywordRegistry,
                selectedFilter: selectedFilter,
                selection: publication.selection
            ))
        )
    }

    private func projectLocal(
        query: String? = nil,
        candidates: [SearchItem],
        selectedFilter: SearchResultFilter,
        selection: SearchResultSelection?,
        progress: SearchResultProgress,
        filterContinuity: SearchResultProjection.FilterContinuity = .reconcileWhenSettled
    ) -> SearchResultPublication {
        let validCandidates = candidates.filter { !blocklistStore.isBlocked(
            name: $0.title,
            id: $0.id
        ) }
        let projectedQuery = query ?? currentQuery
        return SearchResultProjection.project(
            .local(.init(
                query: projectedQuery,
                candidates: validCandidates,
                keywordRegistry: keywordRegistry,
                selectedFilter: selectedFilter,
                selection: selection,
                progress: progress,
                filterContinuity: filterContinuity,
                resolvedFolderRow: resolvedFolderRow(for: projectedQuery)
            ))
        )
    }

    private func idleLocalPublication() -> SearchResultPublication {
        projectLocal(
            query: "",
            candidates: [],
            selectedFilter: .all,
            selection: nil,
            progress: SearchResultProgress(
                isSearching: false,
                totalMatches: [:],
                pendingKinds: sourceWarmUpComplete ? [] : [.application, .systemSetting]
            ),
            filterContinuity: .preserve
        )
    }
}

/// Deep path navigation: one lookup per query change, off the main actor,
/// reused by every projection of that query. The two pieces of state it
/// needs — the resolver and the resolution — are stored on the coordinator
/// itself; everything that reads or refreshes them lives here.
extension SearchCoordinator {
    /// One directory lookup per query change, not one per pass: a resolution
    /// already made for this query under this scope is handed back as it
    /// stands, so re-presenting the panel on an unchanged query is free.
    private nonisolated static func resolvePath(
        reusing previous: CachedPathResolution?,
        query: String,
        rootURL: URL,
        resolver: any PathResolving
    ) async -> CachedPathResolution {
        if let previous, previous.matches(query: query, rootURL: rootURL) { return previous }
        let resolved = await resolver.resolve(query: query, rootURL: rootURL)
        return CachedPathResolution(
            query: query,
            rootURL: rootURL,
            folderRow: resolved?.folderItem
        )
    }

    /// The folder row for `query`, but only when it was resolved for that
    /// query against the scope in force now (ADR 0007). Anything else — a
    /// query the user has moved past, a scope that has since been committed
    /// — projects without a folder row rather than resolving one here.
    private func resolvedFolderRow(for query: String) -> SearchItem? {
        guard let pathResolution, pathResolution.matches(query: query, rootURL: rootURL)
        else {
            return nil
        }
        return pathResolution.folderRow
    }

    /// A scope-relative path resolves against the committed scope (ADR 0007),
    /// so the resolution made under the old root is void and the live query
    /// earns a fresh one. Only the path is re-resolved and republished — the
    /// Search Execution in flight is left alone, so a query that is not
    /// path-like costs nothing here and sees nothing change.
    fileprivate func reresolvePathForCommittedScope() async {
        pathResolution = nil
        let liveQuery = currentQuery
        guard case .local = mode, !liveQuery.isEmpty else { return }
        let scopeRoot = rootURL
        let resolved = await Self.resolvePath(
            reusing: nil,
            query: liveQuery,
            rootURL: scopeRoot,
            resolver: pathResolver
        )
        guard resolved.matches(query: currentQuery, rootURL: rootURL) else { return }
        pathResolution = resolved
        publication = projectLocal(
            candidates: publication.sourceCandidates,
            selectedFilter: selectedFilter,
            selection: publication.selection,
            progress: publication.progress,
            filterContinuity: .preserve
        )
    }
}

extension SearchCoordinator {
    func togglePinSelection() {
        mutateSelectedClipboardEntry { clipboardStore.togglePin(id: $0) }
    }

    func deleteSelection() {
        mutateSelectedClipboardEntry { clipboardStore.delete(id: $0) }
    }

    func clearHistory() {
        clipboardStore.clear()
        if isClipboardMode {
            publishClipboardModeResults()
        }
    }

    /// Whether the selected clipboard row is pinned — the Actions menu
    /// reads it to offer "Pin" or "Unpin".
    var isSelectionPinned: Bool {
        guard isClipboardMode, let selectedItem else { return false }
        return selectedItem.isPinned
    }

    /// The selection's on-disk location, for "Show in Finder".
    var selectionFileURL: URL? {
        selectedItem?.fileURL
    }

    /// Inspector snapshot for the selected Clipboard History entry.
    var clipboardInspector: ClipboardInspector? {
        guard isClipboardMode, let selectedItem, let entryID = clipboardEntryID(from: selectedItem)
        else {
            return nil
        }
        guard let entry = clipboardStore.entry(id: entryID) else { return nil }
        let png = entry.kind == .image ? clipboardStore.imageData(for: entryID)?.png : nil
        return ClipboardInspector.snapshot(for: entry, imagePNG: png)
    }

    fileprivate func publishClipboardModeResults(
        selectedFilter: SearchResultFilter? = nil,
        selection: SearchResultSelection? = nil
    ) {
        searchTask?.cancel()
        searchTask = nil
        publication = SearchResultProjection.project(
            .clipboard(.init(
                query: query.trimmingCharacters(in: .whitespacesAndNewlines),
                entries: clipboardStore.search(query: query),
                selectedFilter: selectedFilter ?? self.selectedFilter,
                selection: selection ?? publication.selection
            ))
        )
    }

    private func mutateSelectedClipboardEntry(_ mutate: (String) -> Void) {
        guard isClipboardMode, let selectedItem, let entryID = clipboardEntryID(from: selectedItem)
        else {
            return
        }
        mutate(entryID)
        publishClipboardModeResults()
    }

    private func clipboardEntryID(from item: SearchItem) -> String? {
        let prefix = "clipboard:"
        guard item.id.hasPrefix(prefix) else { return nil }
        return String(item.id.dropFirst(prefix.count))
    }
}
