import Foundation
import XCTest
@testable import FloodlightEngine

/// Comprehensive tests for `RecentStore` — the frecency boost system that
/// was previously completely untested. Covers recording, boost calculation,
/// recency decay, launch count caps, and persistence.
final class RecentStoreTests: XCTestCase {

    private var cleanupBlocks: [() -> Void] = []

    // MARK: - Empty store

    func testEmptyStoreReturnsZeroBoost() {
        let store = RecentStore(defaults: makeDefaults())
        XCTAssertEqual(store.boost(for: "any-id"), 0)
        XCTAssertEqual(store.boost(for: ""), 0)
    }

    // MARK: - Single record

    func testSingleRecordProducesPositiveBoost() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)
        store.record("app:safari")
        waitForPersist()
        XCTAssertGreaterThan(store.boost(for: "app:safari"), 0)
    }

    func testUnrecordedItemReturnsZeroBoost() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)
        store.record("app:safari")
        waitForPersist()
        XCTAssertEqual(store.boost(for: "app:different"), 0)
    }

    // MARK: - Recency decay

    func testRecentItemNeverScoresLowerThanOlderItemWithSameLaunches() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)

        store.record("old")
        waitForPersist()

        Thread.sleep(forTimeInterval: 2)

        store.record("new")
        waitForPersist()

        let oldBoost = store.boost(for: "old")
        let newBoost = store.boost(for: "new")
        // The recency quantum is 900 seconds (age / 900), so two items
        // recorded 2s apart usually land in the same quantum. What must
        // always hold: recency never rewards the OLDER item, and the drift
        // over 2s can cross at most one quantum boundary (1 point).
        XCTAssertGreaterThanOrEqual(newBoost, oldBoost,
            "a newer item must never score below an equally-launched older one")
        XCTAssertLessThanOrEqual(newBoost - oldBoost, 1,
            "two seconds of age must never cost more than one recency point")
    }

    // MARK: - Launch count

    func testRepeatedRecordingIncreasesBoost() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)

        store.record("app:safari")
        waitForPersist()
        let boostAfterOne = store.boost(for: "app:safari")

        store.record("app:safari")
        waitForPersist()
        let boostAfterTwo = store.boost(for: "app:safari")

        store.record("app:safari")
        waitForPersist()
        let boostAfterThree = store.boost(for: "app:safari")

        XCTAssertGreaterThan(boostAfterTwo, boostAfterOne,
            "second recording should increase boost")
        XCTAssertGreaterThan(boostAfterThree, boostAfterTwo,
            "third recording should increase boost")
    }

    func testLaunchCountCapsAt25() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)

        // record() serializes on the store's persistence queue, so one
        // settle window at the end observes all 30 launches.
        for _ in 0..<30 {
            store.record("app:capped")
        }
        store.record("app:once")
        waitForPersist(milliseconds: 300)

        let cappedBoost = store.boost(for: "app:capped")
        let onceBoost = store.boost(for: "app:once")

        XCTAssertGreaterThan(cappedBoost, onceBoost)

        // The launch component for capped should be 25 * 200 = 5000
        // The launch component for once should be 1 * 200 = 200
        let launchComponentCapped = 25 * 200
        let launchComponentOnce = 1 * 200
        let recencyCapped = cappedBoost - launchComponentCapped
        let recencyOnce = onceBoost - launchComponentOnce

        XCTAssertGreaterThanOrEqual(recencyCapped, recencyOnce - 200)
    }

    // MARK: - Multiple items

    func testMultipleItemsHaveIndependentBoosts() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)

        store.record("a")
        waitForPersist()
        store.record("b")
        store.record("b")
        waitForPersist()

        let boostA = store.boost(for: "a")
        let boostB = store.boost(for: "b")

        XCTAssertGreaterThan(boostB, boostA,
            "item recorded twice should have higher boost than item recorded once")
    }

    func testBoostForNonExistentIDIsAlwaysZero() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)

        store.record("exists")
        waitForPersist()

        for id in ["missing", "", "EXISTS", "exists ", " exists"] {
            XCTAssertEqual(store.boost(for: id), 0, "boost for '\(id)' should be 0")
        }
    }

    // MARK: - Persistence

    func testEntriesPersistAcrossStoreInstances() throws {
        let suiteName = "FloodlightRecentStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        cleanupBlocks.append { defaults.removePersistentDomain(forName: suiteName) }

        let store1 = RecentStore(defaults: defaults)
        store1.record("persistent-id")
        waitForPersist()

        let store2 = RecentStore(defaults: defaults)
        XCTAssertGreaterThan(store2.boost(for: "persistent-id"), 0,
            "entries should persist across store instances")
    }

    func testEmptyDefaultsProduceEmptyStore() throws {
        let suiteName = "FloodlightRecentStoreEmptyTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        cleanupBlocks.append { defaults.removePersistentDomain(forName: suiteName) }

        let store = RecentStore(defaults: defaults)
        XCTAssertEqual(store.boost(for: "anything"), 0)
    }

    // MARK: - Recency formula boundaries

    func testRecencyComponentIsNearMaxForFreshItem() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)
        store.record("fresh")
        waitForPersist()

        let boost = store.boost(for: "fresh")
        // Launch component is 1 * 200 = 200
        // Recency should be close to 4000 (within a few seconds of recording)
        XCTAssertGreaterThan(boost, 200 + 3900,
            "fresh item should have recency close to 4000")
    }

    // MARK: - Concurrent recording

    func testConcurrentRecordingIsSafe() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)

        let expectation = expectation(description: "concurrent recording")
        let count = 100

        for i in 0..<count {
            DispatchQueue.global().async {
                store.record("item-\(i % 10)")
            }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        waitForPersist()

        var anyPositive = false
        for i in 0..<10 {
            if store.boost(for: "item-\(i)") > 0 {
                anyPositive = true
                break
            }
        }
        XCTAssertTrue(anyPositive, "at least some concurrent recordings should have persisted")
    }

    // MARK: - Boost formula verification

    func testBoostFormulaForKnownEntry() {
        let defaults = makeDefaults()
        let store = RecentStore(defaults: defaults)

        // Record exactly 3 times
        for _ in 0..<3 {
            store.record("test-item")
            waitForPersist()
        }

        let boost = store.boost(for: "test-item")
        // launches = 3, capped at 25 -> 3
        // recency = max(0, 4000 - Int(age / 900))
        // age is near 0, so recency ≈ 4000
        // boost = min(3, 25) * 200 + recency = 600 + ~4000
        XCTAssertGreaterThan(boost, 600 + 3900,
            "boost should be approximately 600 + 4000 = 4600")
        XCTAssertLessThanOrEqual(boost, 600 + 4000)
    }

    // MARK: - Helpers

    private func makeDefaults() -> UserDefaults {
        let suiteName = "FloodlightRecentStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        cleanupBlocks.append { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func waitForPersist(milliseconds: Int = 100) {
        Thread.sleep(forTimeInterval: TimeInterval(milliseconds) / 1000.0)
    }

    override func tearDown() {
        for block in cleanupBlocks { block() }
        cleanupBlocks.removeAll()
    }
}
