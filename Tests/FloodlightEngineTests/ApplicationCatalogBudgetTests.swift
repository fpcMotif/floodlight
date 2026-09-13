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

    /// The budget contract without a hand-written case list: seeded corpora
    /// across the interesting sizes (empty, tiny, around and far past the
    /// budget) against seeded queries — exact names, prefixes, acronyms, and
    /// edits that introduce letters the name does not have. Every page must
    /// be the oracle's prefix with the full eligible count beside it, every
    /// returned row must carry matcher evidence, and asking twice must give
    /// the same answer.
    @Test func seededCorporaAndQueriesMatchTheOracle() throws {
        let suiteName = "FloodlightSoakTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recentStore = RecentStore(defaults: defaults)
        let blocklist = BlocklistStore(defaults: defaults)

        // Boost and exclusion exercise the oracle's non-matcher paths. They
        // key on the index-derived URLs, so one setup covers every corpus
        // large enough to contain those indices.
        blocklist.block(id: "application:/Applications/Soak-5.app")
        Self.saturateLaunches(of: "application:/Applications/Soak-3.app", in: recentStore)

        try checkProperty(
            "page == oracle prefix, count == oracle count",
            Self.soakCases,
            runs: 300
        ) { soak in
            let applications = soak.applications
            let catalog = ApplicationCatalog(
                recentStore: recentStore,
                blocklistStore: blocklist,
                discoveryProvider: { applications }
            )
            let oracle = ApplicationSearchOracle.ranked(
                query: soak.query,
                applications: applications,
                recentStore: recentStore,
                blocklist: blocklist
            )
            let page = catalog.immediatePage(for: soak.query, limit: Self.budget)
            guard page.items == Array(oracle.prefix(Self.budget)),
                  page.totalMatched == oracle.count
            else { return false }
            let again = catalog.immediatePage(for: soak.query, limit: Self.budget)
            guard again.items == page.items, again.totalMatched == page.totalMatched
            else { return false }
            let normalizedQuery = FuzzyMatcher.normalized(soak.query)
            return page.items.allSatisfy {
                FuzzyMatcher.score(
                    normalizedQuery: normalizedQuery,
                    normalizedCandidate: FuzzyMatcher.normalized($0.title)
                ) != nil
            }
        }
    }

    /// The systematic shape of #69: for each fixture name, every one-edit
    /// neighbour that introduces a letter the name lacks (plus deletions and
    /// transpositions). The matcher is the only arbiter — whatever it
    /// accepts must be in the page, and whatever it rejects must not be.
    @Test func everyNearMissTheMatcherAcceptsReachesTheCatalog() throws {
        let suiteName = "FloodlightNearMissTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for name in ["Nebula", "Calendar", "Pixel Forge", "Résumé Studio"] {
            let application = Self.application(named: name)
            let catalog = ApplicationCatalog(
                recentStore: RecentStore(defaults: defaults),
                blocklistStore: BlocklistStore(defaults: defaults),
                discoveryProvider: { [application] }
            )
            let id = "application:\(application.url.path)"
            let base = FuzzyMatcher.normalized(name)

            for mutation in Self.oneEditNeighbours(of: base) {
                let accepted = FuzzyMatcher.score(
                    normalizedQuery: mutation,
                    normalizedCandidate: base
                ) != nil
                let page = catalog.immediatePage(for: mutation, limit: Self.budget)
                #expect(
                    page.items.contains { $0.id == id } == accepted,
                    "'\(mutation)' vs '\(name)': matcher says \(accepted), catalog disagrees"
                )
                #expect(page.totalMatched == (accepted ? 1 : 0))
            }
        }
    }

    /// A refresh swaps the snapshot under concurrent reads. Every page taken
    /// during the swap must be exactly the pre- or the post-refresh answer —
    /// a torn mix of two snapshots is the failure this hammers on.
    @Test func pagesStayCoherentWhileARefreshSwapsTheSnapshot() async throws {
        let suiteName = "FloodlightCoherenceTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recentStore = RecentStore(defaults: defaults)
        let blocklist = BlocklistStore(defaults: defaults)
        let before = (0..<60).map { Self.application(named: "Alpha Hammer \($0)") }
        let after = before + [Self.application(named: "Alphabet Soup")]
        let discovery = MutableDiscovery(before)
        let catalog = ApplicationCatalog(
            recentStore: recentStore,
            blocklistStore: blocklist,
            deferDiscovery: true,
            discoveryProvider: { discovery.snapshot() }
        )
        try await catalog.start()

        let readsBegun = AtomicCounter()
        let pages = ConcurrentBag<(items: [SearchItem], total: Int)>()
        let hammer = Task {
            hammerConcurrently(concurrency: 16, iterations: 1_500) { _, _ in
                readsBegun.increment()
                let page = catalog.immediatePage(for: "alph", limit: Self.budget)
                pages.append((page.items, page.totalMatched))
            }
        }
        let readDeadline = Date().addingTimeInterval(TestBudget.seconds(5))
        while readsBegun.value == 0, Date() < readDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        for round in 0..<60 {
            discovery.replace(with: round.isMultiple(of: 2) ? after : before)
            _ = try await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        }
        await hammer.value

        let oracleBefore = ApplicationSearchOracle.ranked(
            query: "alph", applications: before, recentStore: recentStore, blocklist: blocklist
        )
        let oracleAfter = ApplicationSearchOracle.ranked(
            query: "alph", applications: after, recentStore: recentStore, blocklist: blocklist
        )
        let coherent = [
            (Array(oracleBefore.prefix(Self.budget)), oracleBefore.count),
            (Array(oracleAfter.prefix(Self.budget)), oracleAfter.count),
        ]
        for page in pages.values {
            #expect(
                coherent.contains { $0.0 == page.items && $0.1 == page.total },
                "a read observed a page that is neither snapshot's answer"
            )
        }
        #expect(pages.values.contains { $0.total == oracleBefore.count })
        #expect(pages.values.contains { $0.total == oracleAfter.count })
    }

    /// Two applications may share a display name; the catalogue keys on the
    /// URL-derived id, so both must surface as distinct, stable results.
    @Test func duplicateDisplayNamesStayDistinctResults() throws {
        let suiteName = "FloodlightDuplicateNameTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let userCopy = (
            name: "Notes",
            url: URL(fileURLWithPath: "/Applications/Notes.app", isDirectory: true)
        )
        let systemCopy = (
            name: "Notes",
            url: URL(fileURLWithPath: "/System/Applications/Notes.app", isDirectory: true)
        )
        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults),
            blocklistStore: BlocklistStore(defaults: defaults),
            discoveryProvider: { [userCopy, systemCopy] }
        )

        let page = catalog.immediatePage(for: "notes", limit: Self.budget)
        #expect(page.items.count == 2)
        #expect(Set(page.items.map(\.id)) == [
            "application:\(userCopy.url.path)",
            "application:\(systemCopy.url.path)",
        ])
        #expect(page.totalMatched == 2)
        let again = catalog.immediatePage(for: "notes", limit: Self.budget)
        #expect(again.items == page.items)
    }

    /// Substitution, insertion, and deletion of a letter the name does not
    /// contain at every position, plus every adjacent transposition.
    private static func oneEditNeighbours(of name: String) -> [String] {
        let characters = Array(name)
        guard let foreign = "qxzjv".first(where: { !name.contains($0) }) else { return [] }
        var neighbours = Set<String>()
        for index in characters.indices {
            var substituted = characters
            substituted[index] = foreign
            neighbours.insert(String(substituted))
            var deleted = characters
            deleted.remove(at: index)
            neighbours.insert(String(deleted))
            let next = characters.index(after: index)
            if next < characters.endIndex {
                var transposed = characters
                transposed.swapAt(index, next)
                neighbours.insert(String(transposed))
            }
        }
        for index in 0...characters.count {
            var inserted = characters
            inserted.insert(foreign, at: index)
            neighbours.insert(String(inserted))
        }
        neighbours.remove(name)
        return neighbours.sorted()
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

    // MARK: - Soak generation

    /// One soak input: a corpus of application names and the query typed
    /// against it. URLs derive from the corpus index so blocklist and boost
    /// fixtures keyed on `/Applications/Soak-N.app` apply to every corpus
    /// large enough to contain them.
    private struct SoakCase: Sendable, CustomStringConvertible {
        var names: [String]
        var query: String

        var applications: [(name: String, url: URL)] {
            names.enumerated().map { index, name in
                (
                    name: name,
                    url: URL(
                        fileURLWithPath: "/Applications/Soak-\(index).app",
                        isDirectory: true
                    )
                )
            }
        }

        var description: String {
            "query \(query.debugDescription) over \(names.count) apps "
                + "(\(names.prefix(4).joined(separator: ", ")), …)"
        }
    }

    private static let soakCases = Gen<SoakCase>(
        generate: { rng in
            let sizes = [0, 1, 40, 80, 81, 150, 500]
            let size = sizes[Int.random(in: 0..<sizes.count, using: &rng)]
            let names = (0..<size).map { _ in soakName(using: &rng) }
            return SoakCase(names: names, query: soakQuery(for: names, using: &rng))
        },
        shrink: { soak in
            var candidates: [SoakCase] = []
            if soak.names.count > 1 {
                candidates.append(SoakCase(
                    names: Array(soak.names.prefix(soak.names.count / 2)),
                    query: soak.query
                ))
            }
            if soak.query.count > 1 {
                candidates.append(SoakCase(
                    names: soak.names,
                    query: String(soak.query.dropLast())
                ))
            }
            return candidates
        }
    )

    private static func soakName(using rng: inout SeededGenerator) -> String {
        let vocabulary = [
            "Studio", "Tool", "Nebula", "Pixel", "Forge", "Comet", "Aurora",
            "Photon", "Notes", "Calendar", "Ledger", "Orbit", "Canvas", "Drift",
        ]
        let wordCount = Int.random(in: 1...2, using: &rng)
        var words = (0..<wordCount).map { _ in
            vocabulary[Int.random(in: 0..<vocabulary.count, using: &rng)]
        }
        if Bool.random(using: &rng) {
            words.append(String(Int.random(in: 0...99, using: &rng)))
        }
        return words.joined(separator: " ")
    }

    /// Exact names, prefixes, one-edit mutations (often with letters the
    /// name lacks), word initials, and plain noise — the shapes a user
    /// actually types, weighted toward the interesting ones.
    private static func soakQuery(
        for names: [String],
        using rng: inout SeededGenerator
    ) -> String {
        guard let target = names.randomElement(using: &rng) else {
            return soakNoise(using: &rng)
        }
        switch Int.random(in: 0..<10, using: &rng) {
        case 0...2:
            return target
        case 3...5:
            return String(target.prefix(Int.random(in: 1...target.count, using: &rng)))
        case 6...7:
            return soakMutation(of: target, using: &rng)
        case 8:
            return target.split(separator: " ").compactMap(\.first)
                .map(String.init).joined()
        default:
            return soakNoise(using: &rng)
        }
    }

    private static func soakMutation(of name: String, using rng: inout SeededGenerator) -> String {
        var characters = Array(name)
        let letters = Array("qxzjvwky")
        let letter = letters[Int.random(in: 0..<letters.count, using: &rng)]
        switch Int.random(in: 0..<3, using: &rng) {
        case 0:
            characters[Int.random(in: 0..<characters.count, using: &rng)] = letter
        case 1:
            characters.insert(letter, at: Int.random(in: 0...characters.count, using: &rng))
        default:
            characters.remove(at: Int.random(in: 0..<characters.count, using: &rng))
        }
        return String(characters)
    }

    private static func soakNoise(using rng: inout SeededGenerator) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        let length = Int.random(in: 1...8, using: &rng)
        return String((0..<length).map { _ in
            alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]
        })
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
        // The catalog trims its query before matching; the oracle must model
        // the same contract or a trailing space becomes a phantom character.
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
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
