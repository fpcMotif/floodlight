import FloodlightEngine
import Foundation
import Observation

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
    /// Same lifecycle as `activeShortcutDisplayName`, for `.showClipboard`.
    var activeClipboardShortcutDisplayName: String?

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
    /// Clipboard mode's one owner (ADR 0008). The session asks it for the
    /// publication, tells it where the selection moved, and reads the facts
    /// it publishes; the board reads those facts and issues its commands
    /// directly.
    @ObservationIgnored
    let clipboardSearch: ClipboardSearch
    @ObservationIgnored
    private let assistantRunner: any AssistantProcessRunning
    @ObservationIgnored
    private let assistantRunSession: AssistantRunSession
    @ObservationIgnored
    private let actionPerformer: SelectedResultActionPerformer
    @ObservationIgnored
    private let onDismiss: @MainActor () -> Void
    /// The one path resolution the current query paid for, tagged with the
    /// query and the committed scope it belongs to. Every projection of that
    /// query reads it instead of listing directories again.
    @ObservationIgnored
    private var pathCache: PathResolutionCache
    /// Result Publication is the one order results are published in (ADR
    /// 0002). Every change to it is reported to Clipboard Search, which
    /// recomputes what it publishes about the selection on every
    /// republication rather than when a view body happens to ask (#72).
    private var publication: SearchResultPublication {
        didSet { reportSelectionToClipboardSearch() }
    }

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
        clipboardSearch: ClipboardSearch = ClipboardSearch(store: ClipboardHistoryStore.inMemory()),
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
        self.clipboardSearch = clipboardSearch
        self.rootURL = rootURL
        self.assistantRunner = assistantRunner
        pathCache = PathResolutionCache(resolver: pathResolver)
        self.onDismiss = onDismiss
        let assistantRunSession = AssistantRunSession(runner: assistantRunner)
        self.assistantRunSession = assistantRunSession
        actionPerformer = SelectedResultActionPerformer(
            effects: actionEffects,
            assistantRunSession: assistantRunSession,
            runningApplicationActivator: runningApplicationActivator,
            recentStore: recentStore,
            clipboardRestorePayload: { [clipboardSearch] id in
                clipboardSearch.restorePayload(for: id)
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
        // A pin or a delete changes the rows behind the board; the session
        // learns only that history changed and asks for the publication
        // again. Clipboard Search never publishes rows itself (ADR 0002).
        clipboardSearch.historyDidChange = { [weak self] in
            self?.republishClipboardModeResults()
        }
    }

    /// The live wiring: search scope from preferences, index and catalogs over
    /// the real filesystem. Clipboard Search arrives built, over the one
    /// Clipboard History the application shell also hands to Clipboard
    /// Capture. `assistantRunner` is overridable so tests can exercise the
    /// "Ask Codex"/"Ask Claude" seam without spawning a real process or
    /// depending on what's installed on the test machine.
    convenience init(
        clipboardSearch: ClipboardSearch,
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
            clipboardSearch: clipboardSearch,
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
        pathCache = pathCache.cleared()
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

    /// Whether an open board should dismiss instead is presentation's
    /// decision, made above this.
    func showClipboardHistory() {
        applyModeEvent(.clipboardShortcut)
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

    /// Adds the rule, then republishes so the row leaves without re-running
    /// the query. `projectLocal` applies the rule it just wrote.
    func excludeFromSearch(_ item: SearchItem) {
        blocklistStore.block(id: item.id)
        blocklistStore.block(name: item.title)
        publication = projectLocal(
            candidates: publication.sourceCandidates,
            selectedFilter: selectedFilter,
            selection: publication.selection?.id == item.id ? nil : publication.selection,
            progress: publication.progress
        )
    }

    func revealSelection() {
        guard let selectedItem else { return }
        // A clipboard row keeps the path it was copied with even once the
        // file is gone; Clipboard Search says whether Finder can show it.
        if isClipboardMode, clipboardSearch.selectionFileURL == nil { return }
        actionPerformer.reveal(selectedItem)
    }

    func copySelection() {
        guard let item = selectedItem else { return }
        actionPerformer.copy(item)
    }

    /// The previewable file URL of the current selection, or `nil` if the
    /// selection has no file URL or isn't previewable. The shell uses this to
    /// drive QuickLook without re-deriving previewability itself.
    ///
    /// In clipboard mode this is Clipboard Search's preview action, which
    /// *materializes* the temporary file Quick Look reads for a captured
    /// image — so ask `isSelectionPreviewable` to decide whether the
    /// affordance is live, and call this only once the user has actually
    /// pressed Space or Preview. Browsing entries then leaves nothing behind
    /// (#72).
    var previewableSelectionURL: URL? {
        if isClipboardMode {
            return clipboardSearch.materializePreviewURL()
        }
        guard let selectedItem, selectedItem.isPreviewable else { return nil }
        return selectedItem.fileURL
    }

    /// Whether Space has anything to show for the current selection. In
    /// clipboard mode it is the flag Clipboard Search publishes; elsewhere a
    /// row is previewable exactly when it carries a file URL.
    var isSelectionPreviewable: Bool {
        if isClipboardMode {
            return clipboardSearch.isSelectionPreviewable
        }
        return selectedItem?.isPreviewable ?? false
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
            filterContinuity: .preserve,
            folderRow: pathCache.carriedFolderRow(for: requestQuery, rootURL: rootURL)
        )
        let scopeRoot = rootURL
        let previousCache = pathCache
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            // The path lookup and the Source Search pass start together and
            // are both awaited before the first snapshot publishes, so the
            // folder row still lands with the first results — the listings
            // just no longer happen on the main actor, four times over.
            async let resolution = previousCache.resolving(
                query: requestQuery,
                rootURL: scopeRoot
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
                pathCache = resolved
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

    /// `folderRow` overrides what the query tag would derive: `.some` supplies
    /// the row, `nil` derives it. Only the interim publication passes one —
    /// see `scheduleSearch`, where the tag has already moved on.
    private func projectLocal(
        query: String? = nil,
        candidates: [SearchItem],
        selectedFilter: SearchResultFilter,
        selection: SearchResultSelection?,
        progress: SearchResultProgress,
        filterContinuity: SearchResultProjection.FilterContinuity = .reconcileWhenSettled,
        folderRow: SearchItem?? = nil
    ) -> SearchResultPublication {
        // Search sources apply the blocklist to the pages they return, but a
        // pass already in flight when a rule is written was computed without
        // it — and the sources that never consult the blocklist at all have no
        // other gate. Filtering here is what stops either landing an excluded
        // row back on screen.
        let validCandidates = candidates.filter {
            !blocklistStore.isBlocked(name: $0.title, id: $0.id)
        }
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
                resolvedFolderRow: folderRow
                    ?? pathCache.folderRow(for: projectedQuery, rootURL: rootURL)
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

/// Clipboard mode, as the session sees it: ask Clipboard Search for the
/// publication, store it, and tell Clipboard Search where the selection is.
/// Everything that reads or writes Clipboard History lives behind that seam
/// (ADR 0008).
fileprivate extension SearchCoordinator {
    func publishClipboardModeResults(
        selectedFilter: SearchResultFilter? = nil,
        selection: SearchResultSelection? = nil
    ) {
        searchTask?.cancel()
        searchTask = nil
        publication = clipboardSearch.publication(
            query: query,
            selectedFilter: selectedFilter ?? self.selectedFilter,
            selection: selection ?? publication.selection
        )
    }

    /// History changed under the board — a pin or a delete — so the rows are
    /// stale. Outside clipboard mode nothing is showing them.
    func republishClipboardModeResults() {
        guard isClipboardMode else { return }
        publishClipboardModeResults()
    }

    /// Clipboard Search publishes facts about the selected row; this is the
    /// one place it learns which row that is. Outside clipboard mode there is
    /// none, which clears whatever it last published.
    func reportSelectionToClipboardSearch() {
        clipboardSearch.selectionDidMove(to: isClipboardMode ? selectedItem : nil)
    }
}

/// The one operation that is about the coordinator rather than the cache:
/// re-resolving and republishing when the search scope is committed.
fileprivate extension SearchCoordinator {
    /// A scope-relative path resolves against the committed scope (ADR 0007),
    /// so the resolution made under the old root is void and the live query
    /// earns a fresh one. Only the path is re-resolved and republished — the
    /// Search Execution in flight is left alone, so a query that is not
    /// path-like costs nothing here and sees nothing change.
    func reresolvePathForCommittedScope() async {
        pathCache = pathCache.cleared()
        let liveQuery = currentQuery
        guard case .local = mode, !liveQuery.isEmpty else { return }
        let resolved = await pathCache.resolving(query: liveQuery, rootURL: rootURL)
        guard resolved.matches(query: currentQuery, rootURL: rootURL) else { return }
        pathCache = resolved
        publication = projectLocal(
            candidates: publication.sourceCandidates,
            selectedFilter: selectedFilter,
            selection: publication.selection,
            progress: publication.progress,
            filterContinuity: .preserve
        )
    }
}
