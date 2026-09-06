import FloodlightEngine
import Foundation

/// Deep path navigation for one query: a single directory lookup per query
/// change, made off the main actor and reused by every projection of that
/// query.
///
/// Its own type rather than a resolver and a resolution sitting side by side on
/// the coordinator. Every question here is about the query/scope pair the cache
/// is tagged with, and answering them next to the coordinator's other state
/// invited reading one without checking the other — which is how a row resolved
/// under a since-replaced scope reaches the screen (ADR 0007).
struct PathResolutionCache: Sendable {
    /// One query's worth of resolution. Not to be confused with the engine's
    /// `ResolvedPath`, which is what a single lookup returns: this is that
    /// lookup's folder row plus the query and scope it is only valid for.
    private struct Entry: Sendable {
        let query: String
        let rootURL: URL
        let folderRow: SearchItem?

        func matches(query: String, rootURL: URL) -> Bool {
            self.query == query && self.rootURL == rootURL
        }
    }

    private let resolver: any PathResolving
    private var entry: Entry?

    init(resolver: any PathResolving) {
        self.resolver = resolver
    }

    /// The cache this one becomes once `query` is resolved under `rootURL`.
    ///
    /// `nonisolated` and pure: the lookup is the part that must not happen on
    /// the main actor. A resolution already made for this exact pair is handed
    /// back untouched, so re-presenting the panel on an unchanged query is
    /// free.
    nonisolated func resolving(query: String, rootURL: URL) async -> PathResolutionCache {
        if let entry, entry.matches(query: query, rootURL: rootURL) { return self }
        // Most queries are not paths, and for those the resolver provably
        // answers nil. Asking it anyway costs a hop onto the global executor
        // and back on every keystroke of every ordinary search, to learn what
        // a `contains("/")` already knows.
        guard PathNavigator.hasPathSyntax(query) else {
            return with(Entry(query: query, rootURL: rootURL, folderRow: nil))
        }
        let resolved = await resolver.resolve(query: query, rootURL: rootURL)
        return with(Entry(query: query, rootURL: rootURL, folderRow: resolved?.folderItem))
    }

    /// Whether this cache still answers the given pair. Cancellation alone does
    /// not make a store safe — a superseded task can still be scheduled onto
    /// the main actor before it observes the flag — so the caller re-checks
    /// here before keeping a result.
    func matches(query: String, rootURL: URL) -> Bool {
        entry?.matches(query: query, rootURL: rootURL) ?? false
    }

    /// The folder row for `query`, but only when it was resolved for that query
    /// against the scope in force now. Anything else — a query the user has
    /// moved past, a scope since committed — has no row rather than a lookup.
    func folderRow(for query: String, rootURL: URL) -> SearchItem? {
        guard let entry, entry.matches(query: query, rootURL: rootURL) else { return nil }
        return entry.folderRow
    }

    /// Stale-while-revalidate for the folder row.
    ///
    /// At the interim publication the tag still names the *previous* query, so
    /// asking `folderRow(for:rootURL:)` returns nil and the folder blinks off
    /// the top of the list on every keystroke inside a path query — the Top Hit
    /// vanishes and the automatic selection jumps. The previous row is carried
    /// instead, but only while it can still be the right answer: the same
    /// committed scope, and a query that is still path syntax, so replacing
    /// "Projects/" with "xcode" clears it rather than flashing a stale folder.
    /// Both are string comparisons; the projection stays off the disk.
    ///
    /// `.some(nil)` means "show no row", distinct from `nil`, which leaves the
    /// projection to derive one as usual.
    func carriedFolderRow(for query: String, rootURL: URL) -> SearchItem?? {
        guard PathNavigator.hasPathSyntax(query) else { return .some(nil) }
        guard let entry, entry.rootURL == rootURL else { return .some(nil) }
        return .some(entry.folderRow)
    }

    /// Forgets the resolution, keeping the resolver — what a committed scope
    /// change leaves behind.
    func cleared() -> PathResolutionCache {
        with(nil)
    }

    private func with(_ entry: Entry?) -> PathResolutionCache {
        var copy = self
        copy.entry = entry
        return copy
    }
}
