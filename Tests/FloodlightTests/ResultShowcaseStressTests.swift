import FloodlightEngine
import Foundation
import XCTest
@testable import Floodlight

final class ResultShowcaseStressTests: XCTestCase {
    // MARK: - isTopHit for all filters

    func testIsTopHitForAllFilters() {
        for filter in SearchResultFilter.allCases {
            switch filter {
            case .all:
                XCTAssertTrue(
                    ResultShowcase.isTopHit(index: 0, resultCount: 5, filter: .all),
                    "expected top hit for \(filter)"
                )
            default:
                XCTAssertFalse(
                    ResultShowcase.isTopHit(index: 0, resultCount: 5, filter: filter),
                    "expected no top hit for \(filter)"
                )
            }
        }
    }

    func testIsTopHitFalseForAllNonZeroIndices() {
        for index in 1..<10 {
            XCTAssertFalse(
                ResultShowcase.isTopHit(index: index, resultCount: 10, filter: .all),
                "expected no top hit at index \(index)"
            )
        }
    }

    func testIsTopHitFalseForZeroResultCount() {
        XCTAssertFalse(
            ResultShowcase.isTopHit(index: 0, resultCount: 0, filter: .all)
        )
    }

    func testIsTopHitFalseForNegativeIndex() {
        XCTAssertFalse(
            ResultShowcase.isTopHit(index: -1, resultCount: 5, filter: .all)
        )
        XCTAssertFalse(
            ResultShowcase.isTopHit(index: -100, resultCount: 5, filter: .all)
        )
    }

    func testIsTopHitTrueOnlyForAllFilterAtIndexZeroWithResults() {
        XCTAssertTrue(ResultShowcase.isTopHit(index: 0, resultCount: 1, filter: .all))
        XCTAssertTrue(ResultShowcase.isTopHit(index: 0, resultCount: 100, filter: .all))
    }

    // MARK: - emptyStateMessage for all filters

    func testEmptyStateMessageForAllFilters() {
        for filter in SearchResultFilter.allCases {
            let message = ResultShowcase.emptyStateMessage(filter: filter, query: "test")
            XCTAssertTrue(message.hasPrefix("No "))
            XCTAssertTrue(message.contains("test"))
        }
    }

    func testEmptyStateMessageForEmptyQuery() {
        for filter in SearchResultFilter.allCases {
            let message = ResultShowcase.emptyStateMessage(filter: filter, query: "")
            XCTAssertTrue(message.contains("“”"))
        }
    }

    func testEmptyStateMessageWithSpecialCharacters() {
        let message = ResultShowcase.emptyStateMessage(
            filter: .files,
            query: "test \"quotes\" & <html>"
        )
        XCTAssertTrue(message.contains("test \"quotes\" & <html>"))
    }

    func testEmptyStateMessageUsesLowercasedFilterTitle() {
        XCTAssertEqual(
            ResultShowcase.emptyStateMessage(filter: .applications, query: "x"),
            "No apps results for “x”"
        )
        XCTAssertEqual(
            ResultShowcase.emptyStateMessage(filter: .settings, query: "x"),
            "No settings results for “x”"
        )
        XCTAssertEqual(
            ResultShowcase.emptyStateMessage(filter: .all, query: "x"),
            "No all results for “x”"
        )
    }

    // MARK: - formattedModifiedDate

    /// 2026-08-08 15:00 UTC — a Saturday, fixed for deterministic tests.
    private static let fixedNow = Date(timeIntervalSince1970: 1_785_250_800)

    func testFormattedModifiedDateForNow() {
        let now = Self.fixedNow
        let result = ResultShowcase.formattedModifiedDate(now, now: now)
        XCTAssertTrue(result.hasPrefix("Today at "))
    }

    func testFormattedModifiedDateForYesterday() {
        let now = Self.fixedNow
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(
            ResultShowcase.formattedModifiedDate(yesterday, now: now),
            "Yesterday"
        )
    }

    func testFormattedModifiedDateForTwoToSixDaysAgo() {
        let now = Self.fixedNow
        for daysAgo in 2...6 {
            let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
            let result = ResultShowcase.formattedModifiedDate(date, now: now)
            XCTAssertTrue(
                result.contains(" at "),
                "expected weekday-and-time for \(daysAgo) days ago, got \(result)"
            )
            XCTAssertFalse(result == "Yesterday")
            XCTAssertFalse(result.hasPrefix("Today"))
        }
    }

    func testFormattedModifiedDateForSevenDaysAgo() {
        let now = Self.fixedNow
        let sevenDaysAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let result = ResultShowcase.formattedModifiedDate(sevenDaysAgo, now: now)
        // 7 days ago falls outside the 2...6 range, so it's an absolute date.
        XCTAssertFalse(result.contains(" at "))
        XCTAssertFalse(result == "Yesterday")
        XCTAssertFalse(result.hasPrefix("Today"))
    }

    func testFormattedModifiedDateForOneYearAgo() {
        let now = Self.fixedNow
        let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: now)!
        let result = ResultShowcase.formattedModifiedDate(oneYearAgo, now: now)
        XCTAssertFalse(result.contains(" at "))
        XCTAssertFalse(result == "Yesterday")
        XCTAssertFalse(result.hasPrefix("Today"))
    }

    func testFormattedModifiedDateForFutureDate() {
        let now = Self.fixedNow
        let future = Calendar.current.date(byAdding: .day, value: 5, to: now)!
        let result = ResultShowcase.formattedModifiedDate(future, now: now)
        // Future dates fall through to the absolute-date branch.
        XCTAssertFalse(result.contains(" at "))
        XCTAssertFalse(result == "Yesterday")
        XCTAssertFalse(result.hasPrefix("Today"))
    }

    func testFormattedModifiedDateForFarFuture() {
        let now = Self.fixedNow
        let farFuture = Calendar.current.date(byAdding: .year, value: 10, to: now)!
        let result = ResultShowcase.formattedModifiedDate(farFuture, now: now)
        XCTAssertFalse(result.contains(" at "))
        XCTAssertFalse(result == "Yesterday")
        XCTAssertFalse(result.hasPrefix("Today"))
    }

    func testFormattedModifiedDateWithCustomCalendar() {
        let now = Self.fixedNow
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let result = ResultShowcase.formattedModifiedDate(now, now: now, calendar: calendar)
        XCTAssertTrue(result.hasPrefix("Today at "))
    }

    func testFormattedModifiedDateIsDeterministic() {
        let now = Self.fixedNow
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let first = ResultShowcase.formattedModifiedDate(yesterday, now: now)
        let second = ResultShowcase.formattedModifiedDate(yesterday, now: now)
        XCTAssertEqual(first, second)
    }

    func testFormattedModifiedDateAtMidnightBoundary() {
        let now = Self.fixedNow
        let startOfNow = Calendar.current.startOfDay(for: now)
        // Exactly midnight of "today" -> Today at ...
        let result = ResultShowcase.formattedModifiedDate(startOfNow, now: now)
        XCTAssertTrue(result.hasPrefix("Today at "))
    }

    func testFormattedModifiedDateJustBeforeMidnight() {
        let now = Self.fixedNow
        let startOfNow = Calendar.current.startOfDay(for: now)
        let justBeforeMidnight = startOfNow.addingTimeInterval(-1)
        // Just before midnight is the previous day -> Yesterday (1 day ago).
        let result = ResultShowcase.formattedModifiedDate(justBeforeMidnight, now: now)
        XCTAssertEqual(result, "Yesterday")
    }
}
