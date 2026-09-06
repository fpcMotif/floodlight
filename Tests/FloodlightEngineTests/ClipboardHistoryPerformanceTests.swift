import FloodlightTestSupport
import Foundation
import XCTest
@testable import FloodlightEngine

final class ClipboardHistoryPerformanceTests: XCTestCase {
    func testClipboardHistorySearchPerformanceBudget() throws {
        let store = ClipboardHistoryStore.inMemory()

        // Populate with 1,000 realistic clipboard entries
        let sampleTexts = [
            "https://github.com/fpcMotif/floodlight/pull/42",
            "func performSearch(query: String) async throws -> [SearchItem]",
            "Acme billing address: 123 Market St, Suite 400, San Francisco, CA 94105",
            "ssh -i ~/.ssh/id_ed25519 user@server.example.com",
            "SELECT id, text, created_at FROM clipboard_entries WHERE rowid IN (SELECT rowid FROM clipboard_fts);",
            "Meeting notes from 2026-09-01: discussed architecture, seams, and performance budgets.",
            "npm install @floodlight/core --save-dev",
            "git rebase -i HEAD~4",
            "Total balance due: $1,420.50 USD (invoice #98214)",
            "The quick brown fox jumps over the lazy dog 🦊",
        ]
        for index in 0..<1_000 {
            let base = sampleTexts[index % sampleTexts.count]
            let entry = try XCTUnwrap(store.record(
                text: "\(base) #\(index)",
                sourceAppBundleID: "com.apple.Notes"
            ))
            if index % 50 == 0 {
                store.pin(id: entry.id)
            }
        }

        let queries = [
            "",
            "a",
            "in",
            "invoice",
            "performSearch",
            "address",
            "notes",
            "github",
        ]

        // Warm up
        for query in queries {
            _ = store.search(query: query)
        }

        let sampleCount = _isDebugAssertConfiguration() ? 3 : 11
        let iterations = _isDebugAssertConfiguration() ? 20 : 100

        var samples: [Double] = []
        var totalResults = 0

        for _ in 0..<sampleCount {
            let start = processCPUTime()
            for _ in 0..<iterations {
                for query in queries {
                    totalResults += store.search(query: query).count
                }
            }
            let elapsedSeconds = processCPUTime() - start
            let microsecondsPerQuery = (elapsedSeconds * 1_000_000.0) /
                Double(iterations * queries.count)
            samples.append(microsecondsPerQuery)
        }

        let medianMicroseconds = median(samples)

        print(
            "FLOODLIGHT_BENCH clipboard_search_us="
                + String(format: "%.3f", medianMicroseconds)
                + " queries=\(queries.count) entries=\(store.count)"
        )

        // Bounded budget: hot-path clipboard search should remain under 2ms even in debug/CI
        XCTAssertLessThan(medianMicroseconds, 2_000)
    }
}
