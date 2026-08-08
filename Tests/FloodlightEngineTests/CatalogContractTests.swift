import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest

/// The `Catalog` seam itself: the protocol's default implementations, the
/// refresh guard that keeps keystrokes from stacking up filesystem walks,
/// and the directory fingerprint both catalogs use to decide whether a walk
/// is worth doing.
///
/// None of these had direct coverage — they were only ever exercised
/// incidentally through `ApplicationCatalog` and `SystemCatalog`, which
/// means a regression in the shared machinery would surface as a confusing
/// failure two layers away.
final class CatalogContractTests: XCTestCase {
    /// A catalog that implements only what the protocol *requires*, so the
    /// defaults supplied by the protocol extension are what get tested.
    private final class MinimalCatalog: Catalog, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var lastLimit: Int?
        private(set) var lastMinimumInterval: TimeInterval?
        private(set) var lastForceDiscovery: Bool?

        func start() async throws {}

        func refreshIfNeeded(
            minimumInterval: TimeInterval,
            forceDiscovery: Bool
        ) async throws -> Bool {
            lock.lock()
            lastMinimumInterval = minimumInterval
            lastForceDiscovery = forceDiscovery
            lock.unlock()
            return true
        }

        func immediatePage(for query: String, limit: Int) -> SearchItemPage {
            lock.lock()
            lastLimit = limit
            lock.unlock()
            return SearchItemPage(items: [], totalMatched: 0)
        }
    }

    // MARK: - Protocol defaults

    func testACatalogWithNoIndexReturnsNoIndexedItems() async throws {
        let catalog = MinimalCatalog()
        let items = try await catalog.indexedItems(for: "anything", limit: 50)
        XCTAssertTrue(items.isEmpty)
    }

    func testTrackingIsANoOpForACatalogThatCannotLearn() throws {
        // The default `track` exists so the coordinator can call it
        // unconditionally. It must not trap for a catalog that ignores it.
        let catalog = MinimalCatalog()
        catalog.track(query: "q", selectedURL: URL(fileURLWithPath: "/tmp/x"))
        try catalog.track(query: "", selectedURL: XCTUnwrap(URL(string: "https://example.com")))
    }

    func testConvenienceRefreshUsesATwoSecondFloorAndNoForcedDiscovery() async throws {
        let catalog = MinimalCatalog()
        let changed = try await catalog.refreshIfNeeded()

        XCTAssertTrue(changed)
        XCTAssertEqual(catalog.lastMinimumInterval, 2)
        XCTAssertEqual(catalog.lastForceDiscovery, false)
    }

    func testConveniencePageAndIndexedSearchDefaultToTwelveResults() async throws {
        let catalog = MinimalCatalog()
        _ = catalog.immediatePage(for: "q")
        XCTAssertEqual(catalog.lastLimit, 12)

        _ = try await catalog.indexedItems(for: "q")
        XCTAssertEqual(catalog.lastLimit, 12, "the default indexed search must not re-page")
    }

    func testAZeroLimitPageIsEmptyRatherThanACrash() {
        let catalog = ScriptedCatalog(
            immediate: (0..<5).map { SearchFixtures.file(name: "f\($0).txt") }
        )
        let page = catalog.immediatePage(for: "f", limit: 0)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.totalMatched, 5, "the count reports matches, not the page")
    }

    func testAnOversizedLimitReturnsEverythingWithoutPadding() {
        let catalog = ScriptedCatalog(
            immediate: (0..<5).map { SearchFixtures.file(name: "f\($0).txt") }
        )
        let page = catalog.immediatePage(for: "f", limit: 10_000)
        XCTAssertEqual(page.items.count, 5)
        XCTAssertEqual(page.totalMatched, 5)
    }

    // MARK: - CatalogRefreshGuard

    func testTheGuardAdmitsExactlyOneOfManyRacingCallers() {
        let guardUnderTest = CatalogRefreshGuard()
        let admitted = AtomicCounter()

        // Every keystroke calls this. Only one may start a walk.
        hammerConcurrently(concurrency: 16, iterations: 200) { _, _ in
            if guardUnderTest.reserve(minimumInterval: 3_600) {
                admitted.increment()
            }
        }

        XCTAssertEqual(admitted.value, 1)
    }

    func testTheGuardStaysClosedUntilReleased() {
        let guardUnderTest = CatalogRefreshGuard()

        XCTAssertTrue(guardUnderTest.reserve(minimumInterval: 0))
        XCTAssertFalse(
            guardUnderTest.reserve(minimumInterval: 0),
            "a refresh already in flight must absorb the next request"
        )

        guardUnderTest.release()
        XCTAssertTrue(guardUnderTest.reserve(minimumInterval: 0))
    }

    func testTheGuardEnforcesItsMinimumIntervalAfterRelease() {
        let guardUnderTest = CatalogRefreshGuard()

        XCTAssertTrue(guardUnderTest.reserve(minimumInterval: 0))
        guardUnderTest.release()

        // Released, but the interval has not elapsed.
        XCTAssertFalse(guardUnderTest.reserve(minimumInterval: 3_600))
        // A zero interval always admits a released guard.
        XCTAssertTrue(guardUnderTest.reserve(minimumInterval: 0))
    }

    func testReleasingAGuardThatWasNeverReservedIsHarmless() {
        let guardUnderTest = CatalogRefreshGuard()
        guardUnderTest.release()
        guardUnderTest.release()
        XCTAssertTrue(guardUnderTest.reserve(minimumInterval: 0))
    }

    func testRepeatedReserveReleaseCyclesUnderContentionNeverDoubleAdmit() {
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

        XCTAssertEqual(overlaps.value, 0, "two callers held the refresh reservation at once")
    }

    func testAnUnreleasedGuardBlocksForever() {
        // The failure mode worth knowing about: a `refresh` that throws
        // before its `defer { release() }` would wedge the catalog. Both
        // shipping catalogs release in a `defer`; this pins what happens if
        // one ever stops.
        let guardUnderTest = CatalogRefreshGuard()
        XCTAssertTrue(guardUnderTest.reserve(minimumInterval: 0))
        for _ in 0..<50 {
            XCTAssertFalse(guardUnderTest.reserve(minimumInterval: 0))
        }
    }

    // MARK: - CatalogDirectoryFingerprint

    func testAMissingDirectoryFingerprintsAsTheDistantPast() {
        let missing = "/definitely/not/a/real/path-\(UUID().uuidString)"
        XCTAssertEqual(
            CatalogDirectoryFingerprint.modificationDate(
                ofDirectoryAtPath: missing,
                fileManager: .default
            ),
            .distantPast
        )
    }

    func testAnExistingDirectoryFingerprintsAsARealDate() throws {
        let tree = try TemporaryTree(label: "FingerprintTests")
        let date = CatalogDirectoryFingerprint.modificationDate(
            ofDirectoryAtPath: tree.root.path,
            fileManager: .default
        )
        XCTAssertGreaterThan(date, .distantPast)
        XCTAssertLessThanOrEqual(date, Date().addingTimeInterval(5))
    }

    func testDuplicatePathsCollapseInsteadOfTrapping() {
        // `make(forPaths:)` builds a dictionary with
        // `uniqueKeysWithValues`, which traps on a duplicate key. The
        // `Set(paths)` in front of it is the only thing preventing that, so
        // handing it duplicates is the test that matters.
        let path = FileManager.default.temporaryDirectory.path
        let fingerprint = CatalogDirectoryFingerprint.make(
            forPaths: [path, path, path, path],
            fileManager: .default
        )
        XCTAssertEqual(fingerprint.count, 1)
        XCTAssertNotNil(fingerprint[path])
    }

    func testURLsThatStandardizeToTheSamePathCollapse() {
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
        XCTAssertEqual(fingerprint.count, 1, "\(fingerprint.keys)")
    }

    func testAnEmptyInputProducesAnEmptyFingerprint() {
        XCTAssertTrue(
            CatalogDirectoryFingerprint.make(forPaths: [String](), fileManager: .default).isEmpty
        )
        XCTAssertTrue(
            CatalogDirectoryFingerprint.make(for: [URL](), fileManager: .default).isEmpty
        )
    }

    func testAddingAFileChangesTheEnclosingDirectorysFingerprint() throws {
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

        XCTAssertNotEqual(
            after,
            before,
            "adding a file did not move the directory's modification date"
        )
    }

    func testFingerprintingIsStableWhenNothingChanges() throws {
        let tree = try TemporaryTree(label: "FingerprintStableTests")
        try tree.makeFile("a.txt", contents: "a")

        let first = CatalogDirectoryFingerprint.make(
            forPaths: [tree.root.path],
            fileManager: .default
        )
        for _ in 0..<20 {
            XCTAssertEqual(
                CatalogDirectoryFingerprint.make(
                    forPaths: [tree.root.path],
                    fileManager: .default
                ),
                first
            )
        }
    }

    func testFingerprintingManyPathsConcurrentlyIsSafe() throws {
        let tree = try TemporaryTree(label: "FingerprintConcurrentTests")
        var paths: [String] = []
        for index in 0..<20 {
            try paths.append(tree.makeDirectory("dir-\(index)").path)
        }
        let counts = ConcurrentBag<Int>()

        hammerConcurrently(concurrency: 12, iterations: 40) { _, _ in
            let fingerprint = CatalogDirectoryFingerprint.make(
                forPaths: paths,
                fileManager: FileManager()
            )
            counts.append(fingerprint.count)
        }

        XCTAssertTrue(counts.values.allSatisfy { $0 == 20 })
    }

    func testHostilePathsAreFingerprintedWithoutTrapping() throws {
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
        XCTAssertEqual(fingerprint.count, paths.count)
    }

    // MARK: - The scripted double honours the contract

    func testTheScriptedCatalogRecordsWhatTheCoordinatorAsksItFor() async throws {
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

        XCTAssertEqual(catalog.starts, 1)
        XCTAssertEqual(catalog.queries, ["xc"])
        XCTAssertEqual(catalog.indexedSearches, 1)
        XCTAssertEqual(catalog.tracked.count, 1)
        XCTAssertEqual(catalog.immediatePage(for: "xc", limit: 12).totalMatched, 42)
    }

    func testTheScriptedCatalogCanFailEveryStageIndependently() async {
        let catalog = ScriptedCatalog(
            .init(
                startError: TestError.scripted("start"),
                indexedError: TestError.scripted("indexed"),
                refreshError: TestError.scripted("refresh")
            )
        )

        do {
            try await catalog.start()
            XCTFail("start should have thrown")
        } catch {
            XCTAssertEqual(error as? TestError, .scripted("start"))
        }

        do {
            _ = try await catalog.refreshIfNeeded(minimumInterval: 0, forceDiscovery: true)
            XCTFail("refresh should have thrown")
        } catch {
            XCTAssertEqual(error as? TestError, .scripted("refresh"))
        }

        do {
            _ = try await catalog.indexedItems(for: "q", limit: 1)
            XCTFail("indexed search should have thrown")
        } catch {
            XCTAssertEqual(error as? TestError, .scripted("indexed"))
        }
    }
}
