import FloodlightEngine
import Foundation
import Testing
@testable import Floodlight

struct ResultShowcaseTests {
    // MARK: - Top Hit eligibility

    @Test func firstResultOfAnUnfilteredNonEmptyListIsTopHit() {
        #expect(ResultShowcase.isTopHit(index: 0, resultCount: 5, filter: .all))
        #expect(ResultShowcase.isTopHit(index: 0, resultCount: 1, filter: .all))
    }

    @Test func onlyTheFirstIndexIsEverTopHit() {
        #expect(!(ResultShowcase.isTopHit(index: 1, resultCount: 5, filter: .all)))
        #expect(!(ResultShowcase.isTopHit(index: 6, resultCount: 7, filter: .all)))
    }

    @Test func anActiveFilterDisqualifiesTopHitEvenAtIndexZero() {
        #expect(!(ResultShowcase.isTopHit(index: 0, resultCount: 3, filter: .files)))
        #expect(!(ResultShowcase.isTopHit(index: 0, resultCount: 3, filter: .applications)))
        #expect(!(ResultShowcase.isTopHit(index: 0, resultCount: 3, filter: .settings)))
    }

    @Test func anEmptyResultListIsNeverTopHitRegardlessOfIndex() {
        #expect(!(ResultShowcase.isTopHit(index: 0, resultCount: 0, filter: .all)))
    }

    // MARK: - Empty filter state

    @Test func emptyStateNamesTheActiveFilterAndTheQuery() {
        #expect(ResultShowcase
            .emptyStateMessage(filter: .settings, query: "release notes format") ==
            "No settings results for “release notes format”")
        #expect(ResultShowcase
            .emptyStateMessage(filter: .files, query: "zzz") == "No files results for “zzz”")
    }

    // MARK: - Metadata formatting

    @Test func todayFormatsWithATimeOfDay() {
        let now = Self.fixedNow
        #expect(ResultShowcase.formattedModifiedDate(now, now: now).hasPrefix("Today at "))
    }

    @Test func yesterdayFormatsWithoutATimeOfDay() throws {
        let now = Self.fixedNow
        let yesterday = try #require(Calendar.current.date(byAdding: .day, value: -1, to: now))
        #expect(ResultShowcase.formattedModifiedDate(yesterday, now: now) == "Yesterday")
    }

    @Test func withinThePastWeekFormatsAsWeekdayAndTime() throws {
        let now = Self.fixedNow
        let threeDaysAgo = try #require(Calendar.current.date(byAdding: .day, value: -3, to: now))
        let result = ResultShowcase.formattedModifiedDate(threeDaysAgo, now: now)
        #expect(result.contains(" at "))
        #expect(result != "Yesterday")
        #expect(!result.hasPrefix("Today"))
    }

    @Test func olderThanAWeekFormatsAsAnAbsoluteDateWithNoTime() throws {
        let now = Self.fixedNow
        let longAgo = try #require(Calendar.current.date(byAdding: .day, value: -30, to: now))
        let result = ResultShowcase.formattedModifiedDate(longAgo, now: now)
        #expect(!result.contains(" at "))
        #expect(result != "Yesterday")
    }

    @Test func AFutureDateFallsBackToAnAbsoluteDateRatherThanNegativeDays() throws {
        let now = Self.fixedNow
        let nextWeek = try #require(Calendar.current.date(byAdding: .day, value: 8, to: now))
        let result = ResultShowcase.formattedModifiedDate(nextWeek, now: now)
        #expect(!result.contains(" at "))
        #expect(result != "Yesterday")
    }

    /// 2026-08-08 15:00 UTC — a Saturday, comfortably inside the DST/leap
    /// edge cases the day-boundary math needs to be right about.
    private static let fixedNow = Date(timeIntervalSince1970: 1_785_250_800)
}
