import FloodlightEngine
@testable import Floodlight

@MainActor
func makeSearchCoordinatorWithInertPresentation(
    assistantRunner: any AssistantProcessRunning = AssistantProcessRunner()
) -> SearchCoordinator {
    SearchCoordinator(
        assistantRunner: assistantRunner,
        onDismiss: {}
    )
}

@MainActor
func projectResults(
    query: String,
    indexed: [SearchItem],
    apps: [SearchItem],
    system: [SearchItem],
    keywordRegistry: KeywordEngineRegistry = KeywordEngineRegistry(
        engines: KeywordEngineCatalog.all,
        defaultWebEngineID: KeywordEngineCatalog.defaultEngine.id
    )
) -> [SearchItem] {
    SearchResultProjection.project(
        .local(.init(
            query: query,
            candidates: apps + system + indexed,
            keywordRegistry: keywordRegistry,
            selectedFilter: .all,
            selection: nil,
            progress: .settled
        ))
    ).allRows
}
