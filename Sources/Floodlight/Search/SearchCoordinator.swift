import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class SearchCoordinator {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            if query.isEmpty != oldValue.isEmpty {
                let height = panelHeight
                DispatchQueue.main.async { [weak self] in
                    guard self?.panelHeight == height else { return }
                    self?.onPanelHeightChange?(height)
                }
            }
            guard !isResetting else { return }
            scheduleSearch()
        }
    }
    private(set) var results: [SearchItem] = []
    private(set) var selectedFilter: SearchResultFilter = .all
    var selectedID: SearchItem.ID?
    private(set) var isSearching = false
    private(set) var rootURL: URL
    var focusGeneration = 0

    @ObservationIgnored
    var onDismiss: (() -> Void)?
    @ObservationIgnored
    var onPanelHeightChange: ((CGFloat) -> Void)?

    var panelHeight: CGFloat {
        FloodlightMetrics.panelHeight(hasQuery: !query.isEmpty)
    }

    var filterOptions: [SearchFilterOption] {
        let primary = SearchResultFilter.primary.map(makeFilterOption)
        let dynamic = SearchResultFilter.dynamic.compactMap { filter -> SearchFilterOption? in
            let option = makeFilterOption(filter)
            guard option.count > 0 || selectedFilter == filter else { return nil }
            return option
        }
        return primary + dynamic
    }

    private let index: FFFIndex
    private let applicationCatalog: ApplicationCatalog
    private let recentStore: RecentStore
    private let quickLook = QuickLookController()
    private var allResults: [SearchItem] = []
    private var filterCounts = SearchFilterCounts()
    private var applicationMatchCount = 0
    private var settingsMatchCount = 0
    private var isApplicationCatalogLoading = true
    private var isSettingsCatalogLoading = true
    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var startupTask: Task<Void, Never>?
    @ObservationIgnored
    private var generation = 0
    @ObservationIgnored
    private var isResetting = false

    init() {
        let savedRoot = UserDefaults.standard.string(forKey: "index-root")
        let initialRoot = savedRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let recentStore = RecentStore()

        rootURL = initialRoot
        index = FFFIndex(rootURL: initialRoot)
        self.recentStore = recentStore
        applicationCatalog = ApplicationCatalog(
            recentStore: recentStore,
            deferDiscovery: true
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
            do {
                async let startFiles: Void = index.start()
                async let startApplications: Void = applicationCatalog.start()
                async let startSettings: Void = SystemCatalog.start()

                try await startApplications
                isApplicationCatalogLoading = false
                await startSettings
                isSettingsCatalogLoading = false
                try await startFiles
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
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            scheduleSearch(immediate: true)
        }
    }

    func reset() {
        generation += 1
        searchTask?.cancel()
        searchTask = nil
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
        isSearching = false
        quickLook.close()
    }

    func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let currentIndex = selectedID.flatMap { id in results.firstIndex(where: { $0.id == id }) } ?? 0
        let nextIndex = min(max(currentIndex + delta, 0), results.count - 1)
        selectedID = results[nextIndex].id
    }

    func activate(_ item: SearchItem) {
        selectedID = item.id
        performAction(for: item)
    }

    func selectFilter(_ filter: SearchResultFilter) {
        guard filter != selectedFilter else {
            focusGeneration += 1
            return
        }
        selectedFilter = filter
        applySelectedFilter(resetSelection: true)
        focusGeneration += 1
    }

    func openSelection() {
        guard let item = selectedItem else { return }
        performAction(for: item)
    }

    private func performAction(for item: SearchItem) {
        let selectedQuery = query
        onDismiss?()

        switch item.action {
        case .copy(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        case .open(let url):
            open(url, asApplication: item.kind == .application)
            if item.kind == .file || item.kind == .folder {
                index.track(query: selectedQuery, selectedURL: url)
            } else if item.kind == .application {
                applicationCatalog.track(query: selectedQuery, selectedURL: url)
            }
        }
        recentStore.record(item.id)
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
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func togglePreview() {
        guard let url = selectedItem?.fileURL, selectedItem?.isPreviewable == true else { return }
        quickLook.toggle(url)
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose Floodlight Search Scope"
        panel.message = "FFF will index this folder and keep it updated."
        panel.prompt = "Index Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        changeRoot(to: selectedURL)
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

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Floodlight launch-at-login update failed: %@", error.localizedDescription)
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

    private func changeRoot(to url: URL) {
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

        let immediateAppPage = applicationCatalog.fastSearchPage(requestQuery)
        let settingsPage = SystemCatalog.searchPage(requestQuery, limit: 24)
        let immediateApps = immediateAppPage.items
        applicationMatchCount = immediateAppPage.totalMatched
        settingsMatchCount = settingsPage.totalMatched
        isSearching = true
        publishResults(
            buildResults(
                query: requestQuery,
                indexed: [],
                apps: immediateApps,
                system: settingsPage.items
            ),
            resetSelection: true
        )
        FloodlightPerformance.end("ImmediateSearch", id: immediateSignpost)

        searchTask = Task { [weak self] in
            guard let self else { return }

            if !immediate {
                let debounce = immediateApps.isEmpty ? 35 : 180
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

                let mapped = fffItems.map { item in
                    let kind: SearchItemKind = item.isDirectory ? .folder : .file
                    return SearchItem(
                        id: "\(kind.rawValue):\(item.url.path)",
                        title: item.name,
                        subtitle: item.relativePath,
                        kind: kind,
                        action: .open(item.url),
                        score: item.score,
                        fileURL: item.url,
                        modifiedAt: item.modified > 0
                            ? Date(timeIntervalSince1970: TimeInterval(item.modified))
                            : nil,
                        fileSize: item.isDirectory ? nil : item.size
                    )
                }

                publishResults(
                    buildResults(
                        query: requestQuery,
                        indexed: mapped,
                        apps: immediateApps + apps,
                        system: settingsPage.items
                    )
                )
                FloodlightPerformance.end("IndexedSearch", id: asyncSignpost)
                indexedSearchEnded = true

                try await Task.sleep(for: .milliseconds(120))
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
                        score: 1_000,
                        fileURL: item.url
                    )
                }
                publishResults(
                    buildResults(
                        query: requestQuery,
                        indexed: mapped + content,
                        apps: immediateApps + apps,
                        system: settingsPage.items
                    )
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
                        system: settingsPage.items
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
        return try await applicationCatalog.search(query)
    }

    private func buildResults(
        query: String,
        indexed: [SearchItem],
        apps: [SearchItem],
        system: [SearchItem]
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
                    score: 100_000
                )
            )
        }

        output.append(contentsOf: apps)
        output.append(contentsOf: system)
        output.append(contentsOf: indexed)

        var seen = Set<String>()
        output = output
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.score > rhs.score
            }

        if !query.isEmpty,
           let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
           let url = URL(string: "https://www.google.com/search?q=\(encoded)") {
            output.append(
                SearchItem(
                    id: "web-search",
                    title: "Search the Web for “\(query)”",
                    subtitle: "Open in your default browser",
                    kind: .web,
                    action: .open(url),
                    score: Int.min
                )
            )
        }

        return Array(output.prefix(80))
    }

    private func publishResults(
        _ newResults: [SearchItem],
        resetSelection: Bool = false
    ) {
        allResults = newResults
        filterCounts = SearchFilterCounts(items: newResults)
        applySelectedFilter(resetSelection: resetSelection)
    }

    private func applySelectedFilter(resetSelection: Bool) {
        let previousSelection = selectedID
        results = allResults.filter(selectedFilter.includes)

        if resetSelection
            || previousSelection == nil
            || !results.contains(where: { $0.id == previousSelection }) {
            selectedID = results.first?.id
        }
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
}
