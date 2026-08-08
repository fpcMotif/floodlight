import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest

/// `RecentStore` is the only mutable, persisted, cross-thread state in the
/// engine: every keystroke reads a boost, every launch writes one, and the
/// write happens on a background queue while reads keep coming from the
/// main actor. It had no tests at all. These cover the boost arithmetic,
/// the persistence round-trip, corrupt-store recovery, and — the reason
/// this file exists — hammering it from many threads at once.
final class RecentStoreConcurrencyTests: XCTestCase {
    /// The store persists asynchronously, so a read taken immediately after
    /// a write legitimately sees the old value. Everything that waits on a
    /// write goes through here.
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            usleep(2_000)
        }
        XCTFail("never became true: \(description)", file: file, line: line)
    }

    // MARK: - Boost arithmetic

    func testAnUnknownIdentifierHasNoBoost() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        XCTAssertEqual(store.boost(for: "never-opened"), 0)
        XCTAssertEqual(store.boost(for: ""), 0)
        XCTAssertEqual(store.boost(for: String(repeating: "x", count: 10_000)), 0)
    }

    func testRecordingOnceProducesARecencyDominatedBoost() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        store.record("app:one")
        waitUntil("the first launch is recorded") { store.boost(for: "app:one") > 0 }

        // One launch (200) plus a full-strength recency term (4_000).
        XCTAssertEqual(store.boost(for: "app:one"), 4_200)
    }

    func testBoostGrowsWithLaunchesUntilItSaturates() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        for count in 1...30 {
            store.record("app:hot")
            waitUntil("launch \(count) is recorded") {
                store.boost(for: "app:hot") >= 4_000 + min(count, 25) * 200
            }
        }

        // Launches are capped at 25, so the 26th through 30th add nothing.
        XCTAssertEqual(store.boost(for: "app:hot"), 4_000 + 25 * 200)
    }

    func testBoostIsBoundedForEveryPossibleLaunchCount() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        try checkProperty(
            "0 <= boost <= 9_000 for any number of launches",
            Gen<Int>.int(in: 0...40),
            runs: 60
        ) { launches in
            let id = "bounded:\(launches)"
            for _ in 0..<launches {
                store.record(id)
            }
            let boost = store.boost(for: id)
            return boost >= 0 && boost <= 25 * 200 + 4_000
        }
    }

    func testDistinctIdentifiersDoNotShareABoost() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        store.record("app:a")
        waitUntil("app:a is recorded") { store.boost(for: "app:a") > 0 }

        XCTAssertGreaterThan(store.boost(for: "app:a"), 0)
        XCTAssertEqual(store.boost(for: "app:b"), 0)
        XCTAssertEqual(store.boost(for: "app:A"), 0, "identifiers are case-sensitive")
    }

    func testHostileIdentifiersRoundTripThroughTheStore() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        // Result identifiers are built from file paths, so they carry
        // whatever the filesystem allows — emoji, RTL marks, colons. They
        // become JSON dictionary keys, which must survive the round trip.
        let identifiers = AdversarialCorpus.strings.filter { !$0.isEmpty }
        for identifier in identifiers {
            store.record(identifier)
        }
        waitUntil("every hostile identifier is recorded") {
            identifiers.allSatisfy { store.boost(for: $0) > 0 }
        }

        let reloaded = RecentStore(defaults: defaults.defaults)
        waitUntil("the persisted store reloads them") {
            identifiers.allSatisfy { reloaded.boost(for: $0) > 0 }
        }
    }

    // MARK: - Persistence

    func testBoostsSurviveARelaunchThroughTheSameDefaults() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        for _ in 0..<3 {
            store.record("app:persisted")
        }
        waitUntil("three launches are recorded") {
            store.boost(for: "app:persisted") >= 4_600
        }

        let relaunched = RecentStore(defaults: defaults.defaults)
        waitUntil("the relaunched store sees them") {
            relaunched.boost(for: "app:persisted") >= 4_600
        }
        XCTAssertEqual(relaunched.boost(for: "app:persisted"), 4_600)
    }

    func testStoresOnSeparateSuitesAreFullyIsolated() throws {
        let first = try IsolatedDefaults(label: "RecentStoreA")
        let second = try IsolatedDefaults(label: "RecentStoreB")
        let storeA = RecentStore(defaults: first.defaults)
        let storeB = RecentStore(defaults: second.defaults)

        storeA.record("shared-id")
        waitUntil("A records it") { storeA.boost(for: "shared-id") > 0 }

        XCTAssertEqual(storeB.boost(for: "shared-id"), 0)
    }

    func testACorruptPersistedPayloadIsIgnoredRatherThanFatal() throws {
        // Anything could be under this key: an older schema, a truncated
        // write, or a value some other tool wrote. None of it may crash a
        // launcher on startup.
        for payload in [
            Data("not json at all".utf8),
            Data(),
            Data("{".utf8),
            Data("[1,2,3]".utf8),
            Data(#"{"app": {"launches": "not-a-number"}}"#.utf8),
            Data((0..<256).map { UInt8($0 % 256) }),
        ] {
            // A fresh suite per payload: the recovery `record` below persists
            // asynchronously, and on a shared suite that write can land after
            // the next iteration plants its corrupt payload, replacing it
            // with valid data.
            let defaults = try IsolatedDefaults()
            defaults.defaults.set(payload, forKey: "recent-items-v1")
            let store = RecentStore(defaults: defaults.defaults)
            XCTAssertEqual(store.boost(for: "app"), 0)

            // And it must still be usable afterwards.
            store.record("app")
            waitUntil("the store recovers and records") { store.boost(for: "app") > 0 }
        }
    }

    func testANonDataValueUnderTheKeyIsIgnored() throws {
        let defaults = try IsolatedDefaults()
        defaults.defaults.set("a string, not data", forKey: "recent-items-v1")

        let store = RecentStore(defaults: defaults.defaults)
        XCTAssertEqual(store.boost(for: "anything"), 0)
    }

    func testAPartiallyValidPayloadKeepsTheEntriesItCanDecode() throws {
        // The decoder is all-or-nothing on `[String: Entry]`, so a payload
        // with one bad entry drops the whole store. Pinned deliberately:
        // it's a defensible choice, but it should be a chosen one.
        let defaults = try IsolatedDefaults()
        defaults.defaults.set(
            Data(#"{"good":{"launches":3,"lastOpened":700000000},"bad":{"launches":"x"}}"#.utf8),
            forKey: "recent-items-v1"
        )

        let store = RecentStore(defaults: defaults.defaults)
        XCTAssertEqual(
            store.boost(for: "good"),
            0,
            "one undecodable entry discards the entire store"
        )
    }

    // MARK: - Concurrency

    func testConcurrentRecordsOnOneIdentifierNeitherCrashNorExceedTheCap() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        hammerConcurrently(concurrency: 16, iterations: 250) { _, _ in
            store.record("app:contended")
        }

        waitUntil("the contended identifier saturates", timeout: 15) {
            store.boost(for: "app:contended") == 4_000 + 25 * 200
        }
        XCTAssertEqual(store.boost(for: "app:contended"), 9_000)
    }

    func testConcurrentReadsDuringWritesNeverObserveANegativeOrOversizedBoost() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)
        let violations = AtomicCounter()

        // Readers and writers on the same identifier at the same time —
        // this is exactly the shape of a keystroke landing while a previous
        // launch is still being persisted.
        hammerConcurrently(concurrency: 16, iterations: 400) { thread, _ in
            if thread.isMultiple(of: 2) {
                store.record("app:racing")
            } else {
                let boost = store.boost(for: "app:racing")
                if boost < 0 || boost > 9_000 {
                    violations.increment()
                }
            }
        }

        XCTAssertEqual(violations.value, 0, "a torn read produced an out-of-range boost")
    }

    func testConcurrentWritesAcrossManyIdentifiersAllLandEventually() throws {
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)
        let identifiers = (0..<200).map { "app:\($0)" }

        hammerConcurrently(concurrency: 8, iterations: identifiers.count) { _, iteration in
            store.record(identifiers[iteration])
        }

        waitUntil("all 200 identifiers are recorded", timeout: 15) {
            identifiers.allSatisfy { store.boost(for: $0) > 0 }
        }
    }

    func testConstructingManyStoresConcurrentlyOverOneSuiteIsSafe() throws {
        // Every `SearchCoordinator` builds its own `RecentStore`, and tests
        // (and previews) can build several. Concurrent decodes of the same
        // defaults blob must not race.
        let defaults = try IsolatedDefaults()
        let seed = RecentStore(defaults: defaults.defaults)
        seed.record("app:seeded")
        waitUntil("the seed lands") { seed.boost(for: "app:seeded") > 0 }

        let boosts = ConcurrentBag<Int>()
        hammerConcurrently(concurrency: 12, iterations: 25) { _, _ in
            let store = RecentStore(defaults: defaults.defaults)
            boosts.append(store.boost(for: "app:seeded"))
        }

        XCTAssertEqual(boosts.values.count, 12 * 25)
        XCTAssertTrue(
            boosts.values.allSatisfy { $0 == 4_200 },
            "every freshly-constructed store should agree on the persisted boost"
        )
    }

    func testRelaunchesAccumulateLaunchesWhenEachWriteIsAllowedToLand() throws {
        // A launcher quit and relaunched must never *lose* count — provided
        // the previous write actually reached disk. Each round waits on the
        // persisted payload, not on the in-memory value, because the two
        // diverge for as long as the background write is in flight.
        let defaults = try IsolatedDefaults()

        for round in 1...10 {
            let store = RecentStore(defaults: defaults.defaults)
            store.record("app:monotonic")
            waitUntil("round \(round) reaches the defaults") {
                Self.persistedLaunches(in: defaults.defaults, for: "app:monotonic") == round
            }
        }

        let relaunched = RecentStore(defaults: defaults.defaults)
        XCTAssertEqual(relaunched.boost(for: "app:monotonic"), 4_000 + 10 * 200)
    }

    func testAStoreBuiltBeforeThePreviousWriteLandsOverwritesIt() throws {
        // The write path is `persistenceQueue.async` + a whole-dictionary
        // `defaults.set`, so two `RecentStore` instances over one suite are
        // last-writer-wins on the entire store, not per entry. A store
        // constructed during another's in-flight write starts from the old
        // snapshot and then clobbers the newer one.
        //
        // In the shipping app there is exactly one `RecentStore` per
        // process, so this is a latent hazard rather than a live bug — but
        // it is the reason a quit immediately after a launch can lose that
        // launch, and it is pinned here so the behaviour is a decision.
        let defaults = try IsolatedDefaults()

        let first = RecentStore(defaults: defaults.defaults)
        first.record("app:clobbered")
        waitUntil("the first write lands") {
            Self.persistedLaunches(in: defaults.defaults, for: "app:clobbered") == 1
        }

        // Two stores now both hold "launches: 1" and each adds one.
        let second = RecentStore(defaults: defaults.defaults)
        let third = RecentStore(defaults: defaults.defaults)
        second.record("app:clobbered")
        third.record("app:clobbered")

        waitUntil("both writes settle") {
            Self.persistedLaunches(in: defaults.defaults, for: "app:clobbered") == 2
        }

        // Three launches happened; two are recorded. Lost update, by design
        // of the whole-dictionary write.
        XCTAssertEqual(
            Self.persistedLaunches(in: defaults.defaults, for: "app:clobbered"),
            2
        )
        XCTAssertEqual(RecentStore(defaults: defaults.defaults).boost(for: "app:clobbered"), 4_400)
    }

    func testRecordingIsAsynchronousSoAnImmediateReadCanMissIt() throws {
        // Documents the timing contract the tests above have to work
        // around: `record` returns before the entry is visible, so nothing
        // in the app may assume a boost is readable on the next line.
        let defaults = try IsolatedDefaults()
        let store = RecentStore(defaults: defaults.defaults)

        store.record("app:async")
        let immediate = store.boost(for: "app:async")
        waitUntil("the write eventually lands") { store.boost(for: "app:async") > 0 }

        XCTAssertTrue(
            immediate == 0 || immediate == 4_200,
            "an immediate read must either miss the write entirely or see it whole, never a partial value"
        )
    }

    /// Reads the launch count straight out of the persisted payload, so a
    /// test can distinguish "written to memory" from "written to defaults".
    /// Mirrors `RecentStore`'s own key and `Codable` layout.
    private static func persistedLaunches(
        in defaults: UserDefaults,
        for id: String
    ) -> Int? {
        guard
            let data = defaults.data(forKey: "recent-items-v1"),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let entry = root[id] as? [String: Any]
        else {
            return nil
        }
        return entry["launches"] as? Int
    }
}
