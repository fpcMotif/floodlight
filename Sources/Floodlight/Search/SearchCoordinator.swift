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

    var filterOptions: [SearchFilterOption] {
        publication.filterOptions
    }

    /// The engine web mode is scoped to, or `nil` in local mode — what the
    /// search field's token renders.
    var activeWebEngine: KeywordEngine? {
        guard case let .web(context) = mode else { return nil }
        return keywordRegistry.webEngine(id: context.engineID)
    }

    private let sourceSearch: any SourceSearching
    private let assistantRunner: any AssistantProcessRunning
    private let assistantRunSession: AssistantRunSession
    private let actionPerformer: SelectedResultActionPerformer
    private let onDismiss: @MainActor () -> Void
    private var publication: SearchResultPublication
    private var sourceWarmUpComplete = false
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
        rootURL: URL,
        assistantRunner: any AssistantProcessRunning = AssistantProcessRunner(),
        runningApplicationActivator: any RunningApplicationActivating =
            WorkspaceRunningApplicationActivator(),
        actionEffects: any SelectedResultActionEffects = AppKitSelectedResultActionEffects(),
        onDismiss: @escaping @MainActor () -> Void
    ) {
        self.sourceSearch = sourceSearch
        self.rootURL = rootURL
        self.assistantRunner = assistantRunner
        self.onDismiss = onDismiss
        let assistantRunSession = AssistantRunSession(runner: assistantRunner)
        self.assistantRunSession = assistantRunSession
        actionPerformer = SelectedResultActionPerformer(
            effects: actionEffects,
            assistantRunSession: assistantRunSession,
            runningApplicationActivator: runningApplicationActivator,
            recentStore: recentStore,
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
        let fileIndexStorage = indexStorage.appendingPathComponent("FileIndex", isDirectory: true)
        try? fileManager.createDirectory(at: fileIndexStorage, withIntermediateDirectories: true)

        self.init(
            sourceSearch: SourceSearchEngine(
                rootURL: initialRoot,
                storageURL: fileIndexStorage,
                applications: ApplicationCatalog(
                    recentStore: recentStore,
                    deferDiscovery: true
                ),
                settings: SystemCatalog(),
                logFilePath: environment["FLOODLIGHT_FFF_LOG"],
                logLevel: environment["FLOODLIGHT_FFF_LOG_LEVEL"] ?? "info"
            ),
            recentStore: recentStore,
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
        guard case .web = mode else {
            onDismiss()
            return
        }
        applyModeEvent(.escape)
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
        mode = next.mode
        if query != next.query {
            // The observer republishes for the new mode.
            query = next.query
        } else {
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
        guard let selectedItem, selectedItem.isPreviewable else { return nil }
        return selectedItem.fileURL
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
            } catch {
                NSLog("Floodlight search-scope update failed: %@", error.localizedDescription)
            }
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        if case let .web(context) = mode {
            searchTask?.cancel()
            searchTask = nil
            publishWebModeResults(context: context)
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
        searchTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            let snapshots = await sourceSearch.search(requestQuery, immediate: immediate)
            guard !Task.isCancelled else { return }
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
        SearchResultProjection.project(
            .local(.init(
                query: query ?? self.query.trimmingCharacters(in: .whitespacesAndNewlines),
                candidates: candidates,
                keywordRegistry: keywordRegistry,
                selectedFilter: selectedFilter,
                selection: selection,
                progress: progress,
                filterContinuity: filterContinuity
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
