import FloodlightEngine

/// Read-side conveniences the store does not need in production. Tests assert
/// on what was just recorded; the app only ever asks the store for a search.
package extension ClipboardHistoryStore {
    var count: Int {
        search(query: "").count
    }

    var isEmpty: Bool {
        search(query: "").isEmpty
    }

    /// The newest unpinned entry, else the newest pinned one — "what was just
    /// recorded" from a test's point of view.
    var mostRecentEntry: ClipboardEntry? {
        let entries = search(query: "")
        return entries.first { !$0.isPinned }
            ?? entries.filter(\.isPinned).max { $0.createdAt < $1.createdAt }
    }
}
