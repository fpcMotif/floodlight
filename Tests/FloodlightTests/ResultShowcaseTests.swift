import FloodlightEngine
import XCTest
@testable import Floodlight

final class ResultShowcaseTests: XCTestCase {
    // MARK: - Top Hit eligibility

    func testFirstResultOfAnUnfilteredNonEmptyListIsTopHit() {
        XCTAssertTrue(ResultShowcase.isTopHit(index: 0, resultCount: 5, filter: .all))
        XCTAssertTrue(ResultShowcase.isTopHit(index: 0, resultCount: 1, filter: .all))
    }

    func testOnlyTheFirstIndexIsEverTopHit() {
        XCTAssertFalse(ResultShowcase.isTopHit(index: 1, resultCount: 5, filter: .all))
        XCTAssertFalse(ResultShowcase.isTopHit(index: 6, resultCount: 7, filter: .all))
    }

    func testAnActiveFilterDisqualifiesTopHitEvenAtIndexZero() {
        XCTAssertFalse(ResultShowcase.isTopHit(index: 0, resultCount: 3, filter: .files))
        XCTAssertFalse(ResultShowcase.isTopHit(index: 0, resultCount: 3, filter: .applications))
        XCTAssertFalse(ResultShowcase.isTopHit(index: 0, resultCount: 3, filter: .settings))
    }

    func testAnEmptyResultListIsNeverTopHitRegardlessOfIndex() {
        XCTAssertFalse(ResultShowcase.isTopHit(index: 0, resultCount: 0, filter: .all))
    }

    // MARK: - Empty filter state

    func testEmptyStateNamesTheActiveFilterAndTheQuery() {
        XCTAssertEqual(
            ResultShowcase.emptyStateMessage(filter: .settings, query: "release notes format"),
            "No settings results for “release notes format”"
        )
        XCTAssertEqual(
            ResultShowcase.emptyStateMessage(filter: .files, query: "zzz"),
            "No files results for “zzz”"
        )
    }

    // MARK: - Metadata formatting

    func testTodayFormatsWithATimeOfDay() {
        let now = Self.fixedNow
        XCTAssertTrue(
            ResultShowcase.formattedModifiedDate(now, now: now).hasPrefix("Today at ")
        )
    }

    func testYesterdayFormatsWithoutATimeOfDay() {
        let now = Self.fixedNow
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(ResultShowcase.formattedModifiedDate(yesterday, now: now), "Yesterday")
    }

    func testWithinThePastWeekFormatsAsWeekdayAndTime() {
        let now = Self.fixedNow
        let threeDaysAgo = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        let result = ResultShowcase.formattedModifiedDate(threeDaysAgo, now: now)
        XCTAssertTrue(result.contains(" at "))
        XCTAssertNotEqual(result, "Yesterday")
        XCTAssertFalse(result.hasPrefix("Today"))
    }

    func testOlderThanAWeekFormatsAsAnAbsoluteDateWithNoTime() {
        let now = Self.fixedNow
        let longAgo = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let result = ResultShowcase.formattedModifiedDate(longAgo, now: now)
        XCTAssertFalse(result.contains(" at "))
        XCTAssertNotEqual(result, "Yesterday")
    }

    func testAFutureDateFallsBackToAnAbsoluteDateRatherThanNegativeDays() {
        let now = Self.fixedNow
        let nextWeek = Calendar.current.date(byAdding: .day, value: 8, to: now)!
        let result = ResultShowcase.formattedModifiedDate(nextWeek, now: now)
        XCTAssertFalse(result.contains(" at "))
        XCTAssertNotEqual(result, "Yesterday")
    }

    /// 2026-08-08 15:00 UTC — a Saturday, comfortably inside the DST/leap
    /// edge cases the day-boundary math needs to be right about.
    private static let fixedNow = Date(timeIntervalSince1970: 1_785_250_800)
}
