import Foundation
import os

/// A source of search results Floodlight can start, refresh, and query.
///
/// The applications catalog and the System Settings catalog both answer the
/// same four questions, so they answer them through one interface: the
/// coordinator holds `[Catalog]` and never learns which is which.
///
/// Only `immediatePage(for:limit:)` is required to return matches. A catalog
/// that has no second, slower pass leaves `indexedItems` alone, and one that
/// cannot learn from a selection leaves `track` alone.
protocol Catalog: Sendable {
    /// Brings the catalog up to a queryable state. Called once per launch.
    func start() async throws

    /// Re-discovers the catalog's backing store when it looks stale.
    ///
    /// - Returns: `true` when the snapshot changed and results should be
    ///   recomputed.
    func refreshIfNeeded(minimumInterval: TimeInterval, forceDiscovery: Bool) async throws -> Bool

    /// The synchronous pass, cheap enough to run on every keystroke.
    func immediatePage(for query: String, limit: Int) -> SearchItemPage

    /// The asynchronous pass, for catalogs backed by an index.
    func indexedItems(for query: String, limit: Int) async throws -> [SearchItem]

    /// Records that `selectedURL` answered `query`, for frecency.
    func track(query: String, selectedURL: URL)
}

extension Catalog {
    func indexedItems(for query: String, limit: Int) async throws -> [SearchItem] { [] }

    func track(query: String, selectedURL: URL) {}

    func refreshIfNeeded() async throws -> Bool {
        try await refreshIfNeeded(minimumInterval: 2, forceDiscovery: false)
    }

    func immediatePage(for query: String) -> SearchItemPage {
        immediatePage(for: query, limit: 12)
    }

    func indexedItems(for query: String) async throws -> [SearchItem] {
        try await indexedItems(for: query, limit: 12)
    }
}

/// Where a kind of result sits relative to the others before its own match
/// quality is added.
///
/// Each band is far enough from its neighbours that no fuzzy score can cross
/// it, so a strong file match never outranks a weak application match.
enum SearchItemRanking {
    static let command = 200_000
    static let calculator = 100_000
    static let application = 100_000
    static let setting = 2_000
    static let content = 1_000
    /// The web fallback is always last, and always present.
    static let webFallback = Int.min

    /// The one order Floodlight publishes results in.
    ///
    /// Equal scores break on title so a query returns the same order whichever
    /// pass produced it — the immediate pass and the indexed pass have to agree
    /// or results visibly reshuffle as the slower pass lands.
    static func ranksBefore(_ lhs: SearchItem, _ rhs: SearchItem) -> Bool {
        lhs.score == rhs.score
            ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            : lhs.score > rhs.score
    }

    static func ranked(_ items: [SearchItem]) -> [SearchItem] {
        items.sorted(by: ranksBefore)
    }

    /// Ranks `matches`, keeps the first `limit`, and reports how many matched.
    ///
    /// The count is the total, not the page — the filter chips show how many
    /// results exist, not how many fit.
    static func page(_ matches: [SearchItem], limit: Int) -> SearchItemPage {
        let ranked = ranked(matches)
        return SearchItemPage(
            items: Array(ranked.prefix(limit)),
            totalMatched: ranked.count
        )
    }
}

/// Modification-date snapshot of the directories a catalog discovers from.
///
/// Comparing two of these is how both catalogs answer "is a full re-walk worth
/// it?" without walking.
enum CatalogDirectoryFingerprint {
    static func modificationDate(
        ofDirectoryAtPath path: String,
        fileManager: FileManager
    ) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    static func make(forPaths paths: some Sequence<String>, fileManager: FileManager) -> [String: Date] {
        Dictionary(
            uniqueKeysWithValues: Set(paths).map { path in
                (path, modificationDate(ofDirectoryAtPath: path, fileManager: fileManager))
            }
        )
    }

    static func make(for urls: some Sequence<URL>, fileManager: FileManager) -> [String: Date] {
        make(forPaths: urls.map(\.standardizedFileURL.path), fileManager: fileManager)
    }
}

/// Keeps repeated keystrokes from stacking up filesystem walks.
///
/// A refresh is reserved before it starts and released when it finishes, so a
/// walk already in flight absorbs the keystrokes that arrive during it.
final class CatalogRefreshGuard: Sendable {
    private struct State {
        var isRefreshing = false
        var lastRefresh: TimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func reserve(minimumInterval: TimeInterval) -> Bool {
        state.withLock { state in
            guard !state.isRefreshing else { return false }
            let now = Date.timeIntervalSinceReferenceDate
            guard now - state.lastRefresh >= minimumInterval else { return false }
            state.isRefreshing = true
            state.lastRefresh = now
            return true
        }
    }

    func release() {
        state.withLock { $0.isRefreshing = false }
    }
}
