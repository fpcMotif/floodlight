import Darwin
import Foundation
import XCTest
@testable import FloodlightEngine

/// The budget for the selection primitive every catalog's query path runs
/// through.
///
/// `search-path-no-full-sort` bans `.sorted()` in the search path on the claim
/// that bounded selection is cheaper. This is where that claim is measured
/// rather than asserted — if `topRanked` ever stops being sublinear in the
/// discarded tail, the rule is costing correctness for nothing.
///
/// The convention, for whoever adds the next hot path: a new one is not done
/// until it has a budgeted test here. Warm up, take many samples, take the
/// median, and assert against a bound with enough margin to survive a shared
/// CI runner — the budget exists to catch an order-of-magnitude regression,
/// not a 10% one. Print a `FLOODLIGHT_BENCH` line so the actual number is in
/// the log even when the budget holds.
final class SearchItemRankingPerformanceTests: XCTestCase {
    func testTopRankedSelectionBudget() {
        // ~1,500 applications is a heavily-populated Mac, and 12 is the panel's
        // row count: the ratio the bound exists to protect.
        let candidates = makeCandidates(count: 1_500)
        let limit = 12

        for _ in 0..<5 {
            _ = SearchItemRanking.topRanked(candidates, limit: limit)
        }

        let sampleCount = _isDebugAssertConfiguration() ? 3 : 11
        let iterations = _isDebugAssertConfiguration() ? 20 : 200

        let boundedSamples = (0..<sampleCount).map { _ in
            measureCPU(iterations: iterations) {
                SearchItemRanking.topRanked(candidates, limit: limit).count
            }
        }
        let fullSortSamples = (0..<sampleCount).map { _ in
            measureCPU(iterations: iterations) {
                candidates.sorted(by: SearchItemRanking.ranksBefore).prefix(limit).count
            }
        }

        let boundedMicroseconds = median(boundedSamples)
        let fullSortMicroseconds = median(fullSortSamples)

        print(
            "FLOODLIGHT_BENCH top_ranked_selection_us="
                + String(format: "%.3f", boundedMicroseconds)
                + " full_sort_us="
                + String(format: "%.3f", fullSortMicroseconds)
                + " candidates=\(candidates.count) limit=\(limit)"
        )

        XCTAssertLessThan(boundedMicroseconds, 5_000)
        // The point of the rule, stated as a measurement. Generous on purpose:
        // a shared runner's noise floor is wide, and anything under 1.0 here
        // would mean bounded selection had stopped being the cheaper option.
        XCTAssertLessThan(
            boundedMicroseconds,
            fullSortMicroseconds,
            "bounded selection is no longer cheaper than the full sort it replaced"
        )
    }

    func testFuzzyMatcherScoringBudget() {
        let candidates = [
            "Safari",
            "Google Chrome",
            "Visual Studio Code",
            "Ghostty",
            "Raycast",
            "Login Items & Extensions",
            "System Settings",
            "Bluetooth",
            "Wi-Fi",
            "Terminal",
            "Activity Monitor",
            "ColorSync Utility",
        ].map(FuzzyMatcher.normalized)

        let queries = ["saf", "gc", "chrome", "ryacast", "gogle", "gh", "login", "zzz"]
            .map(FuzzyMatcher.normalized)

        // Warm up
        for _ in 0..<5 {
            for query in queries {
                for candidate in candidates {
                    _ = FuzzyMatcher.score(normalizedQuery: query, normalizedCandidate: candidate)
                }
            }
        }

        let sampleCount = _isDebugAssertConfiguration() ? 3 : 11
        let iterations = _isDebugAssertConfiguration() ? 20 : 100

        let samples = (0..<sampleCount).map { _ in
            measureCPU(iterations: iterations) {
                var matches = 0
                for query in queries {
                    for candidate in candidates
                        where (FuzzyMatcher.score(
                            normalizedQuery: query,
                            normalizedCandidate: candidate
                        ) ?? 0) > 0
                    {
                        matches += 1
                    }
                }
                return matches
            }
        }

        let microseconds = median(samples)
        print(
            "FLOODLIGHT_BENCH fuzzy_matcher_scoring_us="
                + String(format: "%.3f", microseconds)
                + " queries=\(queries.count) candidates=\(candidates.count)"
        )

        XCTAssertLessThan(microseconds, 5_000)
    }

    private func makeCandidates(count: Int) -> [SearchItem] {
        (0..<count).map { index in
            let url = URL(fileURLWithPath: "/Applications/Fixture-\(index).app")
            return SearchItem(
                id: "fixture:\(index)",
                title: "Fixture \(String(format: "%05d", (index * 37) % 65_537))",
                subtitle: url.path,
                kind: .application,
                action: .open(url),
                score: (index * 17) % 2_048,
                fileURL: url
            )
        }
    }

    private func measureCPU(iterations: Int, operation: () -> Int) -> Double {
        var checksum = 0
        let start = processCPUTime()
        for _ in 0..<iterations {
            checksum &+= operation()
        }
        let elapsed = processCPUTime() - start
        XCTAssertGreaterThan(checksum, 0)
        return elapsed * 1_000_000 / Double(iterations)
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
