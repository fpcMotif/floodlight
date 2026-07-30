import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class SearchCoordinator: ObservableObject {
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

    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            scheduleSearch()
        }
    }
    @Published private(set) var results: [SearchItem] = []
    @Published var selectedID: SearchItem.ID?
    @Published private(set) var state: State = .starting
    @Published private(set) var isSearching = false
    @Published private(set) var shortcutLabel = "⌘Space"
    @Published private(set) var rootURL: URL
    @Published private(set) var launchAtLoginEnabled = false
    @Published var focusGeneration = 0

    var onDismiss: (() -> Void)?

    var panelHeight: CGFloat {
        guard !query.isEmpty else { return 72 }
        let visibleRows = max(1, min(results.count, 7))
        return min(500, 86 + CGFloat(visibleRows * 58))
    }

    private let index: FFFIndex
    private let applicationCatalog: ApplicationCatalog
    private let recentStore: RecentStore
    private let quickLook = QuickLookController()
    private var searchTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var generation = 0

    init() {
        let savedRoot = UserDefaults.standard.string(forKey: "index-root")
        let initialRoot = savedRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let recentStore = RecentStore()

        rootURL = initialRoot
        index = FFFIndex(rootURL: initialRoot)
        self.recentStore = recentStore
        applicationCatalog = ApplicationCatalog(recentStore: recentStore)
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
            do {
                async let startFiles: Void = index.start()
                async let startApplications: Void = applicationCatalog.start()
                try await startFiles
                try await startApplications
                await refreshProgress()
                scheduleSearch(immediate: true)

                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(350))
                    await refreshProgress()
                }
            } catch is CancellationError {
                return
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    func setShortcutLabel(_ label: String) {
        shortcutLabel = label
    }

    func prepareForPresentation() {
        focusGeneration += 1
        scheduleSearch(immediate: true)
    }

    func reset() {
        query = ""
        results = []
        selectedID = nil
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
        recentStore.record(item.id)

        switch item.action {
        case .copy(let value):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        case .open(let url):
            NSWorkspace.shared.open(url)
            if item.kind == .file || item.kind == .folder {
                index.track(query: query, selectedURL: url)
            } else if item.kind == .application {
                applicationCatalog.track(query: query, selectedURL: url)
            }
        }
        onDismiss?()
    }

    func revealSelection() {
        guard let url = selectedItem?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        onDismiss?()
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
            state = progress.isScanning
                ? .indexing(progress.scannedFiles)
                : .ready(progress.scannedFiles)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        generation += 1
        let requestGeneration = generation
        let requestQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }

            if !immediate {
                try? await Task.sleep(for: .milliseconds(35))
            }
            guard !Task.isCancelled else { return }

            isSearching = true
            defer {
                if requestGeneration == generation {
                    isSearching = false
                }
            }

            do {
                async let indexed = index.search(requestQuery)
                async let applications = applicationCatalog.search(requestQuery)
                let fffItems = try await indexed
                let apps = try await applications
                let contentItems: [IndexedContentItem]
                if requestQuery.count >= 3, fffItems.count < 12 {
                    contentItems = try await index.searchContent(requestQuery)
                } else {
                    contentItems = []
                }
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
                    apps: apps
                )
                selectedID = results.first?.id
            } catch {
                guard requestGeneration == generation else { return }
                state = .error(error.localizedDescription)
                results = buildResults(query: requestQuery, indexed: [], apps: [])
                selectedID = results.first?.id
            }
        }
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
                    id: "calculator:\(query)",
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
                    id: "web:\(query)",
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
