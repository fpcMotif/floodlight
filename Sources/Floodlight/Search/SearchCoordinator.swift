import AppKit
import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class SearchCoordinator {
    enum State: Equatable {
        case error(String)
        case indexing(UInt64)
        case ready(UInt64)
        case starting

        var label: String {
            switch self {
            case .error(let message):
                message
            case .indexing(let count):
                "Indexing \(count.formatted()) items…"
            case .ready(let count):
                "\(count.formatted()) items indexed"
            case .starting:
                "Starting FFF index…"
            }
        }
    }

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
    var selectedID: SearchItem.ID?
    private(set) var state: State = .starting
    private(set) var isSearching = false
    private(set) var shortcutLabel = "⌘Space"
    private(set) var rootURL: URL
    private(set) var launchAtLoginEnabled = false
    var focusGeneration = 0

    @ObservationIgnored
    var onDismiss: (() -> Void)?
    @ObservationIgnored
    var onPanelHeightChange: ((CGFloat) -> Void)?

    var panelHeight: CGFloat {
        FloodlightMetrics.panelHeight(hasQuery: !query.isEmpty)
    }

    private let index: FFFIndex
    private let applicationCatalog: ApplicationCatalog
    private let recentStore: RecentStore
    private let quickLook = QuickLookController()
    @ObservationIgnored
    private var searchTask: Task<Void, Never>?
    @ObservationIgnored
    private var progressTask: Task<Void, Never>?
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
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    deinit {
        searchTask?.cancel()
        progressTask?.cancel()
    }

    func start() {
        guard progressTask == nil else { return }
        state = .starting
        progressTask = Task { [weak self] in
            guard let self else { return }
            let signpost = FloodlightPerformance.begin("IndexStartup")
            do {
                async let startFiles: Void = index.start()
                async let startApplications: Void = applicationCatalog.start()
                try await startFiles
                try await startApplications
                FloodlightPerformance.end("IndexStartup", id: signpost)
                await refreshProgress()
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    scheduleSearch(immediate: true)
                }

                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(350))
                    await refreshProgress()
                }
            } catch is CancellationError {
                FloodlightPerformance.end("IndexStartup", id: signpost)
                return
            } catch {
                FloodlightPerformance.end("IndexStartup", id: signpost)
                state = .error(error.localizedDescription)
            }
        }
    }

    func setShortcutLabel(_ label: String) {
        shortcutLabel = label
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
        results = []
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

    func select(_ item: SearchItem) {
        selectedID = item.id
    }

    func openSelection() {
        guard let item = selectedItem else { return }
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
        state = .indexing(0)
        Task {
            do {
                try await index.rescan()
            } catch {
                state = .error(error.localizedDescription)
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
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            state = .error("Launch at login: \(error.localizedDescription)")
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
        state = .starting
        Task {
            do {
                try await index.changeRoot(to: url)
                rootURL = url.standardizedFileURL
                UserDefaults.standard.set(rootURL.path, forKey: "index-root")
                scheduleSearch(immediate: true)
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    private func refreshProgress() async {
        do {
            let progress = try await index.progress()
            let newState: State = progress.isScanning
                ? .indexing(progress.scannedFiles)
                : .ready(progress.scannedFiles)
            if newState != state {
                state = newState
            }
        } catch {
            let newState = State.error(error.localizedDescription)
            if newState != state {
                state = newState
            }
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        let immediateSignpost = FloodlightPerformance.begin("ImmediateSearch")
        generation += 1
        let requestGeneration = generation
        let requestQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let immediateApps = applicationCatalog.fastSearch(requestQuery)
        searchTask?.cancel()

        results = buildResults(query: requestQuery, indexed: [], apps: immediateApps)
        selectedID = results.first?.id
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
            isSearching = true
            defer {
                if !indexedSearchEnded {
                    FloodlightPerformance.end("IndexedSearch", id: asyncSignpost)
                }
                if requestGeneration == generation {
                    isSearching = false
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

                results = buildResults(
                    query: requestQuery,
                    indexed: mapped,
                    apps: immediateApps + apps
                )
                selectedID = results.first?.id
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
                results = buildResults(
                    query: requestQuery,
                    indexed: mapped + content,
                    apps: immediateApps + apps
                )
                selectedID = results.first?.id
            } catch {
                guard requestGeneration == generation else { return }
                state = .error(error.localizedDescription)
                results = buildResults(
                    query: requestQuery,
                    indexed: [],
                    apps: immediateApps
                )
                selectedID = results.first?.id
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
        apps: [SearchItem]
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
        output.append(contentsOf: SystemCatalog.search(query))
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
}
