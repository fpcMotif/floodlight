import FFFKit
import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest

/// Invariants of the search model: identity, filtering, counting, and the
/// one published ordering.
///
/// These are the rules the rest of the pipeline silently depends on. The
/// filter chips show `SearchFilterCounts`, the list shows
/// `filter(includes)`, and if those two ever disagree a chip reads "12" over
/// a list of nine. Rather than assert that on a handful of fixtures, the
/// properties below assert it for every combination the generators can
/// reach.
final class SearchModelInvariantTests: XCTestCase {
    // MARK: - Identity

    func testGeneratedIdentifiersEncodeKindTitleAndSubtitle() throws {
        try checkProperty(
            "a nil id falls back to kind:title:subtitle",
            Gen<String>.hostile,
            Gen<String>.hostile,
            runs: 300
        ) { title, subtitle in
            let item = SearchItem(
                title: title,
                subtitle: subtitle,
                kind: .file,
                action: .copy(title),
                score: 0
            )
            return item.id == "file:\(title):\(subtitle)"
        }
    }

    func testExplicitIdentifiersAreUsedVerbatim() throws {
        try checkProperty(
            "an explicit id is never rewritten",
            Gen<String>.hostile,
            runs: 300
        ) { identifier in
            SearchItem(
                id: identifier,
                title: "t",
                subtitle: "s",
                kind: .web,
                action: .copy("t"),
                score: 0
            ).id == identifier
        }
    }

    func testHashingAgreesWithEquality() throws {
        // `SearchItem` is `Hashable` and lands in a `Set` inside
        // `buildResults`' de-duplication, so a hash that disagreed with
        // equality would silently drop rows.
        try checkProperty(
            "equal items hash equally",
            SearchGenerators.item(),
            runs: 400
        ) { item in
            let copy = SearchItem(
                id: item.id,
                title: item.title,
                subtitle: item.subtitle,
                kind: item.kind,
                action: item.action,
                iconSource: item.iconSource,
                score: item.score,
                fileURL: item.fileURL,
                modifiedAt: item.modifiedAt,
                fileSize: item.fileSize
            )
            guard copy == item else { return false }
            return copy.hashValue == item.hashValue && Set([item, copy]).count == 1
        }
    }

    func testItemsDifferingOnlyByScoreAreNotEqual() {
        let base = SearchFixtures.file(name: "notes.txt", score: 10)
        let other = SearchFixtures.file(name: "notes.txt", score: 11)
        XCTAssertNotEqual(base, other)
        XCTAssertEqual(base.id, other.id, "the id deliberately ignores score")
        XCTAssertEqual(Set([base, other]).count, 2)
    }

    // MARK: - Previewability

    func testOnlyFilesWithAURLArePreviewable() throws {
        try checkProperty(
            "isPreviewable == (kind == .file && fileURL != nil)",
            SearchGenerators.kind,
            Gen<Bool>.bool,
            runs: 200
        ) { kind, hasURL in
            let url = hasURL ? URL(fileURLWithPath: "/tmp/x.txt") : nil
            let item = SearchItem(
                title: "x",
                subtitle: "x",
                kind: kind,
                action: .copy("x"),
                score: 0,
                fileURL: url
            )
            return item.isPreviewable == (kind == .file && url != nil)
        }
    }

    // MARK: - Filters

    func testFilterCountsAlwaysMatchTheFilterPredicates() throws {
        // The single most load-bearing invariant in the model: the chip
        // count is computed in one pass over the items, the list is
        // computed by re-filtering, and they must never disagree.
        try checkProperty(
            "SearchFilterCounts[f] == items.filter(f.includes).count",
            SearchGenerators.items(count: 0...60),
            runs: 300
        ) { items in
            let counts = SearchFilterCounts(items: items)
            return SearchResultFilter.allCases.allSatisfy { filter in
                counts[filter] == items.filter(filter.includes).count
            }
        }
    }

    func testTheAllFilterCountsEveryItem() throws {
        try checkProperty(
            ".all includes everything",
            SearchGenerators.items(count: 0...40),
            runs: 200
        ) { items in
            SearchFilterCounts(items: items)[.all] == items.count
                && items.allSatisfy { SearchResultFilter.all.includes($0) }
        }
    }

    func testPrimaryKindFiltersArePairwiseDisjoint() throws {
        // Apps, files, folders, and settings partition by `kind`, so no
        // item may satisfy two of them — otherwise the chips would total
        // more than the list.
        let kindFilters: [SearchResultFilter] = [.applications, .files, .folders, .settings]
        try checkProperty(
            "an item matches at most one kind filter",
            SearchGenerators.item(),
            runs: 400
        ) { item in
            kindFilters.filter { $0.includes(item) }.count <= 1
        }
    }

    func testDynamicFileFiltersArePairwiseDisjoint() throws {
        // PDFs, images, and documents are extension buckets. They must not
        // overlap, or a single file would be counted twice.
        let extensionFilters: [SearchResultFilter] = [.pdfs, .images, .documents]
        try checkProperty(
            "an item matches at most one extension filter",
            SearchGenerators.item(),
            runs: 400
        ) { item in
            extensionFilters.filter { $0.includes(item) }.count <= 1
        }
    }

    func testEveryExtensionFilterImpliesTheFilesFilter() throws {
        try checkProperty(
            "pdfs/images/documents are subsets of files",
            SearchGenerators.item(),
            runs: 400
        ) { item in
            let extensionFilters: [SearchResultFilter] = [.pdfs, .images, .documents]
            return extensionFilters.allSatisfy { filter in
                !filter.includes(item) || SearchResultFilter.files.includes(item)
            }
        }
    }

    func testFileExtensionMatchingIsCaseInsensitive() {
        for name in ["report.PDF", "report.Pdf", "report.pdf"] {
            let item = SearchFixtures.file(name: name)
            XCTAssertTrue(
                SearchResultFilter.pdfs.includes(item),
                "\(name) should be classified as a PDF"
            )
        }
        XCTAssertTrue(SearchResultFilter.images.includes(SearchFixtures.file(name: "shot.HEIC")))
        XCTAssertTrue(SearchResultFilter.documents.includes(SearchFixtures.file(name: "plan.DOCX")))
    }

    func testExtensionFiltersIgnoreNonFileKinds() {
        // A folder called "archive.pdf" is still a folder. The extension
        // buckets gate on `kind == .file` first, and this pins that down.
        let folder = SearchItem(
            id: "folder:/tmp/archive.pdf",
            title: "archive.pdf",
            subtitle: "tmp",
            kind: .folder,
            action: .open(URL(fileURLWithPath: "/tmp/archive.pdf", isDirectory: true)),
            score: 0,
            fileURL: URL(fileURLWithPath: "/tmp/archive.pdf", isDirectory: true)
        )
        XCTAssertFalse(SearchResultFilter.pdfs.includes(folder))
        XCTAssertFalse(SearchResultFilter.files.includes(folder))
        XCTAssertTrue(SearchResultFilter.folders.includes(folder))
    }

    func testAFileWithNoURLIsNeverInAnExtensionBucket() {
        let item = SearchItem(
            id: "file:none",
            title: "mystery",
            subtitle: "",
            kind: .file,
            action: .copy("mystery"),
            score: 0,
            fileURL: nil
        )
        XCTAssertTrue(SearchResultFilter.files.includes(item))
        for filter in [SearchResultFilter.pdfs, .images, .documents] {
            XCTAssertFalse(filter.includes(item))
        }
    }

    func testEmptyCountsAreZeroForEveryFilter() {
        let empty = SearchFilterCounts()
        for filter in SearchResultFilter.allCases {
            XCTAssertEqual(empty[filter], 0, filter.rawValue)
        }
        XCTAssertEqual(empty, SearchFilterCounts(items: []))
    }

    func testFilterCatalogueIsExhaustiveAndNonOverlapping() {
        // `primary` and `dynamic` are what the chip bar renders. If a case
        // were added to the enum and forgotten in both lists it would
        // become unreachable in the UI, so the union is checked against
        // `allCases` rather than assumed.
        let listed = SearchResultFilter.primary + SearchResultFilter.dynamic
        XCTAssertEqual(Set(listed), Set(SearchResultFilter.allCases))
        XCTAssertEqual(listed.count, Set(listed).count, "a filter is listed twice")
        XCTAssertTrue(SearchResultFilter.dynamic.allSatisfy(\.isDynamic))
        XCTAssertTrue(SearchResultFilter.primary.allSatisfy { !$0.isDynamic })
        XCTAssertEqual(
            SearchResultFilter.allCases.map(\.id),
            SearchResultFilter.allCases.map(\.rawValue)
        )
    }

    func testEveryFilterAndKindHasANonEmptyLabel() {
        for filter in SearchResultFilter.allCases {
            XCTAssertFalse(filter.title.isEmpty, filter.rawValue)
        }
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
            XCTAssertFalse(kind.symbolName.isEmpty, kind.rawValue)
        }
        // Labels and symbols are what distinguishes rows at a glance, so
        // two kinds sharing either would be a UI bug.
        let kinds: [SearchItemKind] = [
            .application,
            .assistant,
            .calculator,
            .file,
            .folder,
            .systemSetting,
            .web,
        ]
        XCTAssertEqual(Set(kinds.map(\.label)).count, kinds.count)
        XCTAssertEqual(Set(kinds.map(\.symbolName)).count, kinds.count)
    }

    // MARK: - Ranking

    func testRanksBeforeIsIrreflexive() throws {
        try checkProperty(
            "no item ranks before itself",
            SearchGenerators.item(),
            runs: 400
        ) { item in
            !SearchItemRanking.ranksBefore(item, item)
        }
    }

    func testRanksBeforeIsAsymmetric() throws {
        try checkProperty(
            "a < b implies not b < a",
            SearchGenerators.item(),
            SearchGenerators.item(),
            runs: 600
        ) { lhs, rhs in
            !(SearchItemRanking.ranksBefore(lhs, rhs) && SearchItemRanking.ranksBefore(rhs, lhs))
        }
    }

    func testRanksBeforeIsTransitive() throws {
        // A comparator that is not a strict weak ordering makes
        // `sorted(by:)` undefined — in a debug build it can trap outright.
        try checkProperty(
            "a < b and b < c implies a < c",
            SearchGenerators.item(),
            SearchGenerators.item(),
            SearchGenerators.item(),
            runs: 800
        ) { first, second, third in
            guard SearchItemRanking.ranksBefore(first, second),
                  SearchItemRanking.ranksBefore(second, third)
            else {
                return true
            }
            return SearchItemRanking.ranksBefore(first, third)
        }
    }

    func testHigherScoresAlwaysRankFirst() throws {
        try checkProperty(
            "score dominates title",
            SearchGenerators.score,
            SearchGenerators.score,
            runs: 400
        ) { lhs, rhs in
            guard lhs != rhs else { return true }
            let first = SearchFixtures.file(id: "a", name: "zzz.txt", score: lhs)
            let second = SearchFixtures.file(id: "b", name: "aaa.txt", score: rhs)
            return SearchItemRanking.ranksBefore(first, second) == (lhs > rhs)
        }
    }

    func testRankingIsStableAcrossRepeatedSorts() throws {
        try checkProperty(
            "ranking is idempotent",
            SearchGenerators.items(count: 0...50),
            runs: 300
        ) { items in
            let once = fullyRanked(items)
            let twice = fullyRanked(once)
            return once.map(\.id) == twice.map(\.id)
        }
    }

    func testRankingPreservesEveryItem() throws {
        try checkProperty(
            "ranking is a permutation",
            SearchGenerators.items(count: 0...50),
            runs: 300
        ) { items in
            let ranked = fullyRanked(items)
            return ranked.count == items.count
                && Set(ranked.map(\.id)) == Set(items.map(\.id))
        }
    }

    func testRankedOutputIsSortedByScoreDescending() throws {
        try checkProperty(
            "adjacent ranked items are non-increasing in score",
            SearchGenerators.items(count: 2...50),
            runs: 300
        ) { items in
            let ranked = fullyRanked(items)
            return zip(ranked, ranked.dropFirst()).allSatisfy { $0.score >= $1.score }
        }
    }

    func testPageNeverReportsFewerMatchesThanItReturns() throws {
        try checkProperty(
            "totalMatched >= items.count and items.count <= limit",
            SearchGenerators.items(count: 0...60),
            Gen<Int>.int(in: 0...30),
            runs: 300
        ) { items, limit in
            let page = SearchItemRanking.page(items, limit: limit)
            return page.totalMatched == items.count
                && page.items.count <= max(limit, 0)
                && page.items.count <= items.count
        }
    }

    func testPageReturnsTheHighestRankedPrefix() throws {
        try checkProperty(
            "page(limit:) matches a full-sort prefix",
            SearchGenerators.items(count: 0...40),
            Gen<Int>.int(in: 0...20),
            runs: 300
        ) { items, limit in
            let page = SearchItemRanking.page(items, limit: limit)
            let expected = fullyRanked(items).prefix(limit)
            return page.items.map(\.id) == expected.map(\.id)
        }
    }

    private func fullyRanked(_ items: [SearchItem]) -> [SearchItem] {
        items.sorted(by: SearchItemRanking.ranksBefore)
    }

    func testRankingBandsAreSeparatedByMoreThanAnyAchievableMatchScore() throws {
        struct Tier: Sendable {
            let name: String
            let baseScore: Int
        }

        let tiers: [Tier] = [
            Tier(name: "keywordEngine", baseScore: SearchItemRanking.keywordEngine),
            Tier(name: "calculator", baseScore: SearchItemRanking.calculator),
            Tier(name: "application", baseScore: SearchItemRanking.application),
            Tier(name: "setting", baseScore: SearchItemRanking.setting),
            Tier(name: "content", baseScore: SearchItemRanking.content),
        ]

        let declaredExemptions: Set = [
            "calculator-application",
        ]

        let maxAchievableMatchScore = 20_000

        for (higher, lower) in zip(tiers, tiers.dropFirst()) {
            let pairKey = "\(higher.name)-\(lower.name)"
            if declaredExemptions.contains(pairKey) {
                XCTAssertEqual(
                    higher.baseScore,
                    lower.baseScore,
                    "Exempt pair \(pairKey) must be explicitly tied"
                )
                continue
            }

            XCTAssertGreaterThan(
                higher.baseScore - lower.baseScore,
                maxAchievableMatchScore,
                "Band gap between \(higher.name) (\(higher.baseScore)) and \(lower.name) (\(lower.baseScore)) must exceed max match score \(maxAchievableMatchScore)"
            )

            try checkProperty(
                "no match score can cause tier inversion between \(higher.name) and \(lower.name)",
                Gen<Int>.int(in: 0...maxAchievableMatchScore),
                Gen<Int>.int(in: 0...maxAchievableMatchScore),
                runs: 200
            ) { higherMatchScore, lowerMatchScore in
                let higherItem = SearchItem(
                    id: "higher:\(higher.name)",
                    title: "higher",
                    subtitle: "sub",
                    kind: .application,
                    action: .copy("test"),
                    score: higher.baseScore + higherMatchScore
                )
                let lowerItem = SearchItem(
                    id: "lower:\(lower.name)",
                    title: "lower",
                    subtitle: "sub",
                    kind: .file,
                    action: .copy("test"),
                    score: lower.baseScore + lowerMatchScore
                )
                return SearchItemRanking.ranksBefore(higherItem, lowerItem)
                    && !SearchItemRanking.ranksBefore(lowerItem, higherItem)
            }
        }
    }

    // MARK: - Mapping indexed results

    private func indexedResult(
        name: String,
        relativePath: String,
        isDirectory: Bool,
        score: Int = 500,
        modified: UInt64 = 0,
        size: UInt64 = 0
    ) -> IndexedSearchItem {
        IndexedSearchItem(
            name: name,
            relativePath: relativePath,
            url: URL(fileURLWithPath: "/root/\(relativePath)", isDirectory: isDirectory),
            isDirectory: isDirectory,
            score: score,
            modified: modified,
            size: size
        )
    }

    func testAnApplicationBundleBecomesAnApplicationRowWithoutItsExtension() {
        let item = indexedResult(
            name: "Xcode.app",
            relativePath: "Applications/Xcode.app",
            isDirectory: true
        ).makeSearchItem()

        XCTAssertEqual(item.kind, .application)
        XCTAssertEqual(item.title, "Xcode", "the .app extension is stripped from the display title")
        XCTAssertEqual(item.subtitle, "Applications/Xcode.app")
        XCTAssertNil(item.fileSize, "a bundle reports no size")
    }

    func testApplicationBundleDetectionIsCaseInsensitive() {
        for name in ["Thing.APP", "Thing.App", "Thing.app"] {
            let item = indexedResult(
                name: name,
                relativePath: "Applications/\(name)",
                isDirectory: true
            ).makeSearchItem()
            XCTAssertEqual(item.kind, .application, name)
            XCTAssertEqual(item.title, "Thing", name)
        }
    }

    func testANonDirectoryEndingInAppIsAFileNotAnApplication() {
        // The bundle check requires `isDirectory`, so a stray file called
        // "notes.app" stays a file — otherwise it would open as an app.
        let item = indexedResult(
            name: "notes.app",
            relativePath: "code/notes.app",
            isDirectory: false
        ).makeSearchItem()
        XCTAssertEqual(item.kind, .file)
        XCTAssertEqual(item.title, "notes.app")
    }

    func testDirectoriesBecomeFoldersAndCarryNoSize() {
        let item = indexedResult(
            name: "code",
            relativePath: "Users/example/code",
            isDirectory: true,
            size: 4_096
        ).makeSearchItem()
        XCTAssertEqual(item.kind, .folder)
        XCTAssertNil(item.fileSize)
    }

    func testAZeroModificationStampBecomesNoDateRatherThanTheUnixEpoch() throws {
        // FFF reports `0` when it has no modification time. Mapping that
        // straight through would render every such row as "1 Jan 1970".
        let undated = indexedResult(
            name: "a.txt",
            relativePath: "a.txt",
            isDirectory: false,
            modified: 0
        ).makeSearchItem()
        XCTAssertNil(undated.modifiedAt)

        let dated = indexedResult(
            name: "b.txt",
            relativePath: "b.txt",
            isDirectory: false,
            modified: 1_700_000_000
        ).makeSearchItem()
        XCTAssertEqual(
            try XCTUnwrap(dated.modifiedAt),
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testMappedIdentifiersAreUniquePerPathAndKind() throws {
        try checkProperty(
            "mapped ids are stable and path-derived",
            Gen<String>.lowercaseASCII.filter { !$0.isEmpty },
            Gen<Bool>.bool,
            runs: 300
        ) { name, isDirectory in
            let result = self.indexedResult(
                name: name,
                relativePath: "dir/\(name)",
                isDirectory: isDirectory
            )
            let mapped = result.makeSearchItem()
            let again = result.makeSearchItem()
            return mapped.id == again.id
                && mapped.id == "\(mapped.kind.rawValue):\(result.url.path)"
        }
    }

    func testMappedItemsAlwaysCarryTheirURLAndOpenAction() throws {
        try checkProperty(
            "every mapped item opens its own URL",
            Gen<String>.lowercaseASCII.filter { !$0.isEmpty },
            Gen<Bool>.bool,
            runs: 300
        ) { name, isDirectory in
            let result = self.indexedResult(
                name: name,
                relativePath: name,
                isDirectory: isDirectory
            )
            let mapped = result.makeSearchItem()
            return mapped.fileURL == result.url && mapped.action == .open(result.url)
        }
    }

    // MARK: - Actions

    func testActionEqualityDistinguishesEveryCase() {
        let url = URL(fileURLWithPath: "/tmp/x")
        let cases: [SearchItemAction] = [
            .copy("a"),
            .copy("b"),
            .open(url),
            .open(URL(fileURLWithPath: "/tmp/y")),
            .askAssistant(command: "claude", arguments: ["-p", "hi"]),
            .askAssistant(command: "claude", arguments: ["-p", "bye"]),
            .askAssistant(command: "codex", arguments: ["-p", "hi"]),
        ]
        XCTAssertEqual(Set(cases).count, cases.count, "two distinct actions compare equal")
    }

    func testAssistantAnswerStatesAreDistinctByPayload() {
        let states: [AssistantAnswerState] = [
            .running,
            .answered(""),
            .answered("a"),
            .failed(""),
            .failed("a"),
        ]
        XCTAssertEqual(Set(states.map(String.init(describing:))).count, states.count)
        XCTAssertNotEqual(AssistantAnswerState.answered("a"), .failed("a"))

        let run = AssistantRun(itemID: "x", state: .running)
        XCTAssertEqual(run, AssistantRun(itemID: "x", state: .running))
        XCTAssertNotEqual(run, AssistantRun(itemID: "y", state: .running))
    }

    func testSearchItemPagePreservesWhatItIsGiven() throws {
        try checkProperty(
            "SearchItemPage is a transparent container",
            SearchGenerators.items(count: 0...20),
            Gen<Int>.int(in: 0...500),
            runs: 200
        ) { items, total in
            let page = SearchItemPage(items: items, totalMatched: total)
            return page.items.map(\.id) == items.map(\.id) && page.totalMatched == total
        }
    }

    func testFilterOptionIdentityFollowsItsFilter() {
        for filter in SearchResultFilter.allCases {
            let option = SearchFilterOption(filter: filter, count: 3, isLoading: false)
            XCTAssertEqual(option.id, filter)
            XCTAssertEqual(
                option,
                SearchFilterOption(filter: filter, count: 3, isLoading: false)
            )
            XCTAssertNotEqual(
                option,
                SearchFilterOption(filter: filter, count: 3, isLoading: true)
            )
        }
    }
}
