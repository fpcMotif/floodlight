import FloodlightTestSupport
import Foundation
import Testing
@testable import FloodlightEngine

struct ArchitectureAblationTests {
    /// The ablation fixture that justified the simplification, kept as a
    /// regression: the study's 46 applications and 20 queries, broadened with
    /// four more names and two more queries, one of them the substitution
    /// typo with a novel letter from issue #69 that the old character mask
    /// silently rejected.
    ///
    /// The study removed the marker index's contribution and found no top-12
    /// changes; its six lower-ranked indexed-only additions all fell inside
    /// an immediate page of 80. With the index gone, the regression form of
    /// both findings is an oracle check: the single catalog path must return
    /// exactly the eligible matches the structural matcher sees, leading
    /// results first, truncated only at the 80-candidate budget.
    @Test func singleCatalogPathMatchesTheAblationOracle() throws {
        let suite = "ApplicationCatalogAblation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let names = [
            "Safari", "Firefox", "Google Chrome", "Visual Studio Code", "Terminal",
            "System Settings", "Activity Monitor", "Notes", "Notion", "Orbital Launcher",
            "Calendar", "Calculator", "Preview", "Slack", "Spotify", "Résumé Editor",
        ] + (0..<30).map { "Studio Tool \($0)" }
            + ["Nebula", "Comet", "Aurora", "Photon"]
        let applications = names.map { name in
            (name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
        }
        let recentStore = RecentStore(defaults: defaults)
        let blocklist = BlocklistStore(defaults: defaults)
        let catalog = ApplicationCatalog(
            recentStore: recentStore,
            blocklistStore: blocklist,
            discoveryProvider: { applications }
        )
        let queries = [
            "safari", "saf", "safrai", "firefox", "firfox", "chrome", "vsc",
            "studio", "term", "settings", "act", "not", "orbital", "launcher",
            "calc", "prev", "slack", "spot", "resume", "zzzz",
            "nebula", "nebulx",
        ]
        var matchedQueries = 0
        var covered = 0
        for query in queries {
            let oracle = ApplicationSearchOracle.ranked(
                query: query,
                applications: applications,
                recentStore: recentStore,
                blocklist: blocklist
            )
            let leading = catalog.immediatePage(for: query, limit: 12)
            let budgeted = catalog.immediatePage(for: query, limit: 80)
            #expect(
                leading.items == Array(oracle.prefix(12)),
                "\(query): leading results changed"
            )
            #expect(
                budgeted.items == Array(oracle.prefix(80)),
                "\(query): eligible matches missing from the candidate budget"
            )
            #expect(
                budgeted.totalMatched == oracle.count,
                "\(query): the count must cover every eligible match"
            )
            matchedQueries += oracle.isEmpty ? 0 : 1
            covered += budgeted.items.count
            print(
                "APP_ABLATION query=\(query) eligible=\(oracle.count) budgeted=\(budgeted.items.count)"
            )
        }
        #expect(matchedQueries > 0, "The fixture must still exercise real matches.")
        print(
            "APP_ABLATION_SUMMARY applications=\(applications.count) queries=\(queries.count) matched_queries=\(matchedQueries) budgeted_results=\(covered)"
        )
    }
}
