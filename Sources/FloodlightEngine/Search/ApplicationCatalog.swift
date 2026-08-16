import Foundation

package final class ApplicationCatalog: Catalog, @unchecked Sendable {
    private struct Application: Sendable {
        let name: String
        let url: URL
        let markerName: String
        let id: String
        let subtitle: String
        let normalizedName: String
    }

    private let lock = NSLock()
    private let discoveryQueue = DispatchQueue(
        label: "com.floodlight.application-catalog",
        qos: .userInitiated
    )
    private var applications: [Application] = []
    private var applicationsByMarker: [String: Application] = [:]
    private var markerByApplicationPath: [String: String] = [:]
    private var isPrepared = false
    private let refreshGuard = CatalogRefreshGuard()
    private var applicationDirectoryFingerprint: [String: Date] = [:]
    private let markerRoot: URL
    private let index: FFFIndex
    private let recentStore: RecentStore
    private let discoveryProvider: @Sendable () -> [(name: String, url: URL)]

    package init(
        recentStore: RecentStore,
        supportURL: URL? = nil,
        deferDiscovery: Bool = false,
        discoveryProvider: @escaping @Sendable () -> [(name: String, url: URL)] = {
            ApplicationCatalog.discoverApplications()
        }
    ) {
        self.recentStore = recentStore
        self.discoveryProvider = discoveryProvider

        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let defaultSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Floodlight", isDirectory: true))
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "Floodlight",
                isDirectory: true
            )
        let appIndexRoot = (supportURL ?? defaultSupport)
            .appendingPathComponent("ApplicationIndex", isDirectory: true)
        markerRoot = appIndexRoot.appendingPathComponent("Items", isDirectory: true)

        index = FFFIndex(
            rootURL: markerRoot,
            storageURL: appIndexRoot.appendingPathComponent("Database", isDirectory: true),
            enableContentIndexing: false,
            includeBinaryFiles: false,
            watch: false,
            logFilePath: environment["FLOODLIGHT_FFF_LOG"],
            logLevel: environment["FLOODLIGHT_FFF_LOG_LEVEL"] ?? "info"
        )
        if !deferDiscovery {
            prepare(fileManager: fileManager)
        }
    }

    /// Refreshes the standard application catalog without blocking the caller.
    ///
    /// Discovery runs on the catalog's serial background queue. The common case
    /// (nothing was installed or removed) only checks application-directory
    /// modification dates; a full walk, marker synchronization, and the
    /// secondary FFF rescan happen only after a directory changes.
    package func refreshIfNeeded(
        minimumInterval: TimeInterval = 2,
        forceDiscovery: Bool = false
    ) async throws -> Bool {
        guard refreshGuard.reserve(minimumInterval: minimumInterval) else { return false }
        defer { refreshGuard.release() }

        let signpost = FloodlightPerformance.begin("ApplicationRefresh")
        let changed: Bool = await withCheckedContinuation { continuation in
            discoveryQueue.async { [self] in
                guard forceDiscovery || applicationDirectoriesChanged(fileManager: .default) else {
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: prepare(fileManager: .default))
            }
        }
        FloodlightPerformance.end("ApplicationRefresh", id: signpost)

        guard changed else { return false }
        try await index.start()
        try await index.rescan()
        return true
    }

    package func start() async throws {
        if !prepared {
            let signpost = FloodlightPerformance.begin("ApplicationDiscovery")
            await withCheckedContinuation { continuation in
                discoveryQueue.async { [self] in
                    prepare(fileManager: .default)
                    continuation.resume()
                }
            }
            FloodlightPerformance.end("ApplicationDiscovery", id: signpost)
        }
        try await index.start()
        for _ in 0..<200 {
            let progress = try await index.progress()
            if !progress.isScanning {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    package func indexedItems(for query: String, limit: Int = 12) async throws -> [SearchItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let normalizedQuery = FuzzyMatcher.normalized(query)

        let applicationsByMarker = snapshotApplicationsByMarker()
        let indexed = try await index.searchFiles(
            query,
            limit: UInt32(max(limit * 2, limit))
        )

        let matches = indexed.compactMap { result -> SearchItem? in
            guard let application = applicationsByMarker[result.relativePath] else {
                return nil
            }
            guard let score = Self.score(of: application, normalizedQuery: normalizedQuery) else {
                return nil
            }
            return SearchItem(
                id: application.id,
                title: application.name,
                subtitle: application.subtitle,
                kind: .application,
                action: .open(application.url),
                score: score + recentStore.boost(for: application.id),
                fileURL: application.url
            )
        }

        return SearchItemRanking.topRanked(matches, limit: limit)
    }

    package func immediatePage(for query: String, limit: Int = 12) -> SearchItemPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return SearchItemPage(items: [], totalMatched: 0)
        }
        let normalizedQuery = FuzzyMatcher.normalized(query)

        lock.lock()
        let currentApps = applications
        let boostStore = recentStore
        lock.unlock()

        var matches: [SearchItem] = []
        matches.reserveCapacity(min(currentApps.count, 64))

        for application in currentApps {
            guard let score = Self.score(
                of: application,
                normalizedQuery: normalizedQuery
            ) else {
                continue
            }
            matches.append(SearchItem(
                id: application.id,
                title: application.name,
                subtitle: application.subtitle,
                kind: .application,
                action: .open(application.url),
                score: score + boostStore.boost(for: application.id),
                fileURL: application.url
            ))
        }

        return SearchItemRanking.page(matches, limit: limit)
    }

    package func track(query: String, selectedURL: URL) {
        let markerByApplicationPath = snapshotMarkersByApplicationPath()
        guard let markerName = markerByApplicationPath[selectedURL.standardizedFileURL.path] else {
            return
        }
        index.track(
            query: query,
            selectedURL: markerRoot.appendingPathComponent(markerName)
        )
    }

    /// The score both search paths publish for `application` against a query.
    ///
    /// `immediatePage` matches names directly while `indexedItems` goes through
    /// the FFF index, whose own result score lives on an unrelated scale.
    /// Scoring both paths here keeps one ranking: whichever path served the
    /// query, an application lands on the same number.
    private static func score(of application: Application, normalizedQuery: String) -> Int? {
        FuzzyMatcher.score(
            normalizedQuery: normalizedQuery,
            normalizedCandidate: application.normalizedName
        )
        .map { SearchItemRanking.application + $0 }
    }

    private var prepared: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPrepared
    }

    @discardableResult
    private func prepare(fileManager: FileManager) -> Bool {
        let discovered = discoveryProvider()
        let marked = Self.assignMarkerNames(to: discovered)
        applicationDirectoryFingerprint = Self.makeApplicationDirectoryFingerprint(
            applications: marked,
            fileManager: fileManager
        )

        lock.lock()
        let changed = !isPrepared || Self.signature(of: applications) != Self.signature(of: marked)
        lock.unlock()

        guard changed else { return false }

        Self.synchronizeMarkers(
            applications: marked,
            markerRoot: markerRoot,
            fileManager: fileManager
        )

        lock.lock()
        applications = marked
        applicationsByMarker = Dictionary(
            uniqueKeysWithValues: marked.map { ($0.markerName, $0) }
        )
        markerByApplicationPath = Dictionary(
            uniqueKeysWithValues: marked.map { ($0.url.path, $0.markerName) }
        )
        isPrepared = true
        lock.unlock()
        return true
    }

    private static func signature(of applications: [Application]) -> [String] {
        applications.map { "\($0.id)\u{0}\($0.name)\u{0}\($0.markerName)" }
    }

    private func applicationDirectoriesChanged(fileManager: FileManager) -> Bool {
        guard !applicationDirectoryFingerprint.isEmpty else { return true }
        return applicationDirectoryFingerprint.contains { path, previousDate in
            CatalogDirectoryFingerprint.modificationDate(
                ofDirectoryAtPath: path,
                fileManager: fileManager
            ) != previousDate
        }
    }

    private static func makeApplicationDirectoryFingerprint(
        applications: [Application],
        fileManager: FileManager
    ) -> [String: Date] {
        var paths = Set(applicationRoots(fileManager: fileManager).map(\.standardizedFileURL.path))
        paths.formUnion(
            standaloneApplications.map {
                $0.deletingLastPathComponent().standardizedFileURL.path
            }
        )
        paths.formUnion(
            applications.map {
                $0.url.deletingLastPathComponent().standardizedFileURL.path
            }
        )
        return CatalogDirectoryFingerprint.make(forPaths: paths, fileManager: fileManager)
    }

    private func snapshotApplicationsByMarker() -> [String: Application] {
        lock.lock()
        defer { lock.unlock() }
        return applicationsByMarker
    }

    private func snapshotMarkersByApplicationPath() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return markerByApplicationPath
    }

    private static func discoverApplications() -> [(name: String, url: URL)] {
        let fileManager = FileManager.default
        let roots = applicationRoots(fileManager: fileManager)

        var seen = Set<String>()
        var applications: [(name: String, url: URL)] = []
        let keys: [URLResourceKey] = [.isApplicationKey, .isPackageKey, .nameKey]

        for url in standaloneApplications where isApplication(url) {
            appendApplication(url, fileManager: fileManager, seen: &seen, to: &applications)
        }

        var seenRoots = Set<String>()
        for root in roots
            where seenRoots.insert(root.standardizedFileURL.path).inserted
            && fileManager.fileExists(atPath: root.path)
        {
            // Finder-hidden Cryptex links such as Safari still belong in the catalog.
            let directChildren = (try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: keys,
                options: []
            )) ?? []
            for url in directChildren where isApplication(url) {
                appendApplication(url, fileManager: fileManager, seen: &seen, to: &applications)
            }

            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            for case let url as URL in enumerator where isApplication(url) {
                enumerator.skipDescendants()
                appendApplication(url, fileManager: fileManager, seen: &seen, to: &applications)
            }
        }

        // Discovery, not the query path: this runs once per filesystem walk and
        // orders the whole catalog alphabetically, which *is* the full order — a
        // bounded top-K would be the wrong answer here, not a faster one.
        // ast-grep-ignore: search-path-no-full-sort
        return applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func applicationRoots(fileManager: FileManager) -> [URL] {
        // Keep the familiar paths first so duplicate Cryptex-backed apps retain
        // stable URLs, result IDs, subtitles, and learned recency.
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        roots.append(contentsOf: fileManager.urls(for: .applicationDirectory, in: .allDomainsMask))
        roots.append(
            URL(
                fileURLWithPath: "/System/Library/CoreServices/Applications",
                isDirectory: true
            )
        )
        roots.append(
            URL(
                fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications",
                isDirectory: true
            )
        )
        return roots
    }

    private static let standaloneApplications = [
        URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true),
    ]

    private static func isApplication(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "app" {
            return true
        }
        let values = try? url.resourceValues(forKeys: [.isApplicationKey, .isPackageKey])
        return values?.isApplication == true && values?.isPackage == true
    }

    private static func appendApplication(
        _ url: URL,
        fileManager: FileManager,
        seen: inout Set<String>,
        to applications: inout [(name: String, url: URL)]
    ) {
        let standardized = url.standardizedFileURL
        let canonicalPath = standardized.resolvingSymlinksInPath().path
        guard seen.insert(canonicalPath).inserted else { return }
        let displayName = fileManager.displayName(atPath: standardized.path)
            .replacingOccurrences(of: ".app", with: "")
        applications.append((displayName, standardized))
    }

    private static func assignMarkerNames(
        to applications: [(name: String, url: URL)]
    ) -> [Application] {
        var occurrences: [String: Int] = [:]
        return applications.map { application in
            let safeName = application.name
                .replacingOccurrences(of: "/", with: "⁄")
                .replacingOccurrences(of: ":", with: "꞉")
            let occurrence = occurrences[safeName, default: 0]
            occurrences[safeName] = occurrence + 1
            let suffix = occurrence == 0 ? "" : " — \(occurrence + 1)"
            return Application(
                name: application.name,
                url: application.url,
                markerName: "\(safeName)\(suffix).app",
                id: "application:\(application.url.path)",
                subtitle: application.url.deletingLastPathComponent().path,
                normalizedName: FuzzyMatcher.normalized(application.name)
            )
        }
    }

    private static func synchronizeMarkers(
        applications: [Application],
        markerRoot: URL,
        fileManager: FileManager
    ) {
        try? fileManager.createDirectory(at: markerRoot, withIntermediateDirectories: true)
        let desired = Set(applications.map(\.markerName))
        let existing = (try? fileManager.contentsOfDirectory(
            at: markerRoot,
            includingPropertiesForKeys: nil
        )) ?? []

        for url in existing where !desired.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
        for application in applications {
            let marker = markerRoot.appendingPathComponent(application.markerName)
            if !fileManager.fileExists(atPath: marker.path) {
                fileManager.createFile(atPath: marker.path, contents: Data())
            }
        }
    }
}
