import FloodlightEngine
import Foundation
import XCTest
@testable import Floodlight

/// Harsh, critical stress tests for `ResultShowcase` — boundary conditions
/// and edge cases for Top Hit eligibility, empty state messages, and
/// date formatting.
final class ResultShowcaseStressTests: XCTestCase {

    // MARK: - isTopHit exhaustive

    func testIsTopHitAllFilters() {
        for filter in SearchResultFilter.allCases {
            let result = ResultShowcase.isTopHit(index: 0, resultCount: 5, filter: filter)
            if filter == .all {
                XCTAssertTrue(result, "index 0 with .all filter should be top hit")
            } else {
                XCTAssertFalse(result, "index 0 with \(filter) filter should not be top hit")
            }
        }
    }

    func testIsTopHitWithAllNonZeroIndices() {
        for index in 1...10 {
            XCTAssertFalse(
                ResultShowcase.isTopHit(index: index, resultCount: 20, filter: .all),
                "index \(index) should never be top hit"
            )
        }
    }

    func testIsTopHitWithZeroResultCount() {
        XCTAssertFalse(ResultShowcase.isTopHit(index: 0, resultCount: 0, filter: .all))
    }

    func testIsTopHitWithNegativeIndex() {
        // Negative index should not be top hit (index 0 is the minimum)
        XCTAssertFalse(ResultShowcase.isTopHit(index: -1, resultCount: 5, filter: .all))
    }

    // MARK: - emptyStateMessage for all filters

    func testEmptyStateMessageForAllFilters() {
        let query = "test query"
        for filter in SearchResultFilter.allCases {
            let message = ResultShowcase.emptyStateMessage(filter: filter, query: query)
            XCTAssertTrue(message.contains(filter.title.lowercased()),
                "message should contain filter title for \(filter)")
            XCTAssertTrue(message.contains(query),
                "message should contain query for \(filter)")
            XCTAssertTrue(message.hasPrefix("No "),
                "message should start with 'No' for \(filter)")
        }
    }

    func testEmptyStateMessageWithEmptyQuery() {
        let message = ResultShowcase.emptyStateMessage(filter: .files, query: "")
        XCTAssertTrue(message.contains("files"))
    }

    func testEmptyStateMessageWithSpecialCharacters() {
        let message = ResultShowcase.emptyStateMessage(filter: .all, query: "test \"quotes\" & <html>")
        XCTAssertTrue(message.contains("test"))
    }

    // MARK: - formattedModifiedDate boundary conditions

    func testFormattedModifiedDateForNow() {
        let now = Date()
        let result = ResultShowcase.formattedModifiedDate(now, now: now)
        XCTAssertTrue(result.hasPrefix("Today at "))
    }

    func testFormattedModifiedDateForYesterday() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let result = ResultShowcase.formattedModifiedDate(yesterday, now: now)
        XCTAssertEqual(result, "Yesterday")
    }

    func testFormattedModifiedDateForTwoDaysAgo() {
        let now = Date()
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!
        let result = ResultShowcase.formattedModifiedDate(twoDaysAgo, now: now)
        XCTAssertTrue(result.contains(" at "))
        XCTAssertFalse(result.hasPrefix("Today"))
        XCTAssertNotEqual(result, "Yesterday")
    }

    func testFormattedModifiedDateForSixDaysAgo() {
        let now = Date()
        let sixDaysAgo = Calendar.current.date(byAdding: .day, value: -6, to: now)!
        let result = ResultShowcase.formattedModifiedDate(sixDaysAgo, now: now)
        XCTAssertTrue(result.contains(" at "))
    }

    func testFormattedModifiedDateForSevenDaysAgo() {
        let now = Date()
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let result = ResultShowcase.formattedModifiedDate(sevenDaysAgo, now: now)
        XCTAssertFalse(result.contains(" at "))
        XCTAssertFalse(result.hasPrefix("Today"))
        XCTAssertNotEqual(result, "Yesterday")
    }

    func testFormattedModifiedDateForOneYearAgo() {
        let now = Date()
        let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let result = ResultShowcase.formattedModifiedDate(oneYearAgo, now: now)
        XCTAssertFalse(result.contains(" at "))
        XCTAssertFalse(result.hasPrefix("Today"))
        XCTAssertNotEqual(result, "Yesterday")
    }

    func testFormattedModifiedDateForFutureDate() {
        let now = Date()
        let future = Calendar.current.date(byAdding: .day, value: 30, to: now)!
        let result = ResultShowcase.formattedModifiedDate(future, now: now)
        XCTAssertFalse(result.contains(" at "))
        XCTAssertNotEqual(result, "Yesterday")
    }

    func testFormattedModifiedDateForFarFuture() {
        let now = Date()
        let farFuture = Calendar.current.date(byAdding: .year, value: 10, to: now)!
        let result = ResultShowcase.formattedModifiedDate(farFuture, now: now)
        XCTAssertFalse(result.contains(" at "))
    }

    // MARK: - formattedModifiedDate with custom calendar

    func testFormattedModifiedDateWithCustomCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_785_250_800)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let result = ResultShowcase.formattedModifiedDate(yesterday, now: now, calendar: calendar)
        XCTAssertEqual(result, "Yesterday")
    }

    // MARK: - formattedModifiedDate determinism

    func testFormattedModifiedDateIsDeterministic() {
        let now = Date()
        let date = Calendar.current.date(byAdding: .day, value: -3, to: now)!
        let result1 = ResultShowcase.formattedModifiedDate(date, now: now)
        let result2 = ResultShowcase.formattedModifiedDate(date, now: now)
        XCTAssertEqual(result1, result2)
    }

    // MARK: - Day boundary edge cases

    func testFormattedModifiedDateAtMidnightBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let result = ResultShowcase.formattedModifiedDate(yesterday, now: now, calendar: calendar)
        XCTAssertEqual(result, "Yesterday")
    }

    func testFormattedModifiedDateJustBeforeMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(86399) // 23:59:59
        let yesterday = calendar.startOfDay(for: Date()).addingTimeInterval(-1) // 23:59:59 previous day
        let result = ResultShowcase.formattedModifiedDate(yesterday, now: now, calendar: calendar)
        XCTAssertEqual(result, "Yesterday")
    }
}
