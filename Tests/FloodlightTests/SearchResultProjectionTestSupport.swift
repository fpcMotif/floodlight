import FloodlightEngine
@testable import Floodlight

@MainActor
func projectResults(
    query: String,
    indexed: [SearchItem],
    apps: [SearchItem],
    system: [SearchItem],
    keywordEngines: [KeywordEngine] = KeywordEngineCatalog.all
) -> [SearchItem] {
    SearchResultProjection.project(
        .local(.init(
            query: query,
            candidates: apps + system + indexed,
            keywordLookup: KeywordEngineCatalog.makeLookup(for: keywordEngines),
            selectedFilter: .all,
            selection: nil,
            progress: .settled
        ))
    ).allRows
}
