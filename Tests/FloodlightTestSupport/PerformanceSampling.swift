import Darwin
import Foundation

// The sampling a wall-clock or CPU budget test does around its measurements.
//
// Deliberately not the only such pair in the suite: `SearchPerformanceTests`
// and `SearchItemRankingPerformanceTests` take an upper-middle median over
// `CLOCK_PROCESS_CPUTIME_ID`, and their `XCTAssertLessThan` budgets are
// calibrated against those numbers. Folding them in here would move every one
// of those thresholds by a little, silently. This is the clipboard suites'
// spelling, which was identical in both of them.

/// The middle value, averaging the two middles for an even count.
package func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let count = sorted.count
    if count.isMultiple(of: 2) {
        return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
    }
    return sorted[count / 2]
}

/// User plus system CPU seconds this process has burned so far.
package func processCPUTime() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
    return user + system
}
