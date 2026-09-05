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
        let rootURL: URL?

        init(
            query: String,
            candidates: [SearchItem],
            keywordRegistry: KeywordEngineRegistry,
            selectedFilter: SearchResultFilter,
            selection: SearchResultSelection?,
            progress: SearchResultProgress,
            filterContinuity: FilterContinuity = .reconcileWhenSettled,
            rootURL: URL? = nil
        ) {
            self.query = query
            self.candidates = candidates
            self.keywordRegistry = keywordRegistry
            self.selectedFilter = selectedFilter
            self.selection = selection
            self.progress = progress
            self.filterContinuity = filterContinuity
            self.rootURL = rootURL
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
        let query: String
        let entries: [ClipboardEntry]
        let selectedFilter: SearchResultFilter
        let selection: SearchResultSelection?
        let now: Date

        init(
            query: String,
            entries: [ClipboardEntry],
            selectedFilter: SearchResultFilter = .all,
            selection: SearchResultSelection?,
            now: Date = .now
        ) {
            self.query = query
            self.entries = entries
            self.selectedFilter = selectedFilter
            self.selection = selection
            self.now = now
        }
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
        let rows = context.entries.enumerated().map { index, entry in
            buildClipboardRow(entry: entry, index: index, now: context.now)
        }
        let selectedFilter = SearchResultFilter.clipboard.contains(context.selectedFilter)
            ? context.selectedFilter
            : .all
        let visibleRows = rows.filter { clipboardFilter(selectedFilter, includes: $0) }
        return SearchResultPublication(
            sourceCandidates: [],
            allRows: rows,
            visibleRows: visibleRows,
            filterOptions: clipboardFilterOptions(entries: context.entries),
            selectedFilter: selectedFilter,
            selection: reconcile(context.selection, in: visibleRows),
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

    private static func clipboardFilterOptions(
        entries: [ClipboardEntry]
    ) -> [SearchFilterOption] {
        var text = 0
        var files = 0
        var images = 0
        for entry in entries {
            switch entry.kind {
            case .text: text += 1
            case .file: files += 1
            case .image: images += 1
            }
        }
        let counts: [SearchResultFilter: Int] = [
            .all: entries.count,
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

    private static func buildClipboardTextRow(
        entry: ClipboardEntry,
        index: Int,
        now: Date
    ) -> SearchItem {
        let text = entry.text
        if let localURL = ClipboardInspector.parseLocalPath(text) {
            let name = localURL.lastPathComponent
            let title = name.isEmpty ? text : name
            let subtitle = clipboardSubtitle(
                entry: entry,
                now: now,
                detail: parentFolderName(of: localURL)
            )
            let ext = localURL.pathExtension.lowercased()
            let iconSource: SearchItemIconSource = if [
                "png",
                "jpg",
                "jpeg",
                "heic",
                "webp",
                "gif",
                "tiff",
                "svg",
            ].contains(ext) {
                .engine(symbol: "photo", tint: .cyan)
            } else if ["mp4", "mov", "m4v", "webm", "mkv", "avi"].contains(ext) {
                .engine(symbol: "video.fill", tint: .purple)
            } else {
                .inferred
            }
            let exists = FileManager.default.fileExists(atPath: localURL.path)
            return SearchItem(
                id: "clipboard:\(entry.id)",
                title: title,
                subtitle: subtitle,
                kind: .clipboard,
                action: .copy(text),
                iconSource: iconSource,
                score: SearchItemRanking.calculator - index,
                fileURL: exists ? localURL : nil,
                modifiedAt: entry.createdAt,
                isPinned: entry.isPinned
            )
        }

        let title = previewTitle(for: text)
        let subtitle = clipboardSubtitle(entry: entry, now: now, detail: nil)
        let iconSource: SearchItemIconSource = if ClipboardInspector.parseURL(text) != nil {
            .engine(symbol: "link", tint: .blue)
        } else if ClipboardInspector.parseHexColor(text) != nil {
            .engine(symbol: "paintpalette.fill", tint: .purple)
        } else if ClipboardInspector.parseCodeHint(text) != nil {
            .engine(symbol: "curlybraces", tint: .cyan)
        } else {
            .engine(symbol: "doc.text", tint: .gray)
        }
        return SearchItem(
            id: "clipboard:\(entry.id)",
            title: title,
            subtitle: subtitle,
            kind: .clipboard,
            action: .copy(text),
            iconSource: iconSource,
            score: SearchItemRanking.calculator - index,
            modifiedAt: entry.createdAt,
            isPinned: entry.isPinned
        )
    }

    private static func buildClipboardFileRow(
        entry: ClipboardEntry,
        index: Int,
        now: Date
    ) -> SearchItem {
        let path = entry.text
        let fileURL = URL(fileURLWithPath: path)
        let name = fileURL.lastPathComponent

        return SearchItem(
            id: "clipboard:\(entry.id)",
            title: name.isEmpty ? path : name,
            subtitle: clipboardSubtitle(
                entry: entry,
                now: now,
                detail: parentFolderName(of: fileURL)
            ),
            kind: .clipboard,
            action: .copyFiles([path]),
            iconSource: .inferred,
            score: SearchItemRanking.calculator - index,
            fileURL: fileURL,
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
            id: "clipboard:\(entry.id)",
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
        let app = appDisplayName(for: entry.sourceAppBundleID)
        let time = formattedRelativeTime(since: entry.createdAt, now: now)
        guard let detail, !detail.isEmpty else { return "\(app) · \(time)" }
        return "\(app) · \(time) · \(detail)"
    }

    private static func parentFolderName(of url: URL) -> String? {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent == "/" || parent.isEmpty ? nil : parent
    }

    private static func previewTitle(for text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return singleLine.isEmpty ? "(Empty text)" : singleLine
    }

    private static func appDisplayName(for bundleID: String?) -> String {
        ClipboardSourceApp.displayName(for: bundleID)
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
        if let pathResult = PathNavigator.resolve(query: context.query, rootURL: context.rootURL) {
            output.append(pathResult.folderItem)
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
