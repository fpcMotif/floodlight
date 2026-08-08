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
package protocol Catalog: Sendable {
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

package extension Catalog {
    func indexedItems(for query: String, limit: Int) async throws -> [SearchItem] {
        []
    }

    func track(query: String, selectedURL: URL) {}

    func refreshIfNeeded() async throws -> Bool {
        try await refreshIfNeeded(minimumInterval: 2, forceDiscovery: false)
    }

    // periphery:ignore - The protocol's default-limit surface. The shell always
    // passes an explicit limit because the panel's row count decides it, so
    // outside the tests these have no call sites — that makes them unreferenced,
    // not dead: deleting them would push the literal 12 into every caller.
    func immediatePage(for query: String) -> SearchItemPage {
        immediatePage(for: query, limit: 12)
    }

    // periphery:ignore - See `immediatePage(for:)` above.
    func indexedItems(for query: String) async throws -> [SearchItem] {
        try await indexedItems(for: query, limit: 12)
    }
}

/// Where a kind of result sits relative to the others before its own match
/// quality is added.
///
/// Each band is far enough from its neighbours that no fuzzy score can cross
/// it, so a strong file match never outranks a weak application match.
package enum SearchItemRanking {
    package static let command = 200_000
    package static let calculator = 100_000
    package static let application = 100_000
    package static let setting = 2_000
    package static let content = 1_000
    /// The web fallback is always last, and always present.
    package static let webFallback = Int.min

    /// The one order Floodlight publishes results in.
    ///
    /// Equal scores break on title so a query returns the same order whichever
    /// pass produced it — the immediate pass and the indexed pass have to agree
    /// or results visibly reshuffle as the slower pass lands.
    package static func ranksBefore(_ lhs: SearchItem, _ rhs: SearchItem) -> Bool {
        lhs.score == rhs.score
            ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            : lhs.score > rhs.score
    }

    /// Orders every item, for the one caller that publishes a whole list.
    ///
    /// A catalog answering a query wants ``topRanked(_:limit:)`` instead: it
    /// only ever shows a page, and sorting the discarded tail is work nobody
    /// reads. This file is the only place under `Sources/FloodlightEngine/Search`
    /// allowed to call `sorted` — see `tools/ast-grep/rules/search-path-no-full-sort.yml`.
    package static func ranked(_ items: [SearchItem]) -> [SearchItem] {
        items.sorted(by: ranksBefore)
    }

    /// The best `limit` items, in published order.
    ///
    /// Selection is bounded: a heap of at most `limit` candidates, so the cost
    /// is O(n log limit) rather than the O(n log n) of ranking everything and
    /// throwing the tail away. With ~1,500 applications and a 12-row panel
    /// that is the difference between sorting 1,500 items and sifting a
    /// 12-element heap — on every keystroke.
    ///
    /// The result is identical to `ranked(items).prefix(limit)`, which is what
    /// `SearchItemRankingTests` asserts.
    package static func topRanked(_ items: [SearchItem], limit: Int) -> [SearchItem] {
        guard limit > 0 else { return [] }
        guard items.count > limit else { return ranked(items) }

        // A max-heap under `ranksBefore`: the root is the worst item kept so
        // far, so deciding whether a candidate belongs is one comparison.
        var heap: [SearchItem] = []
        heap.reserveCapacity(limit)

        for item in items {
            if heap.count < limit {
                heap.append(item)
                siftUp(&heap, from: heap.count - 1)
            } else if ranksBefore(item, heap[0]) {
                heap[0] = item
                siftDown(&heap, from: 0)
            }
        }

        return ranked(heap)
    }

    /// Ranks `matches`, keeps the first `limit`, and reports how many matched.
    ///
    /// The count is the total, not the page — the filter chips show how many
    /// results exist, not how many fit.
    package static func page(_ matches: [SearchItem], limit: Int) -> SearchItemPage {
        SearchItemPage(
            items: topRanked(matches, limit: limit),
            totalMatched: matches.count
        )
    }

    private static func siftUp(_ heap: inout [SearchItem], from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            // Parent already ranks after the child, so the worst is still on top.
            guard ranksBefore(heap[parent], heap[child]) else { return }
            heap.swapAt(parent, child)
            child = parent
        }
    }

    private static func siftDown(_ heap: inout [SearchItem], from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var worst = parent
            if left < heap.count, ranksBefore(heap[worst], heap[left]) {
                worst = left
            }
            if right < heap.count, ranksBefore(heap[worst], heap[right]) {
                worst = right
            }
            guard worst != parent else { return }
            heap.swapAt(parent, worst)
            parent = worst
        }
    }
}

/// Modification-date snapshot of the directories a catalog discovers from.
///
/// Comparing two of these is how both catalogs answer "is a full re-walk worth
/// it?" without walking.
package enum CatalogDirectoryFingerprint {
    package static func modificationDate(
        ofDirectoryAtPath path: String,
        fileManager: FileManager
    ) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    package static func make(
        forPaths paths: some Sequence<String>,
        fileManager: FileManager
    ) -> [String: Date] {
        Dictionary(
            uniqueKeysWithValues: Set(paths).map { path in
                (path, modificationDate(ofDirectoryAtPath: path, fileManager: fileManager))
            }
        )
    }

    package static func make(
        for urls: some Sequence<URL>,
        fileManager: FileManager
    ) -> [String: Date] {
        make(forPaths: urls.map(\.standardizedFileURL.path), fileManager: fileManager)
    }
}

/// Keeps repeated keystrokes from stacking up filesystem walks.
///
/// A refresh is reserved before it starts and released when it finishes, so a
/// walk already in flight absorbs the keystrokes that arrive during it.
package final class CatalogRefreshGuard: Sendable {
    private struct State {
        var isRefreshing = false
        var lastRefresh: TimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    package func reserve(minimumInterval: TimeInterval) -> Bool {
        state.withLock { state in
            guard !state.isRefreshing else { return false }
            let now = Date.timeIntervalSinceReferenceDate
            guard now - state.lastRefresh >= minimumInterval else { return false }
            state.isRefreshing = true
            state.lastRefresh = now
            return true
        }
    }

    package func release() {
        state.withLock { $0.isRefreshing = false }
    }
}
