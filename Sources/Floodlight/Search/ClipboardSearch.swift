import FloodlightEngine
import Foundation
import Observation

/// What activating a Clipboard History entry puts back on the pasteboard: the
/// exact text, native file references, or the captured image's original PNG
/// and TIFF bytes. The Selected-Result Action performer asks for one of these
/// through a narrow outbound operation (ADR 0005), never for the store.
enum ClipboardRestorePayload: Equatable {
    case text(String)
    case files([String])
    case image(ClipboardImagePayload)
}

/// Clipboard Search: the part of a Search Session in Clipboard mode that turns
/// the query, filter, and selection into Clipboard Entry rows, the Clipboard
/// Inspector snapshot, pin and preview facts, and restore payloads, and
/// applies pin, unpin, and delete to Clipboard History (ADR 0008).
///
/// It decides no Search Mode transitions and is not a Search Source. The
/// Search Session asks it for a Result Publication, tells it where the
/// selection moved, and reads the facts it publishes about that selection;
/// no other part of the Search Session touches Clipboard History for search,
/// inspection, pinning, deletion, preview, or image payloads. (Clipboard
/// Capture writes the store, and the Configuration pane clears it; neither
/// is part of the session.)
@MainActor
@Observable
final class ClipboardSearch {
    /// Inspector snapshot for the selected entry, or `nil` when nothing is
    /// selected. Recomputed when the selection or the store changes — never
    /// inside a getter, so a view body asking never reads an image payload.
    private(set) var inspector: ClipboardInspector?

    /// Whether the selected entry is pinned — the Actions menu reads it to
    /// offer "Pin" or "Unpin". Refreshed from the store the moment a pin
    /// command is accepted, so it never lags the last thing the user did.
    private(set) var isSelectionPinned = false

    /// Whether Space and the board's Preview chip have anything to show for
    /// the selection. A published boolean, not a getter that stats the disk
    /// and writes a temporary file mid-layout (#72).
    private(set) var isSelectionPreviewable = false

    /// The selection's on-disk location, for "Show in Finder".
    private(set) var selectionFileURL: URL?

    /// Installed by the Search Session: runs after a command changed
    /// Clipboard History, so the session can ask for a fresh publication.
    /// Commands never publish rows themselves — a Result Publication has one
    /// owner (ADR 0002) — and the session never learns which command ran.
    @ObservationIgnored
    var historyDidChange: (@MainActor () -> Void)?

    @ObservationIgnored
    private let store: ClipboardHistoryStore
    @ObservationIgnored
    private let previewDirectory: URL
    @ObservationIgnored
    private let now: () -> Date
    /// The row the facts above were computed for. A republication whose
    /// selected row comes back byte-for-byte identical recomputes nothing;
    /// anything that changes the row — a new rank under a new query, a pin,
    /// a delete — does.
    @ObservationIgnored
    private var selectedItem: SearchItem?
    /// The entry behind that row, as the store last described it — what the
    /// commands apply to. `nil` once the row no longer resolves to an entry,
    /// which is how a second delete of the same row applies to nothing.
    @ObservationIgnored
    private var selectedEntry: ClipboardEntry?

    /// The rows of the last publication and what they were built from — one
    /// query deep (#73). A chip switch or a re-entry into Clipboard mode over
    /// unchanged history reuses them and reruns only the scoping; a
    /// keystroke (a new query) or any store write (a new mutation version)
    /// runs the whole projection again. Rows carry their age, so the key
    /// also holds the clock to the minute: across a chip switch an age can
    /// lag by less than the minute it is shown at, and never more.
    private struct RowMemo {
        let version: UInt64
        let query: String
        let minute: Int
        let rows: [SearchItem]
    }

    @ObservationIgnored
    private var rowMemo: RowMemo?

    /// `previewDirectory` is where the preview action materializes a captured
    /// image for Quick Look; `now` is the clock the rows' relative ages are
    /// read against. Both are injected so tests can pin them.
    init(
        store: ClipboardHistoryStore,
        previewDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FloodlightClipboardPreviews", isDirectory: true),
        now: @escaping () -> Date = { .now }
    ) {
        self.store = store
        self.previewDirectory = previewDirectory
        self.now = now
    }

    // MARK: - Row identity

    /// The row identifier a Clipboard History entry gets, and the way back
    /// out of it. Clipboard Search alone owns this mapping: Result Projection
    /// asks for a row's identifier when it builds the row, and the board's
    /// image cache asks for the entry behind a row, so the spelling lives
    /// here once rather than at every site that could drift from it.
    nonisolated static func rowID(forEntryID entryID: String) -> SearchItem.ID {
        rowIDPrefix + entryID
    }

    nonisolated static func entryID(forRowID rowID: SearchItem.ID) -> String? {
        guard rowID.hasPrefix(rowIDPrefix) else { return nil }
        return String(rowID.dropFirst(rowIDPrefix.count))
    }

    private nonisolated static let rowIDPrefix = "clipboard:"

    // MARK: - Publication

    /// The Result Publication for Clipboard mode: every entry matching
    /// `query`, scoped to `selectedFilter`, with `selection` reconciled
    /// against the visible rows. The facts published above are recomputed
    /// for whichever row that reconciliation lands on.
    func publication(
        query: String,
        selectedFilter: SearchResultFilter,
        selection: SearchResultSelection?
    ) -> SearchResultPublication {
        let publication = project(
            query: query,
            selectedFilter: selectedFilter,
            selection: selection
        )
        let selectedRow = publication.selection.flatMap { selection in
            publication.visibleRows.first { $0.id == selection.id }
        }
        selectionDidMove(to: selectedRow)
        return publication
    }

    /// The whole projection — the store search and every row — unless the
    /// last one was for this query over this history, in which case only
    /// the scoping reruns over its rows. The mutation version is the only
    /// fact about the store in the key: a stale row could only follow a
    /// write the store did not count, and it counts them all.
    private func project(
        query: String,
        selectedFilter: SearchResultFilter,
        selection: SearchResultSelection?
    ) -> SearchResultPublication {
        let now = now()
        // Read before the search: a write that lands between the two then
        // costs one needless rebuild, where the other order would keep rows
        // the write had already outdated.
        let version = store.mutationVersion
        let minute = Int((now.timeIntervalSinceReferenceDate / 60).rounded(.down))
        if let memo = rowMemo, memo.version == version, memo.query == query,
           memo.minute == minute
        {
            return SearchResultProjection.clipboardPublication(
                rows: memo.rows,
                selectedFilter: selectedFilter,
                selection: selection
            )
        }
        let publication = SearchResultProjection.project(
            .clipboard(.init(
                entries: store.search(query: query),
                selectedFilter: selectedFilter,
                selection: selection,
                now: now
            ))
        )
        rowMemo = RowMemo(version: version, query: query, minute: minute, rows: publication.allRows)
        return publication
    }

    /// The Search Session reports where its selection is now — after every
    /// arrow key or click that moves it without changing the rows, and with
    /// `nil` once it leaves Clipboard mode. The published facts follow.
    func selectionDidMove(to item: SearchItem?) {
        guard item != selectedItem else { return }
        selectedItem = item
        refreshSelectionFacts()
    }

    // MARK: - Commands

    /// Each command applies to the selected entry and reports whether the
    /// store accepted the write. A refused write changes nothing here and
    /// tells the session nothing, so the board keeps showing what is still
    /// on disk.
    @discardableResult
    func pinSelection() -> Bool {
        mutateSelection { store.pin(id: $0, date: now()) }
    }

    @discardableResult
    func unpinSelection() -> Bool {
        mutateSelection { store.unpin(id: $0) }
    }

    @discardableResult
    func togglePinSelection() -> Bool {
        isSelectionPinned ? unpinSelection() : pinSelection()
    }

    @discardableResult
    func deleteSelection() -> Bool {
        mutateSelection { store.delete(id: $0) }
    }

    private func mutateSelection(_ mutate: (String) -> Bool) -> Bool {
        guard let entry = selectedEntry, mutate(entry.id) else { return false }
        refreshSelectionFacts()
        historyDidChange?()
        return true
    }

    // MARK: - Payloads

    /// What restoring `entryID` to the pasteboard means, by entry kind, or
    /// `nil` for an entry the store no longer has or an image whose bytes
    /// are gone. Activation asks for it when a row names its entry instead
    /// of carrying the value — a captured image today; text and file rows
    /// carry theirs in the action — so this is the one payload read that
    /// path performs.
    func restorePayload(for entryID: String) -> ClipboardRestorePayload? {
        guard let entry = store.entry(id: entryID) else { return nil }
        switch entry.kind {
        case .text:
            return .text(entry.text)
        case .file:
            return .files([entry.text])
        case .image:
            return store.imageData(for: entryID).map(ClipboardRestorePayload.image)
        }
    }

    /// The full-size bytes of a captured image, for the inspector pane to
    /// draw once the stored thumbnail is already on screen. Nonisolated so
    /// the pane can read it off the main actor — one payload read per entry,
    /// started by the pane, never by a keystroke.
    nonisolated func fullImageData(for entryID: String) -> Data? {
        store.imageData(for: entryID).flatMap { $0.png ?? $0.tiff }
    }

    // MARK: - Preview

    /// The URL Quick Look opens for the selection, or `nil` if there is
    /// nothing to preview. For a captured image this *materializes* the
    /// temporary file Quick Look reads, so it is an action, not a question:
    /// ask `isSelectionPreviewable` to decide whether the affordance is live,
    /// and call this only once the user has actually pressed Space or
    /// Preview. Browsing entries then leaves nothing behind (#72).
    func materializePreviewURL() -> URL? {
        guard let item = selectedItem, isSelectionPreviewable else { return nil }
        if let selectionFileURL {
            return selectionFileURL
        }
        if case let .copyImage(entryID) = item.action {
            return materializeImagePreview(entryID: entryID)
        }
        return nil
    }

    private func materializeImagePreview(entryID: String) -> URL? {
        guard let payload = store.imageData(for: entryID) ?? thumbnailPayload(entryID: entryID)
        else {
            return nil
        }
        let data = payload.png ?? payload.tiff
        guard let data, !data.isEmpty else { return nil }
        let ext = payload.png != nil ? "png" : "tiff"
        try? FileManager.default.createDirectory(
            at: previewDirectory,
            withIntermediateDirectories: true
        )
        let fileURL = previewDirectory.appendingPathComponent("\(entryID).\(ext)")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
        }
        return fileURL
    }

    /// An image whose full payload is gone still previews as its thumbnail.
    private func thumbnailPayload(entryID: String) -> ClipboardImagePayload? {
        guard let thumbnail = store.entry(id: entryID)?.image?.thumbnailPNGData,
              !thumbnail.isEmpty
        else {
            return nil
        }
        return ClipboardImagePayload(png: thumbnail, tiff: nil)
    }

    // MARK: - Selection facts

    /// Recomputes every published fact for the selected row. Reading the
    /// entry from the store's in-memory window is what this costs; the image
    /// payload is never touched, which is what keeps it affordable on every
    /// selection move.
    private func refreshSelectionFacts() {
        selectedEntry = selectedItem
            .flatMap { Self.entryID(forRowID: $0.id) }
            .flatMap { store.entry(id: $0) }
        guard let item = selectedItem, let entry = selectedEntry else {
            inspector = nil
            isSelectionPinned = false
            isSelectionPreviewable = false
            selectionFileURL = nil
            return
        }

        // What the board needs to know is that a full-size payload exists,
        // never yet what it contains — and the entry already says so.
        // `recordImage` refuses to write an image row without a payload and
        // stores that payload's size, so a non-zero byte count *is* the
        // existence check. Asking SQLite again would be a query per selection
        // move for a fact already in hand.
        let hasFullImage = entry.kind == .image && (entry.image?.byteCount ?? 0) > 0
        inspector = ClipboardInspector.snapshot(for: entry, hasFullImage: hasFullImage)
        isSelectionPinned = entry.isPinned

        // Copied text that names a file carries its URL whether or not the
        // file is still there, because history records what was copied
        // (#73). This is the one stat on that path, paid per selection move
        // rather than per row per keystroke: it decides whether Space and
        // "Show in Finder" have anything to open. A copied file's row is
        // taken as it comes, as it always was.
        let fileURL: URL? = if case .path? = entry.textContent {
            item.fileURL.flatMap { url in
                FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        } else {
            item.fileURL
        }
        selectionFileURL = fileURL
        isSelectionPreviewable = fileURL != nil
            || Self.hasImageToPreview(entry: entry, hasFullImage: hasFullImage)
    }

    /// A captured image is previewable while it still has pixels to write —
    /// the full payload, or failing that the stored thumbnail.
    private static func hasImageToPreview(entry: ClipboardEntry, hasFullImage: Bool) -> Bool {
        guard entry.kind == .image else { return false }
        return hasFullImage || entry.image?.thumbnailPNGData.isEmpty == false
    }
}
