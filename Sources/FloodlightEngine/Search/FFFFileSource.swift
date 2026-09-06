import Foundation
import os

final class FFFFileSource: FileSource {
    private struct State: Sendable {
        var rootURL: URL
        var hasStartedIndex = false
    }

    private let index: FFFIndex
    private let state: OSAllocatedUnfairLock<State>

    init(index: FFFIndex, rootURL: URL) {
        self.index = index
        state = OSAllocatedUnfairLock(initialState: State(rootURL: rootURL.standardizedFileURL))
    }

    func start() async throws {
        try await index.start()
        try await waitForScanCompletion()
        state.withLock { $0.hasStartedIndex = true }
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
        let (previousRoot, isStarted) = state.withLock { ($0.rootURL, $0.hasStartedIndex) }
        try await index.changeRoot(to: newRoot)
        do {
            guard isStarted else {
                state.withLock { $0.rootURL = newRoot }
                return
            }
            try await waitForScanCompletion()
            state.withLock { $0.rootURL = newRoot }
        } catch {
            try? await index.changeRoot(to: previousRoot)
            try? await waitForScanCompletion()
            throw error
        }
    }

    func rebuild() async throws {
        let currentRoot = state.withLock { $0.rootURL }
        try await index.changeRoot(to: currentRoot)
        try await waitForScanCompletion()
    }

    func track(query: String, selectedURL: URL) {
        index.track(query: query, selectedURL: selectedURL)
    }

    /// One wait, sliced only so that a cancelled scope change is noticed while
    /// FFF is still walking. Each slice is a blocking wait inside the engine,
    /// not a sleep: the scope change finishes the moment a query can observe
    /// the new atomic snapshot, which is the FileSource contract.
    private static let scanWaitSliceMilliseconds: UInt64 = 1_000

    /// FFF starts scans in the background. The FileSource contract is
    /// stronger: startup, rebuild, and scope changes finish only when a query
    /// can observe the new atomic snapshot.
    private func waitForScanCompletion() async throws {
        while true {
            try Task.checkCancellation()
            let progress = try await index.waitForScan(
                timeoutMilliseconds: Self.scanWaitSliceMilliseconds
            )
            if !progress.isScanning { return }
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
                index: FFFIndex(
                    rootURL: rootURL,
                    storageURL: storageURL,
                    enableHomeDirectoryScanning: true,
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
