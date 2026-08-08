import FFFKit
import Foundation

package typealias FFFIndex = FFFKit.FFFIndex
package typealias IndexedSearchItem = FFFKit.FFFSearchResult

actor FFFFileSource: FileSource {
    private let index: FFFKit.FFFIndex
    private var rootURL: URL
    private var hasStartedIndex = false

    init(index: FFFKit.FFFIndex, rootURL: URL) {
        self.index = index
        self.rootURL = rootURL.standardizedFileURL
    }

    func start() async throws {
        try await index.start()
        hasStartedIndex = true
        try await waitForScanCompletion()
    }

    func indexedItems(for query: String, limit: Int) async throws -> [SearchItem] {
        try await index.search(query, limit: UInt32(limit)).map { $0.makeSearchItem() }
    }

    func contentItems(for query: String) async throws -> [SearchItem] {
        try await index.searchContent(query).map { item in
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
    }

    func changeScope(to url: URL) async throws {
        let newRoot = url.standardizedFileURL
        let previousRoot = rootURL
        try await index.changeRoot(to: newRoot)
        do {
            guard hasStartedIndex else {
                rootURL = newRoot
                return
            }
            try await waitForScanCompletion()
            rootURL = newRoot
        } catch {
            try? await index.changeRoot(to: previousRoot)
            try? await waitForScanCompletion()
            throw error
        }
    }

    func rebuild() async throws {
        // A same-root restart gives this rebuild an operation-scoped barrier.
        // FFF's rescan may be deferred behind post-scan indexing while
        // `isScanning` remains false, so polling cannot prove that request
        // committed. Root restart replaces the picker and pre-arms its scan.
        try await index.changeRoot(to: rootURL)
        try await waitForScanCompletion()
    }

    nonisolated func track(query: String, selectedURL: URL) {
        index.track(query: query, selectedURL: selectedURL)
    }

    /// FFF starts scans in the background. The FileSource contract is
    /// stronger: startup, rebuild, and scope changes finish only when a query
    /// can observe the new atomic snapshot.
    private func waitForScanCompletion() async throws {
        var consecutiveIdlePolls = 0
        while consecutiveIdlePolls < 2 {
            try Task.checkCancellation()
            let progress = try await index.progress()
            consecutiveIdlePolls = progress.isScanning ? 0 : consecutiveIdlePolls + 1
            if consecutiveIdlePolls < 2 {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

package extension SourceSearchEngine {
    init(
        rootURL: URL,
        storageURL: URL,
        applications: any Catalog,
        settings: any Catalog,
        logFilePath: String? = nil,
        logLevel: String = "info"
    ) {
        self.init(
            files: FFFFileSource(
                index: FFFKit.FFFIndex(
                    rootURL: rootURL,
                    storageURL: storageURL,
                    logFilePath: logFilePath,
                    logLevel: logLevel
                ),
                rootURL: rootURL
            ),
            applications: applications,
            settings: settings
        )
    }
}
