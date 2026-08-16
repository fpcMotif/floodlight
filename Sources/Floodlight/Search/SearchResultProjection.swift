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
        }
    }
}
