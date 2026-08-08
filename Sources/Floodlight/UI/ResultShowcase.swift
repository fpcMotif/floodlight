import FloodlightEngine
import Foundation

/// Pure presentation decisions for the result list — Top Hit eligibility,
/// the empty-filter message, and Finder-style metadata formatting.
///
/// Ranking, filtering, and selection stay entirely in `SearchCoordinator`;
/// this type only decides how what's already been decided gets shown, so
/// each decision is testable without rendering a view.
enum ResultShowcase {
    /// The first result of a non-empty, unfiltered list earns the Top Hit
    /// treatment. The moment a filter chip narrows the list, the user has
    /// already stated intent, so Top Hit disappears — filtered results are
    /// never eligible, regardless of index.
    static func isTopHit(index: Int, resultCount: Int, filter: SearchResultFilter) -> Bool {
        index == 0 && resultCount > 0 && filter == .all
    }

    /// A quiet message naming both the active filter and the query, shown
    /// only when that filter yields zero rows — the unfiltered list is
    /// never empty, since the web fallback always fills the last slot.
    static func emptyStateMessage(filter: SearchResultFilter, query: String) -> String {
        "No \(filter.title.lowercased()) results for “\(query)”"
    }

    /// Finder's own relative-date vocabulary: a bare time today, "Yesterday"
    /// with no time, weekday-and-time within the past week, and a plain
    /// absolute date beyond that (or for a future date, which a file's
    /// modification time should never be, but a clock skew might produce).
    static func formattedModifiedDate(
        _ date: Date,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        // `Calendar.isDateInToday`/`isDateInYesterday` compare against the
        // real system clock, not an injectable "now" — deliberately unused
        // here so `now` stays the single source of truth and the tiers stay
        // testable without depending on the day the test happens to run.
        let startOfDate = calendar.startOfDay(for: date)
        let startOfNow = calendar.startOfDay(for: now)
        let daysAgo = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? .max

        switch daysAgo {
        case 0:
            return "Today at \(timeOfDay(date))"
        case 1:
            return "Yesterday"
        case 2...6:
            return "\(weekday(date)) at \(timeOfDay(date))"
        default:
            return absoluteDate(date)
        }
    }

    private static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide))
    }

    private static func absoluteDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
