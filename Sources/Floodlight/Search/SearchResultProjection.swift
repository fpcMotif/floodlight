import FloodlightEngine
import Foundation

struct SearchResultPublication: Equatable {
    let sourceCandidates: [SearchItem]
    let allRows: [SearchItem]
    let visibleRows: [SearchItem]
    let filterOptions: [SearchFilterOption]
    let selectedFilter: SearchResultFilter
    let selection: SearchResultSelection?
    let progress: SearchResultProgress

    func selecting(_ selection: SearchResultSelection?) -> SearchResultPublication {
        SearchResultPublication(
            sourceCandidates: sourceCandidates,
            allRows: allRows,
            visibleRows: visibleRows,
            filterOptions: filterOptions,
            selectedFilter: selectedFilter,
            selection: selection,
            progress: progress
        )
    }
}

struct SearchResultSelection: Equatable {
    enum Origin: Equatable {
        case automatic
        case user
    }

    let id: SearchItem.ID
    let origin: Origin
}

struct SearchResultProgress: Equatable {
    let isSearching: Bool
    let totalMatches: [SearchItemKind: Int]
    let pendingKinds: Set<SearchItemKind>

    static let settled = SearchResultProgress(
        isSearching: false,
        totalMatches: [:],
        pendingKinds: []
    )
}

enum SearchResultProjection {
    enum FilterContinuity: Equatable {
        case preserve
        case reconcileWhenSettled
    }

    enum Input {
        case local(LocalContext)
        case web(WebContext)
        case clipboard(ClipboardContext)
    }

    struct LocalContext {
        let query: String
        let candidates: [SearchItem]
        let keywordRegistry: KeywordEngineRegistry
        let selectedFilter: SearchResultFilter
        let selection: SearchResultSelection?
        let progress: SearchResultProgress
        let filterContinuity: FilterContinuity
        /// The folder row for a path-like query, already resolved against the
        /// committed scope by whoever built this context. Projection never
        /// touches the disk itself: it is a pure function of its inputs, and
        /// it runs several times per keystroke.
        let resolvedFolderRow: SearchItem?

        init(
            query: String,
            candidates: [SearchItem],
            keywordRegistry: KeywordEngineRegistry,
            selectedFilter: SearchResultFilter,
            selection: SearchResultSelection?,
            progress: SearchResultProgress,
            filterContinuity: FilterContinuity = .reconcileWhenSettled,
            resolvedFolderRow: SearchItem? = nil
        ) {
            self.query = query
            self.candidates = candidates
            self.keywordRegistry = keywordRegistry
            self.selectedFilter = selectedFilter
            self.selection = selection
            self.progress = progress
            self.filterContinuity = filterContinuity
            self.resolvedFolderRow = resolvedFolderRow
        }
    }

    struct WebContext {
        let query: String
        let activeEngineID: String
        let keywordRegistry: KeywordEngineRegistry
        let selectedFilter: SearchResultFilter
        let selection: SearchResultSelection?
    }

    struct ClipboardContext: Equatable {
        let entries: [ClipboardEntry]
        var selectedFilter: SearchResultFilter = .all
        let selection: SearchResultSelection?
        var now: Date = .now
    }

    static func project(_ input: Input) -> SearchResultPublication {
        switch input {
        case let .local(context): projectLocal(context)
        case let .web(context): projectWeb(context)
        case let .clipboard(context): projectClipboard(context)
        }
    }

    private static let emptyFilterOptions = SearchResultFilter.primary.map {
        SearchFilterOption(filter: $0, count: 0, isLoading: false)
    }

    static let emptyLocal = SearchResultPublication(
        sourceCandidates: [],
        allRows: [],
        visibleRows: [],
        filterOptions: emptyFilterOptions,
        selectedFilter: .all,
        selection: nil,
        progress: .settled
    )

    private static func projectLocal(_ context: LocalContext) -> SearchResultPublication {
        if context.query.isEmpty,
           context.candidates.isEmpty,
           context.selectedFilter == .all,
           context.progress == .settled,
           context.selection == nil
        {
            return emptyLocal
        }
        let allRows = buildLocalRows(context)
        let counts = SearchFilterCounts(items: allRows)
        var selectedFilter = context.selectedFilter
        if context.filterContinuity == .reconcileWhenSettled,
           selectedFilter.isDynamic,
           counts[selectedFilter] == 0,
           !isLoading(selectedFilter, progress: context.progress)
        {
            selectedFilter = .all
        }
        let visibleRows = allRows.filter(selectedFilter.includes)
        let selection = reconcile(context.selection, in: visibleRows)
        let options = filterOptions(
            counts: counts,
            selectedFilter: selectedFilter,
            progress: context.progress
        )
        return SearchResultPublication(
            sourceCandidates: context.candidates,
            allRows: allRows,
            visibleRows: visibleRows,
            filterOptions: options,
            selectedFilter: selectedFilter,
            selection: selection,
            progress: context.progress
        )
    }

    private static func projectWeb(_ context: WebContext) -> SearchResultPublication {
        let rows = context.keywordRegistry.webModeResults(
            for: context.query,
            activeEngineID: context.activeEngineID
        )
        return SearchResultPublication(
            sourceCandidates: [],
            allRows: rows,
            visibleRows: rows,
            filterOptions: [],
            selectedFilter: context.selectedFilter,
            selection: reconcile(context.selection, in: rows),
            progress: .settled
        )
    }

    private static func projectClipboard(_ context: ClipboardContext) -> SearchResultPublication {
        clipboardPublication(
            rows: clipboardRows(entries: context.entries, now: context.now),
            selectedFilter: context.selectedFilter,
            selection: context.selection
        )
    }

    /// The board's rows for `entries`, in order, aged against `now` — the
    /// half of a clipboard projection that costs anything, which is why
    /// Clipboard Search keeps a publication's `allRows` across chip
    /// switches (#73). Pure: every fact a row needs is already on its
    /// entry, so nothing here parses text or touches the filesystem.
    private static func clipboardRows(entries: [ClipboardEntry], now: Date) -> [SearchItem] {
        entries.enumerated().map { index, entry in
            buildClipboardRow(entry: entry, index: index, now: now)
        }
    }

    /// Scopes `rows` to `selectedFilter`, counts every chip, and reconciles
    /// `selection` against what is visible — the cheap half, which Clipboard
    /// Search reruns over a kept publication's `allRows` when nothing the
    /// rows depend on has changed.
    static func clipboardPublication(
        rows: [SearchItem],
        selectedFilter: SearchResultFilter,
        selection: SearchResultSelection?
    ) -> SearchResultPublication {
        let selectedFilter = SearchResultFilter.clipboard.contains(selectedFilter)
            ? selectedFilter
            : .all
        let visibleRows = rows.filter { clipboardFilter(selectedFilter, includes: $0) }
        return SearchResultPublication(
            sourceCandidates: [],
            allRows: rows,
            visibleRows: visibleRows,
            filterOptions: clipboardFilterOptions(rows: rows),
            selectedFilter: selectedFilter,
            selection: reconcile(selection, in: visibleRows),
            progress: .settled
        )
    }

    private static func clipboardFilter(
        _ filter: SearchResultFilter,
        includes row: SearchItem
    ) -> Bool {
        switch filter {
        case .all:
            true
        case .text:
            if case .copy = row.action { true } else { false }
        case .files:
            if case .copyFiles = row.action { true } else { false }
        case .images:
            if case .copyImage = row.action { true } else { false }
        default:
            false
        }
    }

    /// A row's action says which chip it belongs to, the same way
    /// `clipboardFilter` decides membership, so the counts and the scoped
    /// rows can never disagree.
    private static func clipboardFilterOptions(rows: [SearchItem]) -> [SearchFilterOption] {
        var text = 0
        var files = 0
        var images = 0
        for row in rows {
            switch row.action {
            case .copy: text += 1
            case .copyFiles: files += 1
            case .copyImage: images += 1
            default: break
            }
        }
        let counts: [SearchResultFilter: Int] = [
            .all: rows.count,
            .text: text,
            .files: files,
            .images: images,
        ]
        return SearchResultFilter.clipboard.map { filter in
            SearchFilterOption(
                filter: filter,
                count: counts[filter, default: 0],
                isLoading: false
            )
        }
    }

    /// Row identity is Clipboard Search's to assign — `ClipboardSearch.rowID(
    /// forEntryID:)` is the one spelling — so a row built here maps back to
    /// its entry only through Clipboard Search.
    private static func buildClipboardRow(
        entry: ClipboardEntry,
        index: Int,
        now: Date
    ) -> SearchItem {
        switch entry.kind {
        case .file:
            buildClipboardFileRow(entry: entry, index: index, now: now)
        case .text:
            buildClipboardTextRow(entry: entry, index: index, now: now)
        case .image:
            buildClipboardImageRow(entry: entry, index: index, now: now)
        }
    }

    /// The icon is the entry's stored classification read back, never the
    /// text parsed again: what the list shows and what the inspector says
    /// come from the one decision capture made (#73).
    private static func buildClipboardTextRow(
        entry: ClipboardEntry,
        index: Int,
        now: Date
    ) -> SearchItem {
        if case let .path(path) = entry.textContent {
            return buildClipboardPathRow(entry: entry, path: path, index: index, now: now)
        }

        let iconSource: SearchItemIconSource = switch entry.textContent {
        case .link: .engine(symbol: "link", tint: .blue)
        case .color: .engine(symbol: "paintpalette.fill", tint: .purple)
        case .code: .engine(symbol: "curlybraces", tint: .cyan)
        case .plain, .path, nil: .engine(symbol: "doc.text", tint: .gray)
        }
        return SearchItem(
            id: ClipboardSearch.rowID(forEntryID: entry.id),
            title: previewTitle(for: entry.text),
            subtitle: clipboardSubtitle(entry: entry, now: now, detail: nil),
            kind: .clipboard,
            action: .copy(entry.text),
            iconSource: iconSource,
            score: SearchItemRanking.calculator - index,
            modifiedAt: entry.createdAt,
            isPinned: entry.isPinned
        )
    }

    /// Copied text that names a local file reads as that file whether or not
    /// anything is still at the path: history records what was copied. The
    /// row carries the URL; whether it can be opened is decided when the row
    /// is selected, which is the one place that stats it.
    private static func buildClipboardPathRow(
        entry: ClipboardEntry,
        path: ClipboardPathContent,
        index: Int,
        now: Date
    ) -> SearchItem {
        let iconSource: SearchItemIconSource = if pathRowImageExtensions
            .contains(path.fileExtension)
        {
            .engine(symbol: "photo", tint: .cyan)
        } else if pathRowVideoExtensions.contains(path.fileExtension) {
            .engine(symbol: "video.fill", tint: .purple)
        } else {
            .inferred
        }
        return SearchItem(
            id: ClipboardSearch.rowID(forEntryID: entry.id),
            title: path.name.isEmpty ? entry.text : path.name,
            subtitle: clipboardSubtitle(entry: entry, now: now, detail: path.parentFolderName),
            kind: .clipboard,
            action: .copy(entry.text),
            iconSource: iconSource,
            score: SearchItemRanking.calculator - index,
            fileURL: path.url,
            modifiedAt: entry.createdAt,
            isPinned: entry.isPinned
        )
    }

    private static let pathRowImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "svg",
    ]
    private static let pathRowVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi",
    ]

    private static func buildClipboardFileRow(
        entry: ClipboardEntry,
        index: Int,
        now: Date
    ) -> SearchItem {
        let path = ClipboardPathContent(url: URL(fileURLWithPath: entry.text))

        return SearchItem(
            id: ClipboardSearch.rowID(forEntryID: entry.id),
            title: path.name.isEmpty ? entry.text : path.name,
            subtitle: clipboardSubtitle(entry: entry, now: now, detail: path.parentFolderName),
            kind: .clipboard,
            action: .copyFiles([entry.text]),
            iconSource: .inferred,
            score: SearchItemRanking.calculator - index,
            fileURL: path.url,
            isPinned: entry.isPinned
        )
    }

    private static func buildClipboardImageRow(
        entry: ClipboardEntry,
        index: Int,
        now: Date
    ) -> SearchItem {
        let title = entry.text.isEmpty ? "Image" : entry.text
        let dimensions = entry.image.map { "\($0.width)×\($0.height)" }
        let iconSource: SearchItemIconSource = if let thumbnail = entry.image?.thumbnailPNGData,
                                                  !thumbnail.isEmpty
        {
            .thumbnail(thumbnail)
        } else {
            .engine(symbol: "photo", tint: .gray)
        }

        return SearchItem(
            id: ClipboardSearch.rowID(forEntryID: entry.id),
            title: title,
            subtitle: clipboardSubtitle(entry: entry, now: now, detail: dimensions),
            kind: .clipboard,
            action: .copyImage(id: entry.id),
            iconSource: iconSource,
            score: SearchItemRanking.calculator - index,
            fileSize: entry.image.map { UInt64($0.byteCount) },
            isPinned: entry.isPinned
        )
    }

    /// Every clipboard row reads the same way — source app, then age, then
    /// one kind-specific detail (parent folder, image dimensions) — so the
    /// eye finds the same fact in the same place on every row. The full
    /// path and byte size live in the inspector beside the list.
    private static func clipboardSubtitle(
        entry: ClipboardEntry,
        now: Date,
        detail: String?
    ) -> String {
        let app = ClipboardSourceApp.displayName(for: entry.sourceAppBundleID)
        let time = formattedRelativeTime(since: entry.createdAt, now: now)
        guard let detail, !detail.isEmpty else { return "\(app) · \(time)" }
        return "\(app) · \(time) · \(detail)"
    }

    /// One line for the row: the entry's lines joined by single spaces, empty
    /// lines dropped, the ends trimmed — exactly what splitting on
    /// `Character.isNewline` and joining produces, done over the UTF-8 bytes.
    /// A grapheme walk over a 20 KB entry is hundreds of microseconds, and
    /// it ran per row per keystroke; a byte scan is a few (#73).
    private static func previewTitle(for text: String) -> String {
        // Most entries have no newline at all, and for them the title is the
        // text itself: one scan of the string's own buffer, no copy.
        var scanned = text
        let collapsed = scanned.withUTF8 { bytes -> String? in
            var index = 0
            while index < bytes.count, newlineLength(in: bytes, at: index) == 0 {
                index += 1
            }
            return index < bytes.count ? collapseLines(bytes) : nil
        }
        var singleLine = collapsed ?? text
        // Trimming bridges through NSString on every row; it can only change
        // anything when an end byte is a tab, a space, or part of a
        // non-ASCII scalar (every other Unicode space is one).
        if let first = singleLine.utf8.first, let last = singleLine.utf8.last,
           mayBeWhitespace(first) || mayBeWhitespace(last)
        {
            singleLine = singleLine.trimmingCharacters(in: .whitespaces)
        }
        return singleLine.isEmpty ? "(Empty text)" : singleLine
    }

    /// `bytes` with each run of newlines replaced by one space, and leading
    /// and trailing newlines dropped — what splitting on newlines, omitting
    /// empty pieces, and joining with a space produces.
    private static func collapseLines(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        var collapsed: [UInt8] = []
        collapsed.reserveCapacity(bytes.count)
        var separatorPending = false
        var index = 0
        while index < bytes.count {
            let newlineLength = newlineLength(in: bytes, at: index)
            if newlineLength > 0 {
                separatorPending = !collapsed.isEmpty
                index += newlineLength
                continue
            }
            if separatorPending {
                collapsed.append(0x20)
                separatorPending = false
            }
            collapsed.append(bytes[index])
            index += 1
        }
        // Not `String(bytes:encoding: .utf8)`, which the lint rule would
        // otherwise prefer: it strips a leading U+FEFF as a byte-order mark,
        // and the Character walk this replaces kept it. `decoding:` copies
        // the bytes as they are, and they are whole scalars of valid UTF-8.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: collapsed, as: UTF8.self)
    }

    private static func mayBeWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x20 || byte >= 0x80
    }

    /// The byte length of the newline scalar at `index`, or 0. The set is
    /// `Character.isNewline`'s — U+000A through U+000D, U+0085, U+2028,
    /// U+2029 — and every one of them starts its own grapheme, so scanning
    /// scalars decides exactly what scanning Characters would.
    private static func newlineLength(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        switch bytes[index] {
        case 0x0A...0x0D:
            1
        case 0xC2 where index + 1 < bytes.count && bytes[index + 1] == 0x85:
            2
        case 0xE2 where index + 2 < bytes.count && bytes[index + 1] == 0x80
            && (bytes[index + 2] == 0xA8 || bytes[index + 2] == 0xA9):
            3
        default:
            0
        }
    }

    private static func formattedRelativeTime(since date: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(date)))
        if elapsed < 60 {
            return "just now"
        }
        let minutes = elapsed / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        let days = hours / 24
        if days < 30 {
            return "\(days)d"
        }
        let months = days / 30
        if months < 12 {
            return "\(months)mo"
        }
        let years = days / 365
        return "\(years)y"
    }

    private static let maxResultsLimit = 80

    private static func buildLocalRows(_ context: LocalContext) -> [SearchItem] {
        var output: [SearchItem] = []
        if let link = DirectLink.row(for: context.query) {
            output.append(link)
        }
        if let value = Calculator.evaluate(context.query) {
            let answer = Calculator.format(value)
            output.append(SearchItem(
                id: "calculator",
                title: answer,
                subtitle: "\(context.query) = \(answer) · Press Return to copy",
                kind: .calculator,
                action: .copy(answer),
                score: SearchItemRanking.calculator
            ))
        }
        if let item = context.keywordRegistry.addressedResult(for: context.query) {
            output.append(item)
        }
        if let folderRow = context.resolvedFolderRow {
            output.append(folderRow)
        }
        output.append(contentsOf: context.candidates)

        var seen = Set<SearchItem.ID>()
        output.removeAll { !seen.insert($0.id).inserted }

        let fallback = !context.query.isEmpty
            ? context.keywordRegistry.defaultWebResult(for: context.query)
            : nil
        let localLimit = fallback != nil ? maxResultsLimit - 1 : maxResultsLimit
        var ranked = SearchItemRanking.topRankedInPlace(&output, limit: localLimit)

        if let fallback, !seen.contains(fallback.id) {
            ranked.append(fallback)
        }

        return ranked
    }

    private static func reconcile(
        _ selection: SearchResultSelection?,
        in rows: [SearchItem]
    ) -> SearchResultSelection? {
        guard let first = rows.first else { return nil }
        guard let selection else {
            return SearchResultSelection(id: first.id, origin: .automatic)
        }
        if selection.origin == .automatic,
           selection.id == "web-search",
           first.id != "web-search"
        {
            return SearchResultSelection(id: first.id, origin: .automatic)
        }
        if rows.contains(where: { $0.id == selection.id }) { return selection }
        return SearchResultSelection(id: first.id, origin: .automatic)
    }

    private static func filterOptions(
        counts: SearchFilterCounts,
        selectedFilter: SearchResultFilter,
        progress: SearchResultProgress
    ) -> [SearchFilterOption] {
        let option: (SearchResultFilter) -> SearchFilterOption = { filter in
            let visibleCount = counts[filter]
            let count = switch filter {
            case .applications:
                max(progress.totalMatches[.application, default: 0], visibleCount)
            case .settings:
                max(progress.totalMatches[.systemSetting, default: 0], visibleCount)
            default:
                visibleCount
            }
            return SearchFilterOption(
                filter: filter,
                count: count,
                isLoading: isLoading(filter, progress: progress)
            )
        }
        return SearchResultFilter.primary.map(option) + SearchResultFilter.dynamic.compactMap {
            let value = option($0)
            return !value.isEmpty || selectedFilter == $0 ? value : nil
        }
    }

    private static func isLoading(
        _ filter: SearchResultFilter,
        progress: SearchResultProgress
    ) -> Bool {
        switch filter {
        case .all:
            progress.isSearching
                || progress.pendingKinds.contains(.application)
                || progress.pendingKinds.contains(.systemSetting)
        case .applications:
            progress.pendingKinds.contains(.application)
        case .files, .folders, .pdfs, .images, .documents:
            progress.isSearching
        case .settings:
            progress.pendingKinds.contains(.systemSetting)
        case .text:
            false
        }
    }
}
