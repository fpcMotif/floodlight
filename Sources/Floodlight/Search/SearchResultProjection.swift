import FloodlightEngine

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
    }

    struct LocalContext {
        let query: String
        let candidates: [SearchItem]
        let keywordLookup: [String: KeywordEngine]
        let selectedFilter: SearchResultFilter
        let selection: SearchResultSelection?
        let progress: SearchResultProgress
        let filterContinuity: FilterContinuity

        init(
            query: String,
            candidates: [SearchItem],
            keywordLookup: [String: KeywordEngine],
            selectedFilter: SearchResultFilter,
            selection: SearchResultSelection?,
            progress: SearchResultProgress,
            filterContinuity: FilterContinuity = .reconcileWhenSettled
        ) {
            self.query = query
            self.candidates = candidates
            self.keywordLookup = keywordLookup
            self.selectedFilter = selectedFilter
            self.selection = selection
            self.progress = progress
            self.filterContinuity = filterContinuity
        }
    }

    struct WebContext {
        let query: String
        let activeEngineID: String
        let engines: [KeywordEngine]
        let selectedFilter: SearchResultFilter
        let selection: SearchResultSelection?
    }

    static func project(_ input: Input) -> SearchResultPublication {
        switch input {
        case let .local(context): projectLocal(context)
        case let .web(context): projectWeb(context)
        }
    }

    private static func projectLocal(_ context: LocalContext) -> SearchResultPublication {
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
        var rows: [SearchItem] = []
        var position = 0
        for activePass in [true, false] {
            for engine in context.engines
                where (engine.id == context.activeEngineID) == activePass
            {
                if let url = engine.searchURL(for: context.query),
                   let title = engine.searchTitle(for: context.query)
                {
                    rows.append(SearchItem(
                        id: "web-mode:\(engine.id)",
                        title: title,
                        subtitle: "Open in your default browser",
                        kind: .web,
                        action: .open(url),
                        score: SearchItemRanking.keywordEngine - position
                    ))
                }
                position += 1
            }
        }
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
        output.append(contentsOf: FloodlightCommandCatalog.search(context.query))
        if let match = KeywordEngineCatalog.match(context.query, lookup: context.keywordLookup),
           let item = match.engine.makeSearchItem(remainder: match.remainder)
        {
            output.append(item)
        }
        output.append(contentsOf: context.candidates)

        let defaultEngine = KeywordEngineCatalog.defaultEngine
        if !context.query.isEmpty,
           let url = defaultEngine.searchURL(for: context.query),
           let title = defaultEngine.searchTitle(for: context.query)
        {
            let promoted = WebSearchIntent.shouldPromote(
                query: context.query,
                localMatchCount: context.candidates.count
            )
            output.append(SearchItem(
                id: "web-search",
                title: title,
                subtitle: "Open in your default browser",
                kind: .web,
                action: .open(url),
                score: promoted ? SearchItemRanking.webPromoted : SearchItemRanking.webFallback
            ))
        }

        var seen = Set<SearchItem.ID>()
        output.removeAll { !seen.insert($0.id).inserted }
        return SearchItemRanking.topRankedInPlace(&output, limit: 80)
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
        }
    }
}
