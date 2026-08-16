import FloodlightEngine
import FloodlightTestSupport
import Foundation
import os
import Testing

/// The `Catalog` seam itself: the protocol's default implementations, the
/// refresh guard that keeps keystrokes from stacking up filesystem walks,
/// and the directory fingerprint both catalogs use to decide whether a walk
/// is worth doing.
///
/// None of these had direct coverage — they were only ever exercised
/// incidentally through `ApplicationCatalog` and `SystemCatalog`, which
/// means a regression in the shared machinery would surface as a confusing
/// failure two layers away.
struct CatalogContractTests {
    /// A catalog that implements only what the protocol *requires*, so the
    /// defaults supplied by the protocol extension are what get tested.
    private final class MinimalCatalog: Catalog, @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock(initialState: ())
        private(set) var lastLimit: Int?
        private(set) var lastMinimumInterval: TimeInterval?
        private(set) var lastForceDiscovery: Bool?

        func start() async throws {}

        func refreshIfNeeded(
            minimumInterval: TimeInterval,
            forceDiscovery: Bool
        ) async throws -> Bool {
            lock.withLock { _ in
                lastMinimumInterval = minimumInterval
                lastForceDiscovery = forceDiscovery
            }
            return true
        }

        func immediatePage(for query: String, limit: Int) -> SearchItemPage {
            lock.withLock { _ in
                lastLimit = limit
            }
            return SearchItemPage(items: [], totalMatched: 0)
        }
    }

    // MARK: - Protocol defaults

    @Test func aCatalogWithNoIndexReturnsNoIndexedItems() async throws {
        let catalog = MinimalCatalog()
        let items = try await catalog.indexedItems(for: "anything", limit: 50)
        #expect(items.isEmpty)
    }

    @Test func trackingIsANoOpForACatalogThatCannotLearn() throws {
        // The default `track` exists so the coordinator can call it
        // unconditionally. It must not trap for a catalog that ignores it.
        let catalog = MinimalCatalog()
        catalog.track(query: "q", selectedURL: URL(fileURLWithPath: "/tmp/x"))
        try catalog.track(query: "", selectedURL: #require(URL(string: "https://example.com")))
    }

    @Test func convenienceRefreshUsesATwoSecondFloorAndNoForcedDiscovery() async throws {
        let catalog = MinimalCatalog()
        let changed = try await catalog.refreshIfNeeded()

        #expect(changed)
        #expect(catalog.lastMinimumInterval == 2)
        #expect(catalog.lastForceDiscovery == false)
    }

    @Test func conveniencePageAndIndexedSearchDefaultToTwelveResults() async throws {
        let catalog = MinimalCatalog()
        _ = catalog.immediatePage(for: "q")
        #expect(catalog.lastLimit == 12)

        _ = try await catalog.indexedItems(for: "q")
        #expect(catalog.lastLimit == 12, "the default indexed search must not re-page")
    }

    @Test func aZeroLimitPageIsEmptyRatherThanACrash() {
        let catalog = ScriptedCatalog(
            immediate: (0..<5).map { SearchFixtures.file(name: "f\($0).txt") }
        )
        let page = catalog.immediatePage(for: "f", limit: 0)
        #expect(page.items.isEmpty)
        #expect(page.totalMatched == 5, "the count reports matches, not the page")
    }

    @Test func anOversizedLimitReturnsEverythingWithoutPadding() {
        let catalog = ScriptedCatalog(
            immediate: (0..<5).map { SearchFixtures.file(name: "f\($0).txt") }
        )
        let page = catalog.immediatePage(for: "f", limit: 10_000)
        #expect(page.items.count == 5)
        #expect(page.totalMatched == 5)
    }

    // MARK: - CatalogRefreshGuard

    @Test func theGuardAdmitsExactlyOneOfManyRacingCallers() {
        let guardUnderTest = CatalogRefreshGuard()
        let admitted = AtomicCounter()

        // Every keystroke calls this. Only one may start a walk.
        hammerConcurrently(concurrency: 16, iterations: 200) { _, _ in
            if guardUnderTest.reserve(minimumInterval: 3_600) {
                admitted.increment()
            }
        }

        #expect(admitted.value == 1)
    }

    @Test func theGuardStaysClosedUntilReleased() {
        let guardUnderTest = CatalogRefreshGuard()

        #expect(guardUnderTest.reserve(minimumInterval: 0))
        #expect(
            !(guardUnderTest.reserve(minimumInterval: 0)),
            "a refresh already in flight must absorb the next request"
        )

        guardUnderTest.release()
        #expect(guardUnderTest.reserve(minimumInterval: 0))
    }

    @Test func theGuardEnforcesItsMinimumIntervalAfterRelease() {
        let guardUnderTest = CatalogRefreshGuard()

        #expect(guardUnderTest.reserve(minimumInterval: 0))
        guardUnderTest.release()

        // Released, but the interval has not elapsed.
        #expect(!(guardUnderTest.reserve(minimumInterval: 3_600)))
        // A zero interval always admits a released guard.
        #expect(guardUnderTest.reserve(minimumInterval: 0))
    }

    @Test func releasingAGuardThatWasNeverReservedIsHarmless() {
        let guardUnderTest = CatalogRefreshGuard()
        guardUnderTest.release()
        guardUnderTest.release()
        #expect(guardUnderTest.reserve(minimumInterval: 0))
    }

    @Test func repeatedReserveReleaseCyclesUnderContentionNeverDoubleAdmit() {
        // The realistic shape: a refresh finishes and another immediately
        // starts, while other callers keep hammering. At no instant may two
        // callers hold the reservation.
        let guardUnderTest = CatalogRefreshGuard()
        let concurrent = AtomicCounter()
        let overlaps = AtomicCounter()

        hammerConcurrently(concurrency: 12, iterations: 300) { _, _ in
            guard guardUnderTest.reserve(minimumInterval: 0) else { return }
            if concurrent.increment() != 1 {
                overlaps.increment()
            }
            concurrent.increment(by: -1)
            guardUnderTest.release()
        }

        #expect(overlaps.value == 0, "two callers held the refresh reservation at once")
    }

    @Test func anUnreleasedGuardBlocksForever() {
        // The failure mode worth knowing about: a `refresh` that throws
        // before its `defer { release() }` would wedge the catalog. Both
        // shipping catalogs release in a `defer`; this pins what happens if
        // one ever stops.
        let guardUnderTest = CatalogRefreshGuard()
        #expect(guardUnderTest.reserve(minimumInterval: 0))
        for _ in 0..<50 {
            #expect(!(guardUnderTest.reserve(minimumInterval: 0)))
        }
    }

    // MARK: - CatalogDirectoryFingerprint

    @Test func aMissingDirectoryFingerprintsAsTheDistantPast() {
        let missing = "/definitely/not/a/real/path-\(UUID().uuidString)"
        #expect(CatalogDirectoryFingerprint.modificationDate(
            ofDirectoryAtPath: missing,
            fileManager: .default
        ) == .distantPast)
    }

    @Test func anExistingDirectoryFingerprintsAsARealDate() throws {
        let tree = try TemporaryTree(label: "FingerprintTests")
        let date = CatalogDirectoryFingerprint.modificationDate(
            ofDirectoryAtPath: tree.root.path,
            fileManager: .default
        )
        #expect(date > .distantPast)
        #expect(date <= Date().addingTimeInterval(5))
    }

    @Test func duplicatePathsCollapseInsteadOfTrapping() {
        // `make(forPaths:)` builds a dictionary with
        // `uniqueKeysWithValues`, which traps on a duplicate key. The
        // `Set(paths)` in front of it is the only thing preventing that, so
        // handing it duplicates is the test that matters.
        let path = FileManager.default.temporaryDirectory.path
        let fingerprint = CatalogDirectoryFingerprint.make(
            forPaths: [path, path, path, path],
            fileManager: .default
        )
        #expect(fingerprint.count == 1)
        #expect(fingerprint[path] != nil)
    }

    @Test func uRLsThatStandardizeToTheSamePathCollapse() {
        // Application roots are assembled from several sources that can
        // name the same directory differently. Two spellings of one
        // directory must not become two keys — and must not trap.
        let base = FileManager.default.temporaryDirectory
        let urls = [
            base,
            base.appendingPathComponent("."),
            URL(fileURLWithPath: base.path, isDirectory: true),
            URL(fileURLWithPath: base.path + "/", isDirectory: true),
        ]
        let fingerprint = CatalogDirectoryFingerprint.make(for: urls, fileManager: .default)
        #expect(fingerprint.count == 1, "\(fingerprint.keys)")
    }

    @Test func anEmptyInputProducesAnEmptyFingerprint() {
        #expect(CatalogDirectoryFingerprint.make(forPaths: [String](), fileManager: .default)
            .isEmpty)
        #expect(CatalogDirectoryFingerprint.make(for: [URL](), fileManager: .default).isEmpty)
    }

    @Test func addingAFileChangesTheEnclosingDirectorysFingerprint() throws {
        // This is the whole point of the type: it answers "is a full
        // re-walk worth it?" without walking. If a change did not move the
        // fingerprint, newly installed applications would never appear.
        let tree = try TemporaryTree(label: "FingerprintChangeTests")
        let before = CatalogDirectoryFingerprint.make(
            forPaths: [tree.root.path],
            fileManager: .default
        )

        var after = before
        let deadline = Date().addingTimeInterval(5)
        var attempt = 0
        while after == before, Date() < deadline {
            attempt += 1
            try tree.makeFile("added-\(attempt).txt", contents: "x")
            after = CatalogDirectoryFingerprint.make(
                forPaths: [tree.root.path],
                fileManager: .default
            )
            if after == before { usleep(50_000) }
        }

        #expect(after != before, "adding a file did not move the directory's modification date")
    }

    @Test func fingerprintingIsStableWhenNothingChanges() throws {
        let tree = try TemporaryTree(label: "FingerprintStableTests")
        try tree.makeFile("a.txt", contents: "a")

        let first = CatalogDirectoryFingerprint.make(
            forPaths: [tree.root.path],
            fileManager: .default
        )
        for _ in 0..<20 {
            #expect(CatalogDirectoryFingerprint.make(
                forPaths: [tree.root.path],
                fileManager: .default
            ) == first)
        }
    }

    @Test func fingerprintingManyPathsConcurrentlyIsSafe() throws {
        let tree = try TemporaryTree(label: "FingerprintConcurrentTests")
        let paths = try (0..<20).map { index in
            try tree.makeDirectory("dir-\(index)").path
        }
        let counts = ConcurrentBag<Int>()

        hammerConcurrently(concurrency: 12, iterations: 40) { _, _ in
            let fingerprint = CatalogDirectoryFingerprint.make(
                forPaths: paths,
                fileManager: FileManager()
            )
            counts.append(fingerprint.count)
        }

        #expect(counts.values.allSatisfy { $0 == 20 })
    }

    @Test func hostilePathsAreFingerprintedWithoutTrapping() throws {
        // Paths come from the filesystem, so they carry whatever names
        // users give their folders.
        let tree = try TemporaryTree(label: "FingerprintHostileTests")
        var paths: [String] = []
        for (index, name) in [
            "spaces in name",
            "emoji 🧑‍🚀",
            "dots...",
            "ünïcodé",
            "trailing ",
            "  leading",
        ].enumerated() {
            try paths.append(tree.makeDirectory("\(index)-\(name)").path)
        }
        paths.append("/nonexistent-\(UUID().uuidString)")

        let fingerprint = CatalogDirectoryFingerprint.make(
            forPaths: paths,
            fileManager: .default
        )
        #expect(fingerprint.count == paths.count)
    }

    // MARK: - The scripted double honours the contract

    @Test func theScriptedCatalogRecordsWhatTheCoordinatorAsksItFor() async throws {
        let catalog = ScriptedCatalog(
            .init(
                immediate: [SearchFixtures.application(name: "Xcode")],
                totalMatched: 42,
                indexed: [SearchFixtures.application(name: "Xcode Beta")]
            )
        )

        try await catalog.start()
        _ = catalog.immediatePage(for: "xc", limit: 12)
        _ = try await catalog.indexedItems(for: "xc", limit: 12)
        catalog.track(query: "xc", selectedURL: URL(fileURLWithPath: "/Applications/Xcode.app"))

        #expect(catalog.starts == 1)
        #expect(catalog.queries == ["xc"])
        #expect(catalog.indexedSearches == 1)
        #expect(catalog.tracked.count == 1)
        #expect(catalog.immediatePage(for: "xc", limit: 12).totalMatched == 42)
    }

    @Test func theScriptedCatalogCanFailEveryStageIndependently() async {
        let catalog = ScriptedCatalog(
            .init(
                startError: TestError.scripted("start"),
                indexedError: TestError.scripted("indexed"),
                refreshError: TestError.scripted("refresh")
            )
        )

        do {
            try await catalog.start()
            Issue.record("start should have thrown")
        } catch {
            #expect(error as? TestError == .scripted("start"))
        }

        do {
            _ = try await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
            Issue.record("refresh should have thrown")
        } catch {
            #expect(error as? TestError == .scripted("refresh"))
        }

        do {
            _ = try await catalog.indexedItems(for: "q", limit: 1)
            Issue.record("indexed search should have thrown")
        } catch {
            #expect(error as? TestError == .scripted("indexed"))
        }
    }
}
