import Foundation
import os

package final class ApplicationCatalog: Catalog {
    private struct Application: Sendable {
        let name: String
        let url: URL
        let id: String
        let subtitle: String
        let normalizedName: String
        let asciiCandidate: [UInt8]?
    }

    private struct State: Sendable {
        var applications: [Application] = []
        var isPrepared = false
        var applicationDirectoryFingerprint: [String: Date] = [:]
    }

    private let discoveryQueue = DispatchQueue(
        label: "com.floodlight.application-catalog",
        qos: .userInitiated
    )
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let refreshGuard = CatalogRefreshGuard()
    private let recentStore: RecentStore
    private let blocklistStore: BlocklistStore
    private let discoveryProvider: @Sendable () -> [(name: String, url: URL)]

    /// Nothing here touches disk: matching runs entirely against the
    /// in-memory snapshot, so whatever `supportURL` points at is neither read
    /// nor written. A machine upgrading from a marker-index build keeps
    /// whatever it still has under that directory, byte for byte.
    package init(
        supportURL: URL? = nil,
        recentStore: RecentStore,
        blocklistStore: BlocklistStore = BlocklistStore(),
        deferDiscovery: Bool = false,
        discoveryProvider: @escaping @Sendable () -> [(name: String, url: URL)] = {
            ApplicationCatalog.discoverApplications()
        }
    ) {
        // The parameter stays so tests can prove the directory is never
        // touched (#100); referencing it keeps the dead-code gate honest
        // without giving the location a job.
        _ = supportURL
        self.recentStore = recentStore
        self.blocklistStore = blocklistStore
        self.discoveryProvider = discoveryProvider

        if !deferDiscovery {
            prepare(fileManager: .default)
        }
    }

    /// Refreshes the standard application catalog without blocking the caller.
    ///
    /// Discovery runs on the catalog's serial background queue. The common case
    /// (nothing was installed or removed) only checks application-directory
    /// modification dates; a full walk happens only after a directory changes.
    package func refreshIfNeeded(
        minimumInterval: TimeInterval = 2,
        forceDiscovery: Bool = false
    ) async throws -> Bool {
        guard refreshGuard.reserve(minimumInterval: minimumInterval) else { return false }
        defer { refreshGuard.release() }

        let signpost = FloodlightPerformance.begin("ApplicationRefresh")
        let changed = await enqueueDiscovery {
            guard forceDiscovery || self.applicationDirectoriesChanged(fileManager: .default) else {
                return false
            }
            return self.prepare(fileManager: .default)
        }
        FloodlightPerformance.end("ApplicationRefresh", id: signpost)
        return changed
    }

    package func start() async throws {
        if !state.withLock({ $0.isPrepared }) {
            let signpost = FloodlightPerformance.begin("ApplicationDiscovery")
            _ = await enqueueDiscovery {
                self.prepare(fileManager: .default)
            }
            FloodlightPerformance.end("ApplicationDiscovery", id: signpost)
        }
    }

    package func immediatePage(for query: String, limit: Int = 12) -> SearchItemPage {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return SearchItemPage(items: [], totalMatched: 0)
        }
        let normalizedQuery = FuzzyMatcher.normalized(query)
        let queryBytes = Array(normalizedQuery.utf8)
        let asciiQuery = queryBytes.allSatisfy { $0 < 0x80 } ? queryBytes : nil

        let currentApps = state.withLock { $0.applications }
        let boosts = recentStore.boostMap()

        var matches: [SearchItem] = []
        matches.reserveCapacity(min(currentApps.count, 64))

        // Matcher, then blocklist. Asking last is what makes the blocklist
        // cheap: it is consulted for the handful of applications the query
        // actually matched, not for every one it did not. There is no
        // prefilter in front of the matcher — the old character mask was
        // unsound, rejecting substitution typos the matcher accepts (#69).
        for application in currentApps {
            guard let score = Self.score(
                of: application,
                normalizedQuery: normalizedQuery,
                asciiQuery: asciiQuery
            ) else {
                continue
            }
            if blocklistStore.isBlocked(
                normalizedName: application.normalizedName,
                id: application.id
            ) {
                continue
            }
            let boost = boosts[application.id] ?? 0
            matches.append(SearchItem(
                id: application.id,
                title: application.name,
                subtitle: application.subtitle,
                kind: .application,
                action: .open(application.url),
                score: score + boost,
                fileURL: application.url
            ))
        }
        return SearchItemRanking.page(matches, limit: limit)
    }

    /// The one score an application can earn against a query: the structural
    /// matcher's shape score on the application band. With a single retrieval
    /// path there is no second score to agree with.
    private static func score(
        of application: Application,
        normalizedQuery: String,
        asciiQuery: [UInt8]?
    ) -> Int? {
        let rawScore: Int? = if let asciiQuery, let asciiCandidate = application.asciiCandidate {
            FuzzyMatcher.scoreASCII(
                normalizedQuery: asciiQuery,
                normalizedCandidate: asciiCandidate
            )
        } else {
            FuzzyMatcher.score(
                normalizedQuery: normalizedQuery,
                normalizedCandidate: application.normalizedName
            )
        }
        return rawScore.map { SearchItemRanking.application + $0 }
    }

    private func enqueueDiscovery<Result: Sendable>(
        _ work: @escaping @Sendable () -> Result
    ) async -> Result {
        await withCheckedContinuation { continuation in
            discoveryQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    @discardableResult
    private func prepare(fileManager: FileManager) -> Bool {
        let discovered = discoveryProvider()
        let resolved = Self.makeApplications(from: discovered)
        let fingerprint = Self.makeApplicationDirectoryFingerprint(
            applications: resolved,
            fileManager: fileManager
        )

        let changed = state.withLock { current in
            current.applicationDirectoryFingerprint = fingerprint
            return !current.isPrepared
                || Self.signature(of: current.applications) != Self.signature(of: resolved)
        }

        guard changed else { return false }

        state.withLock { current in
            current.applications = resolved
            current.isPrepared = true
        }
        return true
    }

    private static func signature(of applications: [Application]) -> [String] {
        applications.map { "\($0.id)\u{0}\($0.name)" }
    }

    private func applicationDirectoriesChanged(fileManager: FileManager) -> Bool {
        let fingerprint = state.withLock { $0.applicationDirectoryFingerprint }
        guard !fingerprint.isEmpty else { return true }
        return fingerprint.contains { path, previousDate in
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

    private static func makeApplications(
        from discovered: [(name: String, url: URL)]
    ) -> [Application] {
        discovered.map { application in
            let normalized = FuzzyMatcher.normalized(application.name)
            let utf8Bytes = Array(normalized.utf8)
            let asciiCandidate = utf8Bytes.allSatisfy { $0 < 0x80 } ? utf8Bytes : nil
            return Application(
                name: application.name,
                url: application.url,
                id: "application:\(application.url.path)",
                subtitle: application.url.deletingLastPathComponent().path,
                normalizedName: normalized,
                asciiCandidate: asciiCandidate
            )
        }
    }
}
