import FloodlightTestSupport
import Foundation
import Testing
@testable import FloodlightEngine

/// The 80-candidate budget, checked against a test-only full-sort oracle.
///
/// `SearchItemRanking.page` is bounded selection; the oracle here ranks
/// everything and takes the first 80, so the two agreeing means the budget
/// truncates exactly where the published order says it should — with the
/// full eligible count still reported beside the page.
struct ApplicationCatalogBudgetTests {
    private static let budget = 80

    @Test(
        arguments: [
            (eligible: 40, description: "below the budget"),
            (eligible: 80, description: "at the budget"),
            (eligible: 150, description: "above the budget"),
        ]
    )
    func thePageIsTheBestEightyOfEveryEligibleMatch(
        eligible: Int,
        description: String
    ) throws {
        let suiteName = "FloodlightBudgetTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recentStore = RecentStore(defaults: defaults)
        let blocklist = BlocklistStore(defaults: defaults)
        let applications = (0..<eligible).map { Self.application(named: "Studio Tool \($0)") }

        // One blocked and one saturated application, so the oracle has to
        // apply the same exclusion and boost rules as the catalog.
        blocklist.block(name: "Studio Tool 0")
        Self.saturateLaunches(of: Self.identifier(of: applications[1]), in: recentStore)

        let catalog = ApplicationCatalog(
            recentStore: recentStore,
            blocklistStore: blocklist,
            discoveryProvider: { applications }
        )

        let oracle = ApplicationSearchOracle.ranked(
            query: "studio",
            applications: applications,
            recentStore: recentStore,
            blocklist: blocklist
        )
        let page = catalog.immediatePage(for: "studio", limit: Self.budget)

        #expect(
            page.items == Array(oracle.prefix(Self.budget)),
            "\(description): the page is not the oracle's best \(Self.budget)"
        )
        #expect(
            page.totalMatched == oracle.count,
            "\(description): the count must report eligible matches before truncation"
        )
        #expect(!page.items.contains { $0.title == "Studio Tool 0" })
    }

    /// Mutations of a real application name, including letters the name does
    /// not contain. Within the edit budget they must all reach the candidate
    /// — this is the class of query the removed character mask silently
    /// dropped (#69) — while a mutation past the budget stays rejected.
    @Test func typoMutationsWithNovelLettersReachTheCandidate() throws {
        let suiteName = "FloodlightMutationTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let nebula = Self.application(named: "Nebula")
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            discoveryProvider: { [nebula, Self.application(named: "Orbital Launcher")] }
        )

        let mutations = [
            ("nebulx", "substitution with an absent letter"),
            ("nebulaq", "insertion of an absent letter"),
            ("nebla", "deletion"),
            ("neubal", "transposition"),
        ]
        for (query, kind) in mutations {
            let page = catalog.immediatePage(for: query, limit: Self.budget)
            #expect(
                page.items.contains { $0.fileURL == nebula.url },
                "\(kind) mutation '\(query)' did not reach Nebula"
            )
        }

        // Two absent letters in a five-letter query exceed the one-edit
        // budget, so the matcher itself — not a prefilter — rejects it.
        #expect(catalog.immediatePage(for: "nxblx").items.isEmpty)
    }

    private static func application(named name: String) -> (name: String, url: URL) {
        (
            name: name,
            url: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
        )
    }

    private static func identifier(of application: (name: String, url: URL)) -> String {
        "application:\(application.url.path)"
    }

    private static func saturateLaunches(
        of id: String,
        in store: RecentStore,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for _ in 0..<25 {
            store.record(id)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if store.boost(for: id) == FuzzyMatcher.maximumLearningBoost { return }
            usleep(2_000)
        }
        Issue.record(
            "launch history never saturated for \(id)",
            sourceLocation: sourceLocation
        )
    }
}

/// The application catalog's matching expressed without bounded selection:
/// structural matcher, blocklist, and boost applied to every discovered
/// application, then the published order over all of them. Tests compare
/// paged catalog output against a prefix of this full sort.
enum ApplicationSearchOracle {
    static func ranked(
        query: String,
        applications: [(name: String, url: URL)],
        recentStore: RecentStore,
        blocklist: BlocklistStore
    ) -> [SearchItem] {
        let normalizedQuery = FuzzyMatcher.normalized(query)
        return applications.compactMap { application in
            let name = application.name
            let id = "application:\(application.url.path)"
            let normalizedName = FuzzyMatcher.normalized(name)
            guard let rawScore = FuzzyMatcher.score(
                normalizedQuery: normalizedQuery,
                normalizedCandidate: normalizedName
            ) else {
                return nil
            }
            if blocklist.isBlocked(normalizedName: normalizedName, id: id) {
                return nil
            }
            return SearchItem(
                id: id,
                title: name,
                subtitle: application.url.deletingLastPathComponent().path,
                kind: .application,
                action: .open(application.url),
                score: SearchItemRanking.application + rawScore + recentStore.boost(for: id),
                fileURL: application.url
            )
        }.sorted(by: SearchItemRanking.ranksBefore)
    }
}
