import Darwin
import Foundation
import XCTest
@testable import Floodlight

final class SearchPerformanceTests: XCTestCase {
    func testFastApplicationSearchPerformanceBudget() {
        let suiteName = "FloodlightPerformanceTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let catalog = ApplicationCatalog(
            recentStore: RecentStore(defaults: defaults)
        )
        let queries = [
            "a",
            "cl",
            "claude",
            "calendar",
            "xcode",
            "safari",
            "notes",
            "terminal",
        ]

        for query in queries {
            _ = catalog.fastSearch(query)
        }

        let iterations = 80
        var samples: [Double] = []
        var resultCount = 0

        for _ in 0..<9 {
            let sample = measure(iterations: iterations, queries: queries) { query in
                catalog.fastSearch(query)
            }
            samples.append(sample.microsecondsPerQuery)
            resultCount += sample.resultCount
        }
        let microsecondsPerQuery = median(samples)

        print(
            "FLOODLIGHT_BENCH fast_application_search_us="
                + String(format: "%.3f", microsecondsPerQuery)
                + " results=\(resultCount)"
        )
        XCTAssertLessThan(microsecondsPerQuery, 1_000)
    }

    private func measure(
        iterations: Int,
        queries: [String],
        search: (String) -> [SearchItem]
    ) -> (microsecondsPerQuery: Double, resultCount: Int) {
        var resultCount = 0
        let start = processCPUTime()
        for _ in 0..<iterations {
            for query in queries {
                resultCount += search(query).count
            }
        }
        let elapsed = processCPUTime() - start
        let queryCount = iterations * queries.count
        return (
            elapsed * 1_000_000 / Double(queryCount),
            resultCount
        )
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func processCPUTime() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}
