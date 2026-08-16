import FloodlightEngine
import Foundation
import Testing
@testable import Floodlight

struct ResultShowcaseStressTests {
    // MARK: - isTopHit for all filters

    @Test func isTopHitForAllFilters() {
        for filter in SearchResultFilter.allCases {
            switch filter {
            case .all:
                #expect(
                    ResultShowcase.isTopHit(index: 0, resultCount: 5, filter: .all),
                    "expected top hit for \(filter)"
                )
            default:
                #expect(
                    !(ResultShowcase.isTopHit(index: 0, resultCount: 5, filter: filter)),
                    "expected no top hit for \(filter)"
                )
            }
        }
    }

    @Test func isTopHitFalseForAllNonZeroIndices() {
        for index in 1..<10 {
            #expect(
                !(ResultShowcase.isTopHit(index: index, resultCount: 10, filter: .all)),
                "expected no top hit at index \(index)"
            )
        }
    }

    @Test func isTopHitFalseForZeroResultCount() {
        #expect(!(ResultShowcase.isTopHit(index: 0, resultCount: 0, filter: .all)))
    }

    @Test func isTopHitFalseForNegativeIndex() {
        #expect(!(ResultShowcase.isTopHit(index: -1, resultCount: 5, filter: .all)))
        #expect(!(ResultShowcase.isTopHit(index: -100, resultCount: 5, filter: .all)))
    }

    @Test func isTopHitTrueOnlyForAllFilterAtIndexZeroWithResults() {
        #expect(ResultShowcase.isTopHit(index: 0, resultCount: 1, filter: .all))
        #expect(ResultShowcase.isTopHit(index: 0, resultCount: 100, filter: .all))
    }

    // MARK: - emptyStateMessage for all filters

    @Test func emptyStateMessageForAllFilters() {
        for filter in SearchResultFilter.allCases {
            let message = ResultShowcase.emptyStateMessage(filter: filter, query: "test")
            #expect(message.hasPrefix("No "))
            #expect(message.contains("test"))
        }
    }

    @Test func emptyStateMessageForEmptyQuery() {
        for filter in SearchResultFilter.allCases {
            let message = ResultShowcase.emptyStateMessage(filter: filter, query: "")
            #expect(message.contains("“”"))
        }
    }

    @Test func emptyStateMessageWithSpecialCharacters() {
        let message = ResultShowcase.emptyStateMessage(
            filter: .files,
            query: "test \"quotes\" & <html>"
        )
        #expect(message.contains("test \"quotes\" & <html>"))
    }

    @Test func emptyStateMessageUsesLowercasedFilterTitle() {
        #expect(ResultShowcase
            .emptyStateMessage(filter: .applications, query: "x") == "No apps results for “x”")
        #expect(ResultShowcase
            .emptyStateMessage(filter: .settings, query: "x") == "No settings results for “x”")
        #expect(ResultShowcase
            .emptyStateMessage(filter: .all, query: "x") == "No all results for “x”")
    }

    // MARK: - formattedModifiedDate

    /// 2026-08-08 15:00 UTC — a Saturday, fixed for deterministic tests.
    private static let fixedNow = Date(timeIntervalSince1970: 1_785_250_800)

    @Test func formattedModifiedDateForNow() {
        let now = Self.fixedNow
        let result = ResultShowcase.formattedModifiedDate(now, now: now)
        #expect(result.hasPrefix("Today at "))
    }

    @Test func formattedModifiedDateForYesterday() throws {
        let now = Self.fixedNow
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        #expect(ResultShowcase.formattedModifiedDate(yesterday, now: now) == "Yesterday")
    }

    @Test func formattedModifiedDateForTwoToSixDaysAgo() throws {
        let now = Self.fixedNow
        for daysAgo in 2...6 {
            let date = try #require(Calendar.current.date(
                byAdding: .day,
                value: -daysAgo,
                to: now
            ))
            let result = ResultShowcase.formattedModifiedDate(date, now: now)
            #expect(
                result.contains(" at "),
                "expected weekday-and-time for \(daysAgo) days ago, got \(result)"
            )
            #expect(result != "Yesterday")
            #expect(!result.hasPrefix("Today"))
        }
    }

    @Test func formattedModifiedDateForSevenDaysAgo() throws {
        let now = Self.fixedNow
        let sevenDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -7, to: now))
        let result = ResultShowcase.formattedModifiedDate(sevenDaysAgo, now: now)
        // 7 days ago falls outside the 2...6 range, so it's an absolute date.
        #expect(!result.contains(" at "))
        #expect(result != "Yesterday")
        #expect(!result.hasPrefix("Today"))
    }

    @Test func formattedModifiedDateForOneYearAgo() throws {
        let now = Self.fixedNow
        let oneYearAgo = try #require(Calendar.current.date(byAdding: .year, value: -1, to: now))
        let result = ResultShowcase.formattedModifiedDate(oneYearAgo, now: now)
        #expect(!result.contains(" at "))
        #expect(result != "Yesterday")
        #expect(!result.hasPrefix("Today"))
    }

    @Test func formattedModifiedDateForFutureDate() throws {
        let now = Self.fixedNow
        let future = try #require(Calendar.current.date(byAdding: .day, value: 5, to: now))
        let result = ResultShowcase.formattedModifiedDate(future, now: now)
        // Future dates fall through to the absolute-date branch.
        #expect(!result.contains(" at "))
        #expect(result != "Yesterday")
        #expect(!result.hasPrefix("Today"))
    }

    @Test func formattedModifiedDateForFarFuture() throws {
        let now = Self.fixedNow
        let farFuture = try #require(Calendar.current.date(byAdding: .year, value: 10, to: now))
        let result = ResultShowcase.formattedModifiedDate(farFuture, now: now)
        #expect(!result.contains(" at "))
        #expect(result != "Yesterday")
        #expect(!result.hasPrefix("Today"))
    }

    @Test func formattedModifiedDateWithCustomCalendar() throws {
        let now = Self.fixedNow
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let result = ResultShowcase.formattedModifiedDate(now, now: now, calendar: calendar)
        #expect(result.hasPrefix("Today at "))
    }

    @Test func formattedModifiedDateIsDeterministic() throws {
        let now = Self.fixedNow
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let first = ResultShowcase.formattedModifiedDate(yesterday, now: now)
        let second = ResultShowcase.formattedModifiedDate(yesterday, now: now)
        #expect(first == second)
    }

    @Test func formattedModifiedDateAtMidnightBoundary() {
        let now = Self.fixedNow
        let startOfNow = Calendar.current.startOfDay(for: now)
        // Exactly midnight of "today" -> Today at ...
        let result = ResultShowcase.formattedModifiedDate(startOfNow, now: now)
        #expect(result.hasPrefix("Today at "))
    }

    @Test func formattedModifiedDateJustBeforeMidnight() {
        let now = Self.fixedNow
        let startOfNow = Calendar.current.startOfDay(for: now)
        let justBeforeMidnight = startOfNow.addingTimeInterval(-1)
        // Just before midnight is the previous day -> Yesterday (1 day ago).
        let result = ResultShowcase.formattedModifiedDate(justBeforeMidnight, now: now)
        #expect(result == "Yesterday")
    }
}
