import Foundation
import XCTest
@testable import FloodlightEngine

/// Comprehensive tests for `CatalogRefreshGuard` — the throttle that
/// prevents repeated keystrokes from stacking up filesystem walks.
final class CatalogRefreshGuardTests: XCTestCase {

    // MARK: - Basic reserve/release

    func testFirstReserveSucceeds() {
        let guard_ = CatalogRefreshGuard()
        XCTAssertTrue(guard_.reserve(minimumInterval: 2))
    }

    func testReserveThenReleaseAllowsAnotherReserve() {
        let guard_ = CatalogRefreshGuard()
        XCTAssertTrue(guard_.reserve(minimumInterval: 2))
        guard_.release()
        XCTAssertTrue(guard_.reserve(minimumInterval: 2))
    }

    func testReserveWithoutReleaseBlocksSecondReserve() {
        let guard_ = CatalogRefreshGuard()
        XCTAssertTrue(guard_.reserve(minimumInterval: 2))
        XCTAssertFalse(guard_.reserve(minimumInterval: 2))
    }

    // MARK: - Minimum interval

    func testReserveRespectsMinimumInterval() {
        let guard_ = CatalogRefreshGuard()
        XCTAssertTrue(guard_.reserve(minimumInterval: 100))
        guard_.release()
        // Immediately after release, within the minimum interval
        XCTAssertFalse(guard_.reserve(minimumInterval: 100))
    }

    func testZeroMinimumIntervalAllowsImmediateReserveAfterRelease() {
        let guard_ = CatalogRefreshGuard()
        XCTAssertTrue(guard_.reserve(minimumInterval: 0))
        guard_.release()
        XCTAssertTrue(guard_.reserve(minimumInterval: 0))
    }

    // MARK: - Release is idempotent

    func testDoubleReleaseIsSafe() {
        let guard_ = CatalogRefreshGuard()
        guard_.reserve(minimumInterval: 0)
        guard_.release()
        guard_.release() // should not crash
    }

    func testReleaseWithoutReserveIsSafe() {
        let guard_ = CatalogRefreshGuard()
        guard_.release() // should not crash
        XCTAssertTrue(guard_.reserve(minimumInterval: 0))
    }

    // MARK: - Multiple guards are independent

    func testMultipleGuardsAreIndependent() {
        let guard1 = CatalogRefreshGuard()
        let guard2 = CatalogRefreshGuard()

        XCTAssertTrue(guard1.reserve(minimumInterval: 100))
        XCTAssertTrue(guard2.reserve(minimumInterval: 100))
        XCTAssertFalse(guard1.reserve(minimumInterval: 100))
        XCTAssertFalse(guard2.reserve(minimumInterval: 100))

        guard1.release()
        XCTAssertFalse(guard1.reserve(minimumInterval: 100))
        XCTAssertTrue(guard2.reserve(minimumInterval: 0))
    }

    // MARK: - Interval boundary

    func testIntervalBoundaryIsInclusive() {
        let guard_ = CatalogRefreshGuard()
        XCTAssertTrue(guard_.reserve(minimumInterval: 0))
        guard_.release()
        // With interval 0, immediate reserve should succeed
        XCTAssertTrue(guard_.reserve(minimumInterval: 0))
    }

    // MARK: - Concurrent access

    func testConcurrentReserveOnlyOneSucceeds() {
        let guard_ = CatalogRefreshGuard()
        let expectation = expectation(description: "concurrent reserve")
        let count = 100
        var successCount = 0
        let lock = NSLock()

        for _ in 0..<count {
            DispatchQueue.global().async {
                if guard_.reserve(minimumInterval: 100) {
                    lock.lock()
                    successCount += 1
                    lock.unlock()
                }
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(successCount, 1, "exactly one concurrent reserve should succeed")
    }

    // MARK: - Reserve after interval expires

    func testReserveSucceedsAfterIntervalExpires() {
        let guard_ = CatalogRefreshGuard()
        XCTAssertTrue(guard_.reserve(minimumInterval: 0))
        guard_.release()

        // With minimumInterval 0, the lastRefresh timestamp was set
        // but 0 interval means any time difference qualifies
        XCTAssertTrue(guard_.reserve(minimumInterval: 0))
    }
}
