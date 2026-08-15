import AppKit
import FloodlightEngine
import FloodlightTestSupport
import Foundation
import SwiftUI
import XCTest
@testable import Floodlight

/// Renders the real SwiftUI hierarchy — `SearchView`, `ResultRow`,
/// `KeyChip` — through `ImageRenderer` and `NSHostingView`, at the sizes
/// the panel actually uses.
///
/// These are not pixel snapshots; they are crash-and-layout tests. A
/// SwiftUI view that traps on a nil unwrap, recurses through an ambiguous
/// layout, or blows up on a 4_000-character title fails here rather than in
/// front of a user, and every state the panel can be in gets rendered at
/// least once.
@MainActor
final class SearchViewRenderingTests: XCTestCase {
    private nonisolated(unsafe) var tree: TemporaryTree!

    override func setUpWithError() throws {
        tree = try TemporaryTree(label: "SearchViewRendering")
    }

    override func tearDown() {
        tree = nil
    }

    private func makeCoordinator(
        applications: ScriptedCatalog = ScriptedCatalog(),
        settings: ScriptedCatalog = ScriptedCatalog()
    ) throws -> SearchCoordinator {
        try SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: applications,
                settings: settings
            ),
            recentStore: RecentStore(defaults: IsolatedDefaults().defaults),
            rootURL: tree.root,
            assistantRunner: ScriptedAssistantRunner(),
            onDismiss: {}
        )
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never became true: \(description)", file: file, line: line)
    }

    /// Rasterizes `view` at an explicit size and returns the image, failing
    /// the test if SwiftUI could not produce one.
    private func render(
        _ view: some View,
        width: CGFloat,
        height: CGFloat,
        colorScheme: ColorScheme = .dark,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> CGImage {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width, height: height)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage, file: file, line: line)
    }

    /// Mounts `view` in a real hosting view and forces a layout pass — a
    /// stricter check than `ImageRenderer`, since it exercises the AppKit
    /// bridge that `NSViewRepresentable` rows depend on.
    @discardableResult
    private func layout(
        _ view: some View,
        width: CGFloat,
        height: CGFloat
    ) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()
        return hosting
    }

    // MARK: - SearchView

    func testTheCollapsedPanelRendersAtTheSearchBarHeight() throws {
        let coordinator = try makeCoordinator()

        let image = try render(
            SearchView(model: coordinator),
            width: FloodlightMetrics.panelWidth,
            height: FloodlightMetrics.panelHeight(hasQuery: false)
        )

        XCTAssertEqual(image.width, Int(FloodlightMetrics.panelWidth))
        XCTAssertEqual(image.height, Int(FloodlightMetrics.searchHeight))
    }

    func testThePopulatedPanelRendersAtTheExpandedHeight() async throws {
        let applications = ScriptedCatalog(
            immediate: (0..<12).map {
                SearchFixtures.application(
                    id: "app:\($0)",
                    name: "Application \($0)",
                    score: 120_000 - $0
                )
            }
        )
        let coordinator = try makeCoordinator(applications: applications)
        coordinator.query = "application"
        try await waitUntil("application candidates arrive") {
            !coordinator.results.isEmpty
        }

        XCTAssertFalse(coordinator.results.isEmpty)
        let image = try render(
            SearchView(model: coordinator),
            width: FloodlightMetrics.panelWidth,
            height: FloodlightMetrics.panelHeight(hasQuery: true)
        )

        XCTAssertEqual(image.width, Int(FloodlightMetrics.panelWidth))
        XCTAssertEqual(image.height, Int(FloodlightMetrics.expandedPanelHeight))
    }

    func testTheWebModePanelRendersWithoutTheFilterBar() throws {
        // Web mode publishes no filter options, so the section drops the
        // chip bar and hands its height to the results — render that path
        // at the panel's real size to catch a layout that traps.
        let coordinator = try makeCoordinator()
        coordinator.query = "yt lofi"
        coordinator.handleTab()

        XCTAssertTrue(coordinator.filterOptions.isEmpty)
        XCTAssertFalse(coordinator.results.isEmpty)
        let image = try render(
            SearchView(model: coordinator),
            width: FloodlightMetrics.panelWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )
        XCTAssertEqual(image.width, Int(FloodlightMetrics.panelWidth))
        XCTAssertEqual(image.height, Int(FloodlightMetrics.expandedPanelHeight))
    }

    func testTheEmptyFilterStateRenders() throws {
        // A filter with no matches is the one branch that renders
        // `EmptyResultsView` instead of the list.
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode")]
        )
        let coordinator = try makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        coordinator.selectFilter(.folders)

        XCTAssertTrue(coordinator.results.isEmpty)
        _ = try render(
            SearchView(model: coordinator),
            width: FloodlightMetrics.panelWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )
    }

    func testThePanelRendersInBothColorSchemes() throws {
        let applications = ScriptedCatalog(
            immediate: [SearchFixtures.application(name: "Xcode", score: 120_000)]
        )
        let coordinator = try makeCoordinator(applications: applications)
        coordinator.query = "xcode"

        for scheme in [ColorScheme.light, .dark] {
            let image = try render(
                SearchView(model: coordinator),
                width: FloodlightMetrics.panelWidth,
                height: FloodlightMetrics.expandedPanelHeight,
                colorScheme: scheme
            )
            XCTAssertEqual(image.width, Int(FloodlightMetrics.panelWidth))
        }
    }

    func testTheLargestReachableResultSetRendersWithinBudget() async throws {
        // Rendering the widest set the pipeline can publish catches a layout
        // that is accidentally O(n²) before it reaches the panel.
        //
        // Note the ceiling: the coordinator pages each source (12
        // applications, 24 settings), so the panel tops out well below the
        // 80-row merge cap no matter how much a catalog returns.
        let applications = ScriptedCatalog(
            immediate: (0..<80).map {
                SearchFixtures.application(
                    id: "app:\($0)",
                    name: "Application \($0)",
                    score: 120_000 - $0
                )
            }
        )
        let settings = ScriptedCatalog(
            immediate: (0..<40).map {
                SearchFixtures.setting(
                    id: "setting:\($0)",
                    title: "Setting \($0)",
                    score: 11_000 - $0
                )
            }
        )
        let coordinator = try makeCoordinator(applications: applications, settings: settings)
        coordinator.query = "a"
        try await waitUntil("the large result set arrives") {
            coordinator.results.count > FloodlightMetrics.maximumVisibleResults
        }
        XCTAssertGreaterThan(coordinator.results.count, FloodlightMetrics.maximumVisibleResults)

        let start = ContinuousClock.now
        _ = try render(
            SearchView(model: coordinator),
            width: FloodlightMetrics.panelWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )
        XCTAssertLessThan(start.duration(to: .now), .seconds(10))
    }

    func testThePanelRendersEveryResultKind() throws {
        // One row of each kind at once, so every icon, tint, and badge
        // branch in `ResultRow` is exercised in a single layout.
        let mixed: [SearchItem] = [
            SearchFixtures.application(name: "Xcode", score: 120_000),
            SearchFixtures.file(name: "notes.txt", score: 110_000),
            SearchFixtures.folder(name: "code", score: 100_000),
            SearchFixtures.setting(title: "Keyboard", score: 90_000),
            SearchFixtures.calculator(),
            SearchFixtures.assistant(),
            SearchFixtures.web(score: 10),
        ]
        let coordinator = try makeCoordinator(
            applications: ScriptedCatalog(immediate: mixed)
        )
        coordinator.query = "everything"

        _ = try render(
            SearchView(model: coordinator),
            width: FloodlightMetrics.panelWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )
    }

    func testThePanelMountsInARealHostingView() throws {
        let coordinator = try makeCoordinator(
            applications: ScriptedCatalog(immediate: [SearchFixtures.application(name: "Xcode")])
        )
        coordinator.query = "xcode"

        let hosting = layout(
            SearchView(model: coordinator),
            width: FloodlightMetrics.panelWidth,
            height: FloodlightMetrics.expandedPanelHeight
        )

        XCTAssertEqual(hosting.frame.width, FloodlightMetrics.panelWidth)
        XCTAssertFalse(hosting.subviews.isEmpty, "the hosting view produced no content")
    }

    // MARK: - ResultRow

    private func renderRow(
        _ item: SearchItem,
        isSelected: Bool = false,
        isTopHit: Bool = false,
        assistantState: AssistantAnswerState? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        _ = try render(
            ResultRow(
                item: item,
                isSelected: isSelected,
                isTopHit: isTopHit,
                assistantState: assistantState
            ),
            width: FloodlightMetrics.panelWidth - FloodlightMetrics.resultPadding * 2,
            height: FloodlightMetrics.resultRowHeight,
            file: file,
            line: line
        )
    }

    func testEveryRowKindRendersSelectedAndUnselected() throws {
        let items: [SearchItem] = [
            SearchFixtures.application(name: "Xcode"),
            SearchFixtures.file(name: "notes.txt", modifiedAt: .now, fileSize: 12_345),
            SearchFixtures.folder(name: "code"),
            SearchFixtures.setting(title: "Keyboard"),
            SearchFixtures.calculator(),
            SearchFixtures.assistant(),
            SearchFixtures.web(),
        ]

        for item in items {
            for isSelected in [true, false] {
                for isTopHit in [true, false] {
                    try renderRow(item, isSelected: isSelected, isTopHit: isTopHit)
                }
            }
        }
    }

    func testTheAssistantRowRendersEveryAnswerState() throws {
        let row = SearchFixtures.assistant()
        for state: AssistantAnswerState in [
            .running,
            .answered("A short answer."),
            .answered(String(repeating: "A very long answer that wraps. ", count: 40)),
            .answered(""),
            .failed("claude isn't installed."),
            .failed(""),
        ] {
            try renderRow(row, isSelected: true, assistantState: state)
        }
    }

    func testRowsSurviveHostileTitlesAndSubtitles() throws {
        // Titles come from file names, so they carry emoji, RTL overrides,
        // and 1_000-character monsters. None may break layout.
        for text in AdversarialCorpus.strings {
            let item = SearchItem(
                id: "hostile:\(text.hashValue)",
                title: text,
                subtitle: text,
                kind: .file,
                action: .copy(text),
                score: 0,
                fileURL: URL(fileURLWithPath: "/tmp/x.txt"),
                modifiedAt: .now,
                fileSize: 4_096
            )
            try renderRow(item, isSelected: true, isTopHit: true)
        }
    }

    func testRowEqualityDrivesTheRedrawDecision() {
        // `ResultRow` is `Equatable` and used with `.equatable()`, so an
        // incorrect `==` would either freeze rows or defeat the
        // optimization entirely.
        let item = SearchFixtures.application(name: "Xcode")
        let base = ResultRow(item: item, isSelected: false, isTopHit: false, assistantState: nil)

        XCTAssertEqual(
            base,
            ResultRow(item: item, isSelected: false, isTopHit: false, assistantState: nil)
        )
        XCTAssertNotEqual(
            base,
            ResultRow(item: item, isSelected: true, isTopHit: false, assistantState: nil)
        )
        XCTAssertNotEqual(
            base,
            ResultRow(item: item, isSelected: false, isTopHit: true, assistantState: nil)
        )
        XCTAssertNotEqual(
            base,
            ResultRow(item: item, isSelected: false, isTopHit: false, assistantState: .running)
        )
        XCTAssertNotEqual(
            base,
            ResultRow(
                item: SearchFixtures.application(name: "Xcode Beta"),
                isSelected: false,
                isTopHit: false,
                assistantState: nil
            )
        )
    }

    func testARowWithNoMetadataRendersWithoutTheDotSeparators() throws {
        // `fileSize == 0` and a nil date both suppress their segment; a row
        // showing a bare "·" would be a visible bug.
        try renderRow(
            SearchItem(
                id: "bare",
                title: "Bare",
                subtitle: "no metadata",
                kind: .file,
                action: .copy("Bare"),
                score: 0,
                fileURL: URL(fileURLWithPath: "/tmp/bare"),
                modifiedAt: nil,
                fileSize: 0
            )
        )
    }

    // MARK: - KeyChip

    func testTheKeyChipRendersInBothOfItsForms() throws {
        _ = try render(KeyChip(symbolName: "return"), width: 40, height: 24)
        _ = try render(KeyChip(label: "⌘K"), width: 40, height: 24)
        _ = try render(KeyChip(label: ""), width: 40, height: 24)
        _ = try render(KeyChip(symbolName: "not.a.real.symbol.name"), width: 40, height: 24)
    }

    func testEveryShippingEngineSymbolResolvesToARealSFImage() {
        // An unknown symbol name renders as an empty tile — the row looks
        // broken rather than merely plain, so the catalog's names are
        // pinned against NSImage's resolver.
        for engine in KeywordEngineCatalog.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: engine.symbolName, accessibilityDescription: nil),
                "\(engine.id)'s symbolName must be a real SF Symbol"
            )
        }
    }

    // MARK: - Accessibility

    func testEveryResultKindExposesANonEmptyAccessibilityLabel() {
        // The row's accessibility label is its title and the hint names the
        // kind, so an empty label would make a row unreachable by
        // VoiceOver. Checked on the model the view reads from.
        for kind in [
            SearchItemKind.application,
            .assistant,
            .calculator,
            .file,
            .folder,
            .systemSetting,
            .web,
        ] {
            XCTAssertFalse(kind.label.isEmpty, kind.rawValue)
            XCTAssertFalse(
                "Select \(kind.label). Double-click or press Return to open.".isEmpty
            )
        }
    }

    func testTheFilterChipsExposeSettledCounts() async throws {
        let applications = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode")],
                totalMatched: 7
            )
        )
        let coordinator = try makeCoordinator(applications: applications)
        coordinator.query = "xcode"
        try await waitUntil("the application count settles") {
            coordinator.filterOptions.first { $0.filter == .applications }?.count == 7
                && !coordinator.isSearching
        }

        let option = try XCTUnwrap(
            coordinator.filterOptions.first { $0.filter == .applications }
        )
        // These are the exact values `SearchFilterChip` renders as its
        // accessibility value.
        XCTAssertEqual(option.count, 7)
        XCTAssertFalse(option.isLoading)
        XCTAssertEqual(option.filter.title, "Apps")
    }

    // MARK: - Layout metrics the views depend on

    func testTheResultsRegionExactlyFillsTheExpandedPanel() {
        // `SearchResultsSection` derives its height by subtraction. If these
        // stop adding up, the list is clipped or the panel gains a gap.
        let resultsHeight = FloodlightMetrics.expandedPanelHeight
            - FloodlightMetrics.searchHeight
            - 1
            - FloodlightMetrics.filterBarHeight

        XCTAssertEqual(
            resultsHeight,
            FloodlightMetrics.resultPadding * 2
                + CGFloat(FloodlightMetrics.maximumVisibleResults) * FloodlightMetrics
                .resultRowHeight
        )
        XCTAssertGreaterThan(resultsHeight, 0)
    }
}
