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

    /// The two halves of the in-memory mirror, as a consistency test needs to
    /// see them: whether a write that SQLite refused nonetheless moved a row
    /// between them. Read through `search` like the rest of this file, so a
    /// fixture that drops the table underneath the store still gets the
    /// mirror's answer rather than a query failure.
    var pinnedEntries: [ClipboardEntry] {
        search(query: "").filter(\.isPinned)
    }

    var unpinnedEntries: [ClipboardEntry] {
        search(query: "").filter { !$0.isPinned }
    }

    /// The newest unpinned entry, else the newest pinned one — "what was just
    /// recorded" from a test's point of view.
    var mostRecentEntry: ClipboardEntry? {
        let entries = search(query: "")
        return entries.first { !$0.isPinned }
            ?? entries.max { $0.createdAt < $1.createdAt }
    }
}
