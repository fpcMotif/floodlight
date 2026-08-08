import FloodlightTestSupport
import Foundation
import XCTest
@testable import FloodlightEngine

private actor SystemCatalogCallingActor {
    func refresh(_ catalog: any Catalog) async -> Bool {
        await (try? catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)) ?? false
    }

    func ping() {}
}

private final class BlockingSystemCatalogDiscovery: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func snapshot() -> [SystemCatalog.DiscoveredSetting] {
        started.signal()
        release.wait()
        return []
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func resume() {
        release.signal()
    }
}

private final class SystemCatalogTestSignal: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)

    func send() {
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

/// `SystemCatalog` runs on every keystroke over ~40 settings, so it carries
/// two optimizations in front of the fuzzy scorer: a 64-bit character mask
/// that rejects candidates missing one of the query's letters, and a
/// word-prefix rule for queries shorter than four characters.
///
/// A mask is only safe if it never rejects something the scorer would have
/// accepted. Rather than trust that, the central test here re-implements
/// the *semantics* (word-prefix rule, confidence threshold) without the
/// mask and asserts the catalog returns exactly the same rows for
/// thousands of generated queries. Any false negative the bit-twiddling
/// introduces shows up as a divergence.
final class SystemCatalogInvariantTests: XCTestCase {
    private static let fixtures: [SystemCatalog.DiscoveredSetting] = [
        .init(name: "Aurora Controls", keywords: "brightness glow ambient", pane: "test.aurora"),
        .init(name: "Nebula Network", keywords: "wifi ethernet vpn", pane: "test.nebula"),
        .init(name: "Quasar Audio", keywords: "sound volume output", pane: "test.quasar"),
        .init(name: "Pulsar Privacy", keywords: "camera microphone access", pane: "test.pulsar"),
        .init(name: "Meteor Mouse", keywords: "tracking scrolling click", pane: "test.meteor"),
        .init(name: "Zenith Zoom", keywords: "magnify accessibility", pane: "test.zenith"),
    ]

    /// The catalog's rule, expressed without the character mask.
    private func referenceMatches(
        query rawQuery: String,
        in settings: [SystemCatalog.DiscoveredSetting]
    ) -> Set<String> {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let normalizedQuery = FuzzyMatcher.normalized(trimmed)
        let requiresWordPrefix = normalizedQuery.count < 4

        return Set(
            settings.compactMap { setting -> String? in
                let candidate = FuzzyMatcher.normalized("\(setting.name) \(setting.keywords)")
                let words = candidate
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map(String.init)
                if requiresWordPrefix, !words.contains(where: { $0.hasPrefix(normalizedQuery) }) {
                    return nil
                }
                guard
                    let score = FuzzyMatcher.score(
                        normalizedQuery: normalizedQuery,
                        normalizedCandidate: candidate
                    ),
                    score >= FuzzyMatcher.confidentMatchThreshold,
                    URL(string: "x-apple.systempreferences:\(setting.pane)") != nil
                else {
                    return nil
                }
                return "setting:\(setting.pane)"
            }
        )
    }

    private func makeCatalog(
        _ settings: [SystemCatalog.DiscoveredSetting]
    ) async -> SystemCatalog {
        let discovery = MutableDiscovery(settings)
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        return catalog
    }

    // MARK: - The mask must never reject a real match

    func testTheCharacterMaskNeverRejectsAMatchTheScorerWouldAccept() async throws {
        let catalog = await makeCatalog(Self.fixtures)
        let alphabet = Array("abcdeimnopqrstuvwxyz ")

        try checkProperty(
            "masked search == unmasked reference",
            Gen<String>.string(alphabet: alphabet, length: 1...10),
            runs: 3_000
        ) { query in
            self.fixtureMatches(from: catalog, query: query)
                == self.referenceMatches(query: query, in: Self.fixtures)
        }
    }

    /// The rows the catalog returns for the injected fixtures only. The
    /// built-in table is `private`, so rather than duplicate forty entries
    /// that would drift the moment one is edited, the comparison is scoped
    /// to panes this test owns — the mask and the word-prefix rule are the
    /// same code either way.
    private func fixtureMatches(from catalog: SystemCatalog, query: String) -> Set<String> {
        Set(
            catalog.immediatePage(for: query, limit: 1_000).items
                .map(\.id)
                .filter { $0.hasPrefix("setting:test.") }
        )
    }

    func testTheMaskAgreesWithTheReferenceOnRealSettingsVocabulary() async {
        let catalog = await makeCatalog(Self.fixtures)
        let queries = [
            "aurora", "nebula", "quasar", "pulsar", "meteor", "zenith",
            "wifi", "vpn", "sound", "camera", "click", "magnify",
            "au", "aur", "neb", "q", "zz", "aa", "xyz", "  aurora  ",
            "AURORA", "Aurora Controls", "aurora controls brightness",
            "nebula network wifi ethernet vpn", "ac", "acc",
        ]

        for query in queries {
            XCTAssertEqual(
                fixtureMatches(from: catalog, query: query),
                referenceMatches(query: query, in: Self.fixtures),
                "query: \(String(reflecting: query))"
            )
        }
    }

    // MARK: - Shape of every result

    func testEveryResultIsAWellFormedSettingsRow() async throws {
        let catalog = await makeCatalog(Self.fixtures)

        try checkProperty(
            "settings rows are uniform",
            Gen<String>.element(of: AdversarialCorpus.searchQueries),
            runs: 200
        ) { query in
            catalog.immediatePage(for: query, limit: 50).items.allSatisfy { item in
                item.kind == .systemSetting
                    && item.subtitle == "System Settings"
                    && item.id.hasPrefix("setting:")
                    && item.fileURL == nil
                    && item.score >= SearchItemRanking.setting + FuzzyMatcher
                    .confidentMatchThreshold
                    && !item.title.isEmpty
            }
        }
    }

    func testResultsAreRankedAndPagedConsistently() async throws {
        let catalog = await makeCatalog(Self.fixtures)

        try checkProperty(
            "the page is the ranked prefix and the count is the total",
            Gen<String>.element(of: ["a", "ne", "wifi", "sound", "settings", "e", "s"]),
            Gen<Int>.int(in: 0...30),
            runs: 200
        ) { query, limit in
            let page = catalog.immediatePage(for: query, limit: limit)
            let full = catalog.immediatePage(for: query, limit: 1_000)
            return page.items.count <= max(limit, 0)
                && page.totalMatched == full.items.count
                && page.items.map(\.id) == Array(full.items.prefix(max(limit, 0))).map(\.id)
                && zip(page.items, page.items.dropFirst()).allSatisfy { $0.score >= $1.score }
        }
    }

    func testResultIdentifiersAreAlwaysUnique() async throws {
        let catalog = await makeCatalog(Self.fixtures)

        try checkProperty(
            "no query returns the same pane twice",
            Gen<String>.string(alphabet: Array("abcdenoprstuvwz "), length: 1...8),
            runs: 800
        ) { query in
            let ids = catalog.immediatePage(for: query, limit: 200).items.map(\.id)
            return ids.count == Set(ids).count
        }
    }

    // MARK: - Empty and hostile queries

    func testBlankQueriesReturnNothing() async {
        let catalog = await makeCatalog(Self.fixtures)
        for query in ["", " ", "\t", "\n", "   \n\t  ", "\u{00A0}"] {
            let page = catalog.immediatePage(for: query, limit: 24)
            XCTAssertTrue(page.items.isEmpty, String(reflecting: query))
            XCTAssertEqual(page.totalMatched, 0, String(reflecting: query))
        }
    }

    func testHostileQueriesNeverTrapAndNeverReturnJunk() async {
        let catalog = await makeCatalog(Self.fixtures)
        for query in AdversarialCorpus.strings {
            let page = catalog.immediatePage(for: query, limit: 24)
            XCTAssertLessThanOrEqual(page.items.count, 24, String(reflecting: query))
            XCTAssertGreaterThanOrEqual(page.totalMatched, page.items.count)
            XCTAssertTrue(page.items.allSatisfy { $0.kind == .systemSetting })
        }
    }

    func testAVeryLongQueryIsRejectedRatherThanMatchingEverything() async {
        let catalog = await makeCatalog(Self.fixtures)
        let page = catalog.immediatePage(for: String(repeating: "a", count: 50_000), limit: 24)
        XCTAssertTrue(page.items.isEmpty)
    }

    // MARK: - The short-query word-prefix rule

    func testShortQueriesMustPrefixAWordRatherThanScatterAcrossOne() async {
        let catalog = await makeCatalog(Self.fixtures)

        // "neb" prefixes "nebula", so it matches.
        XCTAssertTrue(
            catalog.immediatePage(for: "neb", limit: 50).items
                .contains { $0.id == "setting:test.nebula" }
        )
        // "nbl" is a subsequence of "nebula" but prefixes no word, so a
        // three-character query must not surface it. This rule is what
        // keeps the settings list quiet while a user is still typing.
        XCTAssertFalse(
            catalog.immediatePage(for: "nbl", limit: 50).items
                .contains { $0.id == "setting:test.nebula" }
        )
        // At four characters the rule lifts.
        XCTAssertEqual(
            catalog.immediatePage(for: "nbla", limit: 50).items
                .contains { $0.id == "setting:test.nebula" },
            referenceMatches(query: "nbla", in: Self.fixtures).contains("setting:test.nebula")
        )
    }

    func testTheWordPrefixRuleAppliesAtExactlyThreeCharacters() async throws {
        let catalog = await makeCatalog(Self.fixtures)

        try checkProperty(
            "queries under four characters require a word prefix",
            Gen<String>.string(alphabet: Array("abcdenoprstuvwz"), length: 1...3),
            runs: 800
        ) { query in
            let normalized = FuzzyMatcher.normalized(query)
            let returned = self.fixtureMatches(from: catalog, query: query)
            return returned.allSatisfy { id in
                guard let setting = Self.fixtures.first(where: { id == "setting:\($0.pane)" })
                else {
                    return false
                }
                let candidate = FuzzyMatcher.normalized("\(setting.name) \(setting.keywords)")
                return candidate
                    .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .contains { $0.hasPrefix(normalized) }
            }
        }
    }

    func testMatchingIsCaseAndDiacriticInsensitive() async {
        let catalog = await makeCatalog([
            .init(name: "Éclair Settings", keywords: "pâtisserie", pane: "test.eclair"),
        ])

        for query in ["eclair", "ECLAIR", "Éclair", "éclair", "ÉCLAIR"] {
            XCTAssertTrue(
                catalog.immediatePage(for: query, limit: 50).items
                    .contains { $0.id == "setting:test.eclair" },
                query
            )
        }
    }

    func testNonASCIICandidatesFallBackToTheStringScorerAndStillMatch() async {
        // The ASCII fast path is skipped for any candidate with a byte
        // above 0x7F. That fallback has to produce the same behaviour, or
        // a localized settings pane would silently stop being findable.
        let catalog = await makeCatalog([
            .init(name: "日本語 Settings", keywords: "language 言語", pane: "test.japanese"),
        ])

        XCTAssertTrue(
            catalog.immediatePage(for: "日本語", limit: 50).items
                .contains { $0.id == "setting:test.japanese" }
        )
        XCTAssertTrue(
            catalog.immediatePage(for: "language", limit: 50).items
                .contains { $0.id == "setting:test.japanese" }
        )
    }

    // MARK: - Discovery, refresh, and de-duplication

    func testARowExistsExactlyWhenItsPaneFormsAURL() async {
        // The pane identifier goes straight into
        // `x-apple.systempreferences:<pane>`, and a row is only emitted if
        // that parses. Asserted differentially against `URL(string:)`
        // itself rather than against a guess about which strings are legal
        // — Foundation's parser is far more lenient than it looks, and
        // spaces or emoji in a pane do *not* disqualify it.
        let panes = [
            "test.plain",
            "has spaces",
            "new\nline",
            "tab\there",
            "delete\u{7F}",
            "ünïcodé",
            "emoji🧑‍🚀",
            "",
        ]
        let catalog = await makeCatalog(
            panes.enumerated().map { index, pane in
                .init(name: "Probe \(index)", keywords: "candidate", pane: pane)
            }
        )

        for (index, pane) in panes.enumerated() {
            let parses = URL(string: "x-apple.systempreferences:\(pane)") != nil
            let found = catalog.immediatePage(for: "Probe \(index)", limit: 50).items
                .contains { $0.id == "setting:\(pane)" }
            XCTAssertEqual(
                found,
                parses,
                "pane \(String(reflecting: pane)) parses=\(parses) but found=\(found)"
            )
        }
    }

    func testAnOpenableSettingCarriesTheSystemPreferencesScheme() async throws {
        let catalog = await makeCatalog([
            .init(name: "Working Pane", keywords: "openable", pane: "test.working"),
        ])
        let item = try XCTUnwrap(
            catalog.immediatePage(for: "Working Pane", limit: 50).items
                .first { $0.id == "setting:test.working" }
        )
        guard case let .open(url) = item.action else {
            return XCTFail("a settings row must open a URL")
        }
        XCTAssertEqual(url.scheme, "x-apple.systempreferences")
        XCTAssertEqual(url.absoluteString, "x-apple.systempreferences:test.working")
    }

    func testDuplicatePanesCollapseWithTheBuiltInWinning() async {
        // Discovery walks several directories and can find the same pane
        // twice; built-ins are listed first, so they win the de-duplication.
        let catalog = await makeCatalog([
            .init(
                name: "Impostor Bluetooth",
                keywords: "fake",
                pane: "com.apple.BluetoothSettings"
            ),
            .init(name: "Duplicate One", keywords: "first", pane: "test.duplicate"),
            .init(name: "Duplicate Two", keywords: "second", pane: "test.duplicate"),
        ])

        let bluetooth = catalog.immediatePage(for: "bluetooth", limit: 50).items
        XCTAssertEqual(
            bluetooth.filter { $0.id == "setting:com.apple.BluetoothSettings" }.count,
            1
        )
        XCTAssertEqual(bluetooth.first?.title, "Bluetooth", "the built-in name wins")

        XCTAssertFalse(
            catalog.immediatePage(for: "Impostor", limit: 50).items
                .contains { $0.id == "setting:com.apple.BluetoothSettings" }
        )
        XCTAssertEqual(
            catalog.immediatePage(for: "Duplicate", limit: 50).items
                .filter { $0.id == "setting:test.duplicate" }.count,
            1
        )
    }

    func testStartingTwiceOnlyDiscoversOnce() async throws {
        let discovery = MutableDiscovery(Self.fixtures)
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })

        try await catalog.start()
        let afterFirst = discovery.reads
        try await catalog.start()
        try await catalog.start()

        XCTAssertEqual(discovery.reads, afterFirst, "start() must be idempotent")
        XCTAssertGreaterThan(afterFirst, 0)
    }

    func testRefreshReportsChangeOnlyWhenTheSnapshotActuallyChanges() async {
        let discovery = MutableDiscovery(Self.fixtures)
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })

        let firstRefresh = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(firstRefresh)
        let unchangedRefresh = await catalog.refreshIfNeeded(
            minimumInterval: 0,
            forceDiscovery: true
        )
        XCTAssertFalse(unchangedRefresh, "an unchanged snapshot must not report a change")

        discovery.replace(with: Self.fixtures + [
            .init(name: "Comet Clock", keywords: "time", pane: "test.comet"),
        ])
        let afterAdding = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(afterAdding)
        let afterSettling = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertFalse(afterSettling)
    }

    func testARenameWithTheSamePaneIsDetectedAsAChange() async {
        // Only the pane is the identity, so a pure rename has to be caught
        // by comparing names too — otherwise a renamed pane keeps its old
        // title forever.
        let discovery = MutableDiscovery([
            SystemCatalog.DiscoveredSetting(name: "Before", keywords: "same", pane: "test.rename"),
        ])
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)

        discovery.replace(with: [
            .init(name: "After", keywords: "same", pane: "test.rename"),
        ])
        let didChange = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(didChange)
        XCTAssertTrue(
            catalog.immediatePage(for: "After", limit: 50).items
                .contains { $0.id == "setting:test.rename" }
        )
        XCTAssertFalse(
            catalog.immediatePage(for: "Before", limit: 50).items
                .contains { $0.id == "setting:test.rename" }
        )
    }

    func testAKeywordOnlyChangeIsDetected() async {
        let discovery = MutableDiscovery([
            SystemCatalog.DiscoveredSetting(
                name: "Steady",
                keywords: "alpha",
                pane: "test.keywords"
            ),
        ])
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)

        discovery.replace(with: [
            .init(name: "Steady", keywords: "omega", pane: "test.keywords"),
        ])
        let didChange = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(didChange)
        XCTAssertTrue(
            catalog.immediatePage(for: "omega", limit: 50).items
                .contains { $0.id == "setting:test.keywords" }
        )
    }

    func testARemovalDropsTheRowButKeepsTheBuiltIns() async {
        let discovery = MutableDiscovery(Self.fixtures)
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertFalse(catalog.immediatePage(for: "aurora", limit: 50).items.isEmpty)

        discovery.replace(with: [])
        let didChange = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(didChange)

        XCTAssertTrue(catalog.immediatePage(for: "aurora", limit: 50).items.isEmpty)
        XCTAssertFalse(
            catalog.immediatePage(for: "bluetooth", limit: 50).items.isEmpty,
            "built-in settings survive an empty discovery"
        )
    }

    func testTheRefreshGuardRateLimitsBackToBackRefreshes() async {
        let discovery = MutableDiscovery(Self.fixtures)
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)

        discovery.replace(with: Self.fixtures + [
            .init(name: "Rate Limited", keywords: "throttle", pane: "test.throttled"),
        ])

        // The interval has not elapsed, so this refresh is skipped entirely
        // — no discovery, no change.
        let throttled = await catalog.refreshIfNeeded(minimumInterval: 3_600, forceDiscovery: true)
        XCTAssertFalse(throttled)
        XCTAssertTrue(catalog.immediatePage(for: "Rate Limited", limit: 50).items.isEmpty)

        let allowed = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
        XCTAssertTrue(allowed)
        XCTAssertFalse(catalog.immediatePage(for: "Rate Limited", limit: 50).items.isEmpty)
    }

    func testAnEmptyDiscoveryStillLeavesTheCatalogUsable() async {
        let catalog = await makeCatalog([])
        XCTAssertFalse(catalog.immediatePage(for: "bluetooth", limit: 24).items.isEmpty)
        XCTAssertFalse(catalog.immediatePage(for: "wifi", limit: 24).items.isEmpty)
    }

    // MARK: - Scale and concurrency

    func testRefreshDiscoveryDoesNotOccupyTheCallingActor() async {
        let discovery = BlockingSystemCatalogDiscovery()
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })
        let caller = SystemCatalogCallingActor()
        let refresh = Task { await caller.refresh(catalog) }

        let didStart = await Task.detached {
            discovery.waitUntilStarted(timeout: 1)
        }.value
        guard didStart else {
            discovery.resume()
            _ = await refresh.value
            return XCTFail("discovery did not start")
        }

        let pinged = SystemCatalogTestSignal()
        let ping = Task {
            await caller.ping()
            pinged.send()
        }
        let actorStayedResponsive = await Task.detached {
            pinged.wait(timeout: 0.5)
        }.value

        discovery.resume()
        _ = await refresh.value
        _ = await ping.value

        XCTAssertTrue(
            actorStayedResponsive,
            "filesystem discovery must leave its caller actor free to accept newer work"
        )
    }

    func testAHugeDiscoveredCatalogStaysSearchableAndFast() async {
        // Nothing bounds how many panes a Mac has installed. Ten thousand
        // is far past realistic, and the per-keystroke budget still has to
        // hold.
        let many = (0..<10_000).map { index in
            SystemCatalog.DiscoveredSetting(
                name: "Generated Pane \(index)",
                keywords: "synthetic fixture number \(index)",
                pane: "test.generated.\(index)"
            )
        }
        let catalog = await makeCatalog(many)

        _ = catalog.immediatePage(for: "generated", limit: 24)
        let start = ContinuousClock.now
        let page = catalog.immediatePage(for: "generated", limit: 24)
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(page.items.count, 24)
        XCTAssertGreaterThan(page.totalMatched, 9_000)
        XCTAssertLessThan(elapsed, .milliseconds(500), "per-keystroke search budget")
    }

    func testConcurrentSearchesAndRefreshesAgreeAndNeverTrap() async {
        let discovery = MutableDiscovery(Self.fixtures)
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)

        // Search is called from the main actor on every keystroke while a
        // refresh runs on a detached task. The lock around the settings
        // snapshot is the only thing keeping this coherent.
        let counts = ConcurrentBag<Int>()
        hammerConcurrently(concurrency: 12, iterations: 200) { _, _ in
            counts.append(catalog.immediatePage(for: "aurora", limit: 24).items.count)
        }

        XCTAssertEqual(Set(counts.values).count, 1, "concurrent searches disagreed")
    }

    func testSearchingWhileTheCatalogIsBeingReplacedNeverReturnsAMixedSnapshot() async {
        let discovery = MutableDiscovery(Self.fixtures)
        let catalog = SystemCatalog(discoveryProvider: { discovery.snapshot() })
        _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)

        let observed = ConcurrentBag<Bool>()
        let refresher = Task.detached {
            for round in 0..<40 {
                discovery.replace(with: round.isMultiple(of: 2) ? Self.fixtures : [])
                _ = await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
            }
        }

        hammerConcurrently(concurrency: 8, iterations: 150) { _, _ in
            let items = catalog.immediatePage(for: "aurora", limit: 24).items
            // Either the fixture is present or it isn't — never a torn row.
            observed.append(items.allSatisfy { $0.id == "setting:test.aurora" })
        }
        await refresher.value

        XCTAssertTrue(observed.values.allSatisfy { $0 })
    }
}
