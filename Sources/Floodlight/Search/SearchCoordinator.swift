import AppKit
import FloodlightEngine
import Foundation
import Observation

@MainActor
@Observable
final class SearchCoordinator {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            cancelAssistantRun()
            selectionWasUserDriven = false
            guard !isResetting else { return }
            if case .local = mode,
               !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                refreshApplicationsIfNeeded()
                refreshSettingsIfNeeded()
            }
            scheduleSearch()
        }
    }
    /// Local fuzzy search, or web mode scoped to one engine (entered with
    /// Tab, shown as the field's token). All transitions run through
    /// `SearchMode.transition` — this only publishes what it decides.
    private(set) var mode: SearchMode = .local
    private(set) var results: [SearchItem] = []
    private(set) var selectedFilter: SearchResultFilter = .all
    var selectedID: SearchItem.ID?
    private(set) var isSearching = false
    private(set) var rootURL: URL
    var focusGeneration = 0
    /// The in-flight or completed state of the last "Ask Codex"/"Ask
    /// Claude" the user triggered, or `nil` if none is active.
    private(set) var assistantRun: AssistantRun?
    /// The actually-registered summon shortcut ("⌘ Space"), set by
    /// `AppDelegate` once it knows whether the preferred combo registered
    /// or Carbon fell back to the alternate one — `nil` until then, or if
    /// registration failed outright. The idle capsule's hotkey chip reads
    /// this directly rather than re-deriving a preference that might not
    /// match what's actually active.
    var activeShortcutDisplayName: String?

    @ObservationIgnored
    var onDismiss: (() -> Void)?
    @ObservationIgnored
    var onShowSettings: (() -> Void)?

    var filterOptions: [SearchFilterOption] {
        // Local-only controls: suppressed while web mode is active, restored
        // — selection included — as soon as the mode exits.
        guard case .local = mode else { return [] }
        let primary = SearchResultFilter.primary.map(makeFilterOption)
        let dynamic = SearchResultFilter.dynamic.compactMap { filter -> SearchFilterOption? in
            let option = makeFilterOption(filter)
            guard option.count > 0 || selectedFilter == filter else { return nil }
            return option
        }
        return primary + dynamic
    }

    /// The engine web mode is scoped to, or `nil` in local mode — what the
    /// search field's token renders.
    var activeWebEngine: KeywordEngine? {
        guard case .web(let context) = mode else { return nil }
        return KeywordEngineCatalog.webSearchEngines.first { $0.id == context.engineID }
    }

    private let index: FFFIndex
    private let applicationCatalog: any Catalog
    private let settingsCatalog: any Catalog
    private let recentStore: RecentStore
    private let assistantRunner: any AssistantProcessRunning
    private var allResults: [SearchItem] = []
    private var filterCounts = SearchFilterCounts()
    private var applicationMatchCount = 0
    private var settingsMatchCount = 0
    private var isApplicationCatalogLoading = true
    private var isSettingsCatalogLoading = true
    /// Assistant engines ("Ask Codex", "Ask Claude") only ever appear once
    /// their binary is confirmed runnable at startup; web-search engines
    /// (Twitter/X, YouTube) don't need that check and are always included.
    private var availableKeywordEngines: [KeywordEngine] = KeywordEngineCatalog.all.filter { $0.kind != .assistant }
    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var startupTask: Task<Void, Never>?
    @ObservationIgnored
    private var applicationRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var settingsRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var assistantTask: Task<Void, Never>?
    @ObservationIgnored
    private var generation = 0
    @ObservationIgnored
    private var isResetting = false
    @ObservationIgnored
    private var selectionWasUserDriven = false

    /// Builds a coordinator over already-constructed sources.
    ///
    /// Every dependency arrives here, so a test can hand in in-memory catalogs
    /// and assert on `results` through the same interface the panel uses,
    /// instead of reaching past it for a pure helper.
    init(
        index: FFFIndex,
        applicationCatalog: any Catalog,
        settingsCatalog: any Catalog,
        recentStore: RecentStore,
        rootURL: URL,
        assistantRunner: any AssistantProcessRunning = AssistantProcessRunner()
    ) {
        self.index = index
        self.applicationCatalog = applicationCatalog
        self.settingsCatalog = settingsCatalog
        self.recentStore = recentStore
        self.rootURL = rootURL
        self.assistantRunner = assistantRunner
    }

    /// The live wiring: search scope from preferences, index and catalogs over
    /// the real filesystem. `assistantRunner` is overridable so tests can
    /// exercise the "Ask Codex"/"Ask Claude" seam without spawning a real
    /// process or depending on what's installed on the test machine.
    convenience init(assistantRunner: any AssistantProcessRunning = AssistantProcessRunner()) {
        let fileManager = FileManager.default
        let savedRoot = UserDefaults.standard.string(forKey: "index-root")
        let initialRoot = savedRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
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

        self.init(
            index: FFFIndex(
                rootURL: initialRoot,
                storageURL: indexStorage,
                logFilePath: environment["FLOODLIGHT_FFF_LOG"],
                logLevel: environment["FLOODLIGHT_FFF_LOG_LEVEL"] ?? "info"
            ),
            applicationCatalog: ApplicationCatalog(
                recentStore: recentStore,
                deferDiscovery: true
            ),
            settingsCatalog: SystemCatalog(),
            recentStore: recentStore,
            rootURL: initialRoot,
            assistantRunner: assistantRunner
        )
    }

    deinit {
        searchTask?.cancel()
        startupTask?.cancel()
        applicationRefreshTask?.cancel()
        settingsRefreshTask?.cancel()
        assistantTask?.cancel()
    }

    func start() {
        guard startupTask == nil else { return }
        startupTask = Task { [weak self] in
            guard let self else { return }
            let signpost = FloodlightPerformance.begin("IndexStartup")
            defer {
                FloodlightPerformance.end("IndexStartup", id: signpost)
            }
            do {
                async let startFiles: Void = index.start()
                async let startApplications: Void = applicationCatalog.start()
                async let startSettings: Void = settingsCatalog.start()
                async let resolvedKeywordEngines = KeywordEngineCatalog.availableEngines(runner: assistantRunner)

                try await startApplications
                isApplicationCatalogLoading = false
                try await startSettings
                isSettingsCatalogLoading = false
                try await startFiles
                availableKeywordEngines = await resolvedKeywordEngines
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch(immediate: true)
                }
            } catch is CancellationError {
                return
            } catch {
                isApplicationCatalogLoading = false
                isSettingsCatalogLoading = false
                NSLog("Floodlight index startup failed: %@", error.localizedDescription)
            }
        }
    }

    func prepareForPresentation() {
        focusGeneration += 1
        refreshApplicationsIfNeeded()
        refreshSettingsIfNeeded()
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch(immediate: true)
        }
    }

    private func refreshApplicationsIfNeeded() {
        refreshCatalogIfNeeded(
            isLoading: isApplicationCatalogLoading,
            task: \.applicationRefreshTask,
            label: "application-catalog"
        ) { coordinator in
            try await coordinator.applicationCatalog.refreshIfNeeded()
        }
    }

    private func refreshSettingsIfNeeded() {
        refreshCatalogIfNeeded(
            isLoading: isSettingsCatalogLoading,
            task: \.settingsRefreshTask,
            label: "settings-catalog"
        ) { coordinator in
            try await coordinator.settingsCatalog.refreshIfNeeded()
        }
    }

    /// Runs `refresh` at most once at a time per catalog, re-searching whenever
    /// the catalog reports a change. A catalog still loading its initial
    /// contents, or one whose refresh is already in flight, is left alone.
    private func refreshCatalogIfNeeded(
        isLoading: Bool,
        task: ReferenceWritableKeyPath<SearchCoordinator, Task<Void, Never>?>,
        label: String,
        refresh: @escaping (SearchCoordinator) async throws -> Bool
    ) {
        guard !isLoading, self[keyPath: task] == nil else { return }
        self[keyPath: task] = Task { [weak self] in
            guard let self else { return }
            defer { self[keyPath: task] = nil }

            do {
                let changed = try await refresh(self)
                guard changed else { return }
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch(immediate: true)
                }
            } catch is CancellationError {
                return
            } catch {
                NSLog("Floodlight %@ refresh failed: %@", label, error.localizedDescription)
            }
        }
    }

    func reset() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        mode = .local
        isResetting = true
        query = ""
        isResetting = false
        allResults = []
        filterCounts = SearchFilterCounts()
        results = []
        selectedFilter = .all
        applicationMatchCount = 0
        settingsMatchCount = 0
        selectedID = nil
        selectionWasUserDriven = false
        isSearching = false
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
            onDismiss?()
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
            let match = KeywordEngineCatalog.match(query, in: availableKeywordEngines),
            case .webSearch = match.engine.destination,
            item.id == match.engine.rowID
        else {
            return nil
        }
        return match.engine.title
    }

    private func applyModeEvent(_ event: SearchModeEvent) {
        let next = SearchMode.transition(from: mode, query: query, event: event)
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
        let currentIndex = selectedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), results.count - 1)
        selectedID = results[nextIndex].id
        selectionWasUserDriven = true
    }

    func activate(_ item: SearchItem) {
        select(item)
        guard webModeReturnIsArmed else { return }
        performAction(for: item)
    }

    func select(_ item: SearchItem) {
        selectedID = item.id
        selectionWasUserDriven = true
    }

    func selectFilter(_ filter: SearchResultFilter) {
        selectionWasUserDriven = true
        guard filter != selectedFilter else {
            focusGeneration += 1
            return
        }
        selectedFilter = filter
        applySelectedFilter(resetSelection: true)
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
        let selectedQuery = query

        switch item.action {
        case .copy(let value):
            onDismiss?()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        case .open(let url):
            onDismiss?()
            open(url, asApplication: item.kind == .application)
            if item.kind == .file || item.kind == .folder {
                index.track(query: selectedQuery, selectedURL: url)
            } else if item.kind == .application {
                applicationCatalog.track(query: selectedQuery, selectedURL: url)
            }
        case .showFloodlightSettings:
            onDismiss?()
            onShowSettings?()
        case .askAssistant(let command, let arguments):
            // Keeps the panel open through a running/answered/failed cycle
            // instead of the eager dismiss-then-act every other action uses.
            runAssistant(command: command, arguments: arguments, for: item)
        }
        recentStore.record(item.id)
    }

    /// Runs an assistant engine's CLI and publishes its lifecycle to
    /// `assistantRun`. Never fires on a keystroke — only an explicit
    /// selection (Return or double-click) reaches this.
    private func runAssistant(command: String, arguments: [String], for item: SearchItem) {
        cancelAssistantRun()
        assistantRun = AssistantRun(itemID: item.id, state: .running)

        let runner = assistantRunner
        assistantTask = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await runner.run(command: command, arguments: arguments)
                guard !Task.isCancelled, assistantRun?.itemID == item.id else { return }
                assistantRun = AssistantRun(itemID: item.id, state: .answered(output))
            } catch is CancellationError {
                return
            } catch AssistantProcessError.executableNotFound(let missingCommand) {
                guard !Task.isCancelled, assistantRun?.itemID == item.id else { return }
                assistantRun = AssistantRun(itemID: item.id, state: .failed("\(missingCommand) isn't installed."))
            } catch AssistantProcessError.timedOut {
                guard !Task.isCancelled, assistantRun?.itemID == item.id else { return }
                assistantRun = AssistantRun(itemID: item.id, state: .failed("That ask took too long and was stopped."))
            } catch AssistantProcessError.nonZeroExit(_, let message) where !message.isEmpty {
                guard !Task.isCancelled, assistantRun?.itemID == item.id else { return }
                assistantRun = AssistantRun(itemID: item.id, state: .failed(message))
            } catch {
                guard !Task.isCancelled, assistantRun?.itemID == item.id else { return }
                assistantRun = AssistantRun(itemID: item.id, state: .failed("That ask failed."))
            }
        }
    }

    /// Cancels any in-flight ask (which terminates its subprocess) and
    /// clears whatever answer is currently displayed. Called whenever the
    /// query changes, so a stale answer never lingers under a new query.
    private func cancelAssistantRun() {
        assistantTask?.cancel()
        assistantTask = nil
        assistantRun = nil
    }

    func revealSelection() {
        guard let url = selectedItem?.fileURL else { return }
        onDismiss?()
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func copySelection() {
        guard let item = selectedItem else { return }
        let value: String
        switch item.action {
        case .copy(let text):
            value = text
        case .open(let url):
            value = url.isFileURL ? url.path : url.absoluteString
        case .showFloodlightSettings:
            value = item.title
        case .askAssistant:
            if let assistantRun, assistantRun.itemID == item.id, case .answered(let text) = assistantRun.state {
                value = text
            } else {
                value = item.title
            }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
        guard assistantRun?.itemID == item.id else { return nil }
        return assistantRun?.state
    }

    func rebuildIndex() {
        Task {
            do {
                try await index.rescan()
            } catch {
                NSLog("Floodlight index rebuild failed: %@", error.localizedDescription)
            }
        }
    }

    private var selectedItem: SearchItem? {
        guard let selectedID else { return results.first }
        return results.first { $0.id == selectedID }
    }

    private func open(_ url: URL, asApplication: Bool) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let signpost = FloodlightPerformance.begin("OpenSelection")

        if asApplication {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: configuration,
                completionHandler: { _, _ in
                    FloodlightPerformance.end("OpenSelection", id: signpost)
                }
            )
        } else {
            NSWorkspace.shared.open(
                url,
                configuration: configuration,
                completionHandler: { _, _ in
                    FloodlightPerformance.end("OpenSelection", id: signpost)
                }
            )
        }
    }

    func changeRoot(to url: URL) {
        Task {
            do {
                try await index.changeRoot(to: url)
                rootURL = url.standardizedFileURL
                UserDefaults.standard.set(rootURL.path, forKey: "index-root")
                scheduleSearch(immediate: true)
            } catch {
                NSLog("Floodlight search-scope update failed: %@", error.localizedDescription)
            }
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        if case .web(let context) = mode {
            publishWebModeResults(context: context)
            return
        }

        let immediateSignpost = FloodlightPerformance.begin("ImmediateSearch")
        generation += 1
        let requestGeneration = generation
        let requestQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !requestQuery.isEmpty else {
            allResults = []
            filterCounts = SearchFilterCounts()
            results = []
            selectedFilter = .all
            applicationMatchCount = 0
            settingsMatchCount = 0
            selectedID = nil
            isSearching = false
            FloodlightPerformance.end("ImmediateSearch", id: immediateSignpost)
            return
        }

        let immediateAppPage = applicationCatalog.immediatePage(for: requestQuery, limit: 12)
        let settingsPage = settingsCatalog.immediatePage(for: requestQuery, limit: 24)
        let immediateApps = immediateAppPage.items
        applicationMatchCount = immediateAppPage.totalMatched
        settingsMatchCount = settingsPage.totalMatched
        isSearching = true
        publishResults(
            buildResults(
                query: requestQuery,
                indexed: [],
                apps: immediateApps,
                system: settingsPage.items,
                keywordEngines: availableKeywordEngines
            ),
            resetSelection: true
        )
        FloodlightPerformance.end("ImmediateSearch", id: immediateSignpost)

        searchTask = Task { [weak self] in
            guard let self else { return }

            if !immediate {
                let debounce = immediateApps.isEmpty ? 15 : 20
                try? await Task.sleep(for: .milliseconds(debounce))
            }
            guard !Task.isCancelled else { return }

            let asyncSignpost = FloodlightPerformance.begin("IndexedSearch")
            var indexedSearchEnded = false
            defer {
                if !indexedSearchEnded {
                    FloodlightPerformance.end("IndexedSearch", id: asyncSignpost)
                }
                if requestGeneration == generation {
                    isSearching = false
                    reconcileSelectedFilter()
                }
            }

            do {
                async let indexed = searchIndexedFiles(requestQuery)
                async let applications = searchIndexedApplications(requestQuery)
                let fffItems = try await indexed
                let apps = try await applications
                guard !Task.isCancelled, requestGeneration == generation else { return }

                let mapped = fffItems.map { $0.makeSearchItem() }

                publishResults(
                    buildResults(
                        query: requestQuery,
                        indexed: mapped,
                        apps: immediateApps + apps,
                        system: settingsPage.items,
                        keywordEngines: availableKeywordEngines
                    ),
                    promoteWebFallback: true
                )
                FloodlightPerformance.end("IndexedSearch", id: asyncSignpost)
                indexedSearchEnded = true

                try await Task.sleep(for: .milliseconds(30))
                guard !Task.isCancelled, requestGeneration == generation else { return }
                guard requestQuery.count >= 3, fffItems.count < 12 else { return }
                let contentSignpost = FloodlightPerformance.begin("ContentSearch")
                defer {
                    FloodlightPerformance.end("ContentSearch", id: contentSignpost)
                }
                let contentItems = try await index.searchContent(requestQuery)
                guard
                    !Task.isCancelled,
                    requestGeneration == generation,
                    !contentItems.isEmpty
                else {
                    return
                }
                let content = contentItems.map { item in
                    SearchItem(
                        id: "content:\(item.url.path):\(item.line)",
                        title: item.name,
                        subtitle: "\(item.relativePath):\(item.line) · \(item.snippet)",
                        kind: .file,
                        action: .open(item.url),
                        score: SearchItemRanking.content,
                        fileURL: item.url
                    )
                }
                publishResults(
                    buildResults(
                        query: requestQuery,
                        indexed: mapped + content,
                        apps: immediateApps + apps,
                        system: settingsPage.items,
                        keywordEngines: availableKeywordEngines
                    ),
                    promoteWebFallback: true
                )
            } catch is CancellationError {
                return
            } catch {
                guard requestGeneration == generation else { return }
                NSLog("Floodlight indexed search failed: %@", error.localizedDescription)
                publishResults(
                    buildResults(
                        query: requestQuery,
                        indexed: [],
                        apps: immediateApps,
                        system: settingsPage.items,
                        keywordEngines: availableKeywordEngines
                    )
                )
            }
        }
    }

    private func searchIndexedFiles(_ query: String) async throws -> [IndexedSearchItem] {
        let signpost = FloodlightPerformance.begin("FileIndexSearch")
        defer {
            FloodlightPerformance.end("FileIndexSearch", id: signpost)
        }
        return try await index.search(query)
    }

    private func searchIndexedApplications(_ query: String) async throws -> [SearchItem] {
        let signpost = FloodlightPerformance.begin("ApplicationIndexSearch")
        defer {
            FloodlightPerformance.end("ApplicationIndexSearch", id: signpost)
        }
        return try await applicationCatalog.indexedItems(for: query, limit: 12)
    }

    /// The whole list while web mode is active: one row per preset URL
    /// engine, nothing else. The local passes stay paused — no catalog or
    /// index is touched — and any in-flight pass is cancelled so it can't
    /// land its results over the engine rows.
    private func publishWebModeResults(context: SearchMode.WebContext) {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false

        let rows = Self.webModeResults(
            query: query.trimmingCharacters(in: .whitespacesAndNewlines),
            activeEngineID: context.engineID
        )
        allResults = rows
        filterCounts = SearchFilterCounts()
        results = rows
        // Row identity is the engine, so an engine the user arrowed to stays
        // selected while they keep typing; on entry the active engine leads.
        if !rows.contains(where: { $0.id == selectedID }) {
            selectedID = rows.first?.id
        }
    }

    /// One "Search <Engine> for “<query>”" row per preset URL engine —
    /// active engine first, the rest in table order, positioned within the
    /// keyword-engine score band. Titles and URLs track the live query;
    /// nothing here performs I/O.
    static func webModeResults(
        query: String,
        activeEngineID: String,
        engines: [KeywordEngine] = KeywordEngineCatalog.webSearchEngines
    ) -> [SearchItem] {
        let ordered = engines.filter { $0.id == activeEngineID }
            + engines.filter { $0.id != activeEngineID }

        return ordered.enumerated().compactMap { position, engine in
            guard let url = engine.searchURL(for: query), let title = engine.searchTitle(for: query) else {
                return nil
            }
            return SearchItem(
                id: "web-mode:\(engine.id)",
                title: title,
                subtitle: "Open in your default browser",
                kind: .web,
                action: .open(url),
                score: SearchItemRanking.keywordEngine - position
            )
        }
    }

    func buildResults(
        query: String,
        indexed: [SearchItem],
        apps: [SearchItem],
        system: [SearchItem],
        keywordEngines: [KeywordEngine] = KeywordEngineCatalog.all
    ) -> [SearchItem] {
        var output: [SearchItem] = []

        if let value = Calculator.evaluate(query) {
            let answer = Calculator.format(value)
            output.append(
                SearchItem(
                    id: "calculator",
                    title: answer,
                    subtitle: "\(query) = \(answer) · Press Return to copy",
                    kind: .calculator,
                    action: .copy(answer),
                    score: SearchItemRanking.calculator
                )
            )
        }

        output.append(contentsOf: FloodlightCommandCatalog.search(query))
        output.append(contentsOf: KeywordEngineCatalog.search(query, in: keywordEngines))
        output.append(contentsOf: apps)
        output.append(contentsOf: system)
        output.append(contentsOf: indexed)

        // The fallback row is the table's default engine wearing its stable
        // "web-search" identity — reached by promotion here, the same
        // destination Tab's plain-query mode addresses deliberately.
        let defaultEngine = KeywordEngineCatalog.defaultEngine
        if !query.isEmpty,
           let url = defaultEngine.searchURL(for: query),
           let title = defaultEngine.searchTitle(for: query) {
            let localMatchCount = apps.count + system.count + indexed.count
            let promoted = WebSearchIntent.shouldPromote(
                query: query,
                localMatchCount: localMatchCount
            )
            output.append(
                SearchItem(
                    id: Self.webSearchResultID,
                    title: title,
                    subtitle: "Open in your default browser",
                    kind: .web,
                    action: .open(url),
                    score: promoted ? SearchItemRanking.webPromoted : SearchItemRanking.webFallback
                )
            )
        }

        var seen = Set<String>()
        output = SearchItemRanking.ranked(output.filter { seen.insert($0.id).inserted })

        return Array(output.prefix(80))
    }

    private func publishResults(
        _ newResults: [SearchItem],
        resetSelection: Bool = false,
        promoteWebFallback: Bool = false
    ) {
        allResults = newResults
        filterCounts = SearchFilterCounts(items: newResults)
        applySelectedFilter(
            resetSelection: resetSelection,
            promoteWebFallback: promoteWebFallback
        )
    }

    func applySelectedFilter(
        resetSelection: Bool,
        promoteWebFallback: Bool = false
    ) {
        let previousSelection = selectedID
        results = allResults.filter(selectedFilter.includes)
        selectedID = Self.reconciledSelectionID(
            previousSelection: previousSelection,
            results: results,
            resetSelection: resetSelection,
            promoteWebFallback: promoteWebFallback && !selectionWasUserDriven
        )
    }

    static func reconciledSelectionID(
        previousSelection: SearchItem.ID?,
        results: [SearchItem],
        resetSelection: Bool,
        promoteWebFallback: Bool
    ) -> SearchItem.ID? {
        guard let first = results.first else { return nil }
        if resetSelection {
            return first.id
        }
        if promoteWebFallback,
           previousSelection == webSearchResultID,
           first.id != webSearchResultID {
            return first.id
        }
        if let previousSelection,
           results.contains(where: { $0.id == previousSelection }) {
            return previousSelection
        }
        return first.id
    }

    private func reconcileSelectedFilter() {
        guard selectedFilter.isDynamic else { return }
        let option = makeFilterOption(selectedFilter)
        guard option.count == 0, !option.isLoading else { return }
        selectedFilter = .all
        applySelectedFilter(resetSelection: true)
    }

    private func makeFilterOption(_ filter: SearchResultFilter) -> SearchFilterOption {
        let visibleCount = filterCounts[filter]
        let count: Int
        switch filter {
        case .applications:
            count = max(applicationMatchCount, visibleCount)
        case .settings:
            count = max(settingsMatchCount, visibleCount)
        case .all, .files, .folders, .pdfs, .images, .documents:
            count = visibleCount
        }

        let isLoading: Bool
        switch filter {
        case .all:
            isLoading = isSearching
                || isApplicationCatalogLoading
                || isSettingsCatalogLoading
        case .applications:
            isLoading = isApplicationCatalogLoading
        case .files, .folders, .pdfs, .images, .documents:
            isLoading = isSearching
        case .settings:
            isLoading = isSettingsCatalogLoading
        }

        return SearchFilterOption(
            filter: filter,
            count: count,
            isLoading: isLoading
        )
    }

    private static let webSearchResultID = "web-search"
}
