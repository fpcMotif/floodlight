import AppKit
import Foundation

final class ApplicationCatalog: @unchecked Sendable {
    private struct Application: Sendable {
        let name: String
        let url: URL
        let markerName: String
    }

    private let applicationsByMarker: [String: Application]
    private let markerByApplicationPath: [String: String]
    private let markerRoot: URL
    private let index: FFFIndex
    private let recentStore: RecentStore

    init(recentStore: RecentStore, supportURL: URL? = nil) {
        self.recentStore = recentStore

        let fileManager = FileManager.default
        let defaultSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Floodlight", isDirectory: true))
            ?? fileManager.temporaryDirectory.appendingPathComponent("Floodlight", isDirectory: true)
        let appIndexRoot = (supportURL ?? defaultSupport)
            .appendingPathComponent("ApplicationIndex", isDirectory: true)
        markerRoot = appIndexRoot.appendingPathComponent("Items", isDirectory: true)

        let applications = Self.discoverApplications()
        let marked = Self.assignMarkerNames(to: applications)
        applicationsByMarker = Dictionary(uniqueKeysWithValues: marked.map { ($0.markerName, $0) })
        markerByApplicationPath = Dictionary(
            uniqueKeysWithValues: marked.map { ($0.url.path, $0.markerName) }
        )

        Self.synchronizeMarkers(
            applications: marked,
            markerRoot: markerRoot,
            fileManager: fileManager
        )
        index = FFFIndex(
            rootURL: markerRoot,
            storageURL: appIndexRoot.appendingPathComponent("Database", isDirectory: true),
            enableContentIndexing: false,
            watch: false
        )
    }

    func start() async throws {
        try await index.start()
        for _ in 0..<200 {
            let progress = try await index.progress()
            if !progress.isScanning {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func search(_ query: String, limit: Int = 12) async throws -> [SearchItem] {
        let indexed = try await index.search(
            query,
            limit: UInt32(max(applicationsByMarker.count, limit))
        )

        return indexed.compactMap { result -> SearchItem? in
            guard let application = applicationsByMarker[result.relativePath] else {
                return nil
            }
            let id = "application:\(application.url.path)"
            return SearchItem(
                id: id,
                title: application.name,
                subtitle: application.url.deletingLastPathComponent().path,
                kind: .application,
                action: .open(application.url),
                score: result.score + recentStore.boost(for: id),
                fileURL: application.url
            )
        }
        .sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.title < rhs.title : lhs.score > rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }

    func track(query: String, selectedURL: URL) {
        guard let markerName = markerByApplicationPath[selectedURL.standardizedFileURL.path] else {
            return
        }
        index.track(
            query: query,
            selectedURL: markerRoot.appendingPathComponent(markerName)
        )
    }

    private static func discoverApplications() -> [(name: String, url: URL)] {
        let fileManager = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        var seen = Set<String>()
        var applications: [(name: String, url: URL)] = []
        let keys: [URLResourceKey] = [.isApplicationKey, .isPackageKey, .nameKey]

        for root in roots where fileManager.fileExists(atPath: root.path) {
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

        return applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

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
        guard seen.insert(standardized.path).inserted else { return }
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
                markerName: "\(safeName)\(suffix).app"
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
