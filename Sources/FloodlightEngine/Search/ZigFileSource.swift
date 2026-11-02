import Foundation
import os

/// File search on the memory-mapped Zig index in `core/` (ADR 0010). Names
/// and folders come from the index; content search, and the selection
/// history FFF keeps for it, stay on the source this one wraps.
///
/// Every scope change and rebuild writes a fresh index, maps it, and only then
/// drops the old handle, so a query never sees a half-built index and never
/// waits on a build.
final class ZigFileSource: FileSource {
    private struct State: Sendable {
        var rootURL: URL
        var index: ZigNameIndex?
    }

    private let content: any FileSource
    private let indexFileURL: URL
    private let state: OSAllocatedUnfairLock<State>

    init(content: any FileSource, rootURL: URL, storageURL: URL) {
        self.content = content
        indexFileURL = storageURL.appendingPathComponent("names.flix")
        state = OSAllocatedUnfairLock(
            initialState: State(rootURL: FFFIndex.canonicalFileURL(rootURL))
        )
    }

    func start() async throws {
        let rootURL = state.withLock { $0.rootURL }
        async let names = ZigNameIndex.build(root: rootURL, at: indexFileURL)
        try await content.start()
        let index = try await names
        state.withLock { $0.index = index }
    }

    func indexedItems(for query: String, limit: Int) async throws -> [SearchItem] {
        guard let index = state.withLock({ $0.index }) else { return [] }
        return await Self.search(index, for: query, limit: limit)
    }

    func contentItems(for query: String) async throws -> [SearchItem] {
        try await content.contentItems(for: query)
    }

    func changeScope(to url: URL) async throws {
        let newRoot = FFFIndex.canonicalFileURL(url)
        let (previousRoot, isStarted) = state.withLock { ($0.rootURL, $0.index != nil) }
        guard isStarted else {
            try await content.changeScope(to: newRoot)
            state.withLock { $0.rootURL = newRoot }
            return
        }
        async let names = ZigNameIndex.build(root: newRoot, at: indexFileURL)
        try await content.changeScope(to: newRoot)
        do {
            let index = try await names
            state.withLock { $0 = State(rootURL: newRoot, index: index) }
        } catch {
            // The name index kept its previous handle; put content search back
            // on the same root so the two halves never disagree on scope.
            try? await content.changeScope(to: previousRoot)
            throw error
        }
    }

    func rebuild() async throws {
        let rootURL = state.withLock { $0.rootURL }
        async let names = ZigNameIndex.build(root: rootURL, at: indexFileURL)
        try await content.rebuild()
        let index = try await names
        state.withLock { $0.index = index }
    }

    func track(query: String, selectedURL: URL) {
        content.track(query: query, selectedURL: selectedURL)
    }

    /// `@concurrent` so the C search never runs on the caller's actor, which
    /// may be the main actor, whatever isolation the caller has.
    @concurrent
    private static func search(
        _ index: ZigNameIndex,
        for query: String,
        limit: Int
    ) async -> [SearchItem] {
        index.search(query, limit: limit).map { $0.makeSearchItem() }
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
            files: ZigFileSource(
                content: FFFFileSource(
                    index: FFFIndex(
                        rootURL: rootURL,
                        storageURL: storageURL,
                        enableHomeDirectoryScanning: true,
                        contentCacheBudget: .launcher,
                        logFilePath: logFilePath,
                        logLevel: logLevel
                    ),
                    rootURL: rootURL
                ),
                rootURL: rootURL,
                storageURL: storageURL
            ),
            applications: applications,
            settings: settings
        )
    }
}
