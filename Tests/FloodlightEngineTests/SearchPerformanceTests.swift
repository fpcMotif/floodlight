import Darwin
import Foundation
import XCTest
@testable import FloodlightEngine

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
            _ = catalog.immediatePage(for: query).items
        }

        let iterations = 80
        var samples: [Double] = []
        var resultCount = 0

        for _ in 0..<9 {
            let sample = measure(iterations: iterations, queries: queries) { query in
                catalog.immediatePage(for: query).items
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

    func testNewSearchFeaturePerformanceBaselines() async throws {
        let catalog = SystemCatalog()
        try await catalog.start()

        let items = makeFilterFixture()
        let allFilters = SearchResultFilter.primary + SearchResultFilter.dynamic
        let sampleCount = _isDebugAssertConfiguration() ? 3 : 11
        let filterIterations = _isDebugAssertConfiguration() ? 100 : 2_000
        let settingsIterations = _isDebugAssertConfiguration() ? 25 : 500
        let filterSamples = (0..<sampleCount).map { _ in
            measureCPU(iterations: filterIterations) {
                let counts = SearchFilterCounts(items: items)
                return allFilters.reduce(into: 0) { count, filter in
                    count += counts[filter]
                }
            }
        }
        let filterMicroseconds = median(filterSamples.map(\.microsecondsPerIteration))
        let filterSwitchSamples = (0..<sampleCount).map { _ in
            measureCPU(iterations: filterIterations) {
                allFilters.reduce(into: 0) { count, filter in
                    count += items.lazy.filter(filter.includes).count
                }
            }
        }
        let filterSwitchMicroseconds = median(
            filterSwitchSamples.map(\.microsecondsPerIteration)
        )

        let settingsQueries = [
            "appearance",
            "bluetooth",
            "display",
            "keyboard",
            "network",
            "privacy",
            "settings",
            "sound",
            "storage",
            "wifi",
        ]
        for query in settingsQueries {
            _ = catalog.immediatePage(for: query, limit: 24)
        }
        let settingsSamples = (0..<sampleCount).map { _ in
            measureCPU(iterations: settingsIterations) {
                settingsQueries.reduce(into: 0) { count, query in
                    count += catalog.immediatePage(for: query, limit: 24).totalMatched
                }
            }
        }
        let settingsMicroseconds = median(
            settingsSamples.map {
                $0.microsecondsPerIteration / Double(settingsQueries.count)
            }
        )

        print(
            "FLOODLIGHT_BENCH filter_summary_us="
                + String(format: "%.3f", filterMicroseconds)
                + " filter_switch_cycle_us="
                + String(format: "%.3f", filterSwitchMicroseconds)
                + " settings_search_us="
                + String(format: "%.3f", settingsMicroseconds)
        )
        XCTAssertLessThan(filterMicroseconds, 1_000)
        XCTAssertLessThan(filterSwitchMicroseconds, 1_000)
        XCTAssertLessThan(settingsMicroseconds, 1_000)
    }

    func testExpandedFFFIndexScanBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["FLOODLIGHT_RUN_INDEX_BENCH"] == "1" else {
            throw XCTSkip("Set FLOODLIGHT_RUN_INDEX_BENCH=1 to run the filesystem benchmark.")
        }

        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("FloodlightScanBench-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        for directoryIndex in 0..<25 {
            let directory = root
                .appendingPathComponent("Directory-\(directoryIndex)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            for fileIndex in 0..<100 {
                let fileExtension = fileIndex.isMultiple(of: 2) ? "pdf" : "txt"
                fileManager.createFile(
                    atPath: directory
                        .appendingPathComponent("fixture-\(fileIndex).\(fileExtension)")
                        .path,
                    contents: Data()
                )
            }
        }

        let index = FFFIndex(
            rootURL: root,
            storageURL: storage,
            enableContentIndexing: false,
            includeBinaryFiles: true,
            watch: false
        )
        try await index.start()
        _ = try await waitForScan(index)

        var samples: [Double] = []
        var indexedFiles: UInt64 = 0
        for _ in 0..<7 {
            let start = ContinuousClock.now
            try await index.rescan()
            indexedFiles = try await waitForScan(index)
            samples.append(milliseconds(start.duration(to: .now)))
        }

        let scanMilliseconds = median(samples)
        print(
            "FLOODLIGHT_BENCH expanded_fff_scan_ms="
                + String(format: "%.3f", scanMilliseconds)
                + " indexed_files=\(indexedFiles)"
        )
        XCTAssertEqual(indexedFiles, 2_500)
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

    private func measureCPU(
        iterations: Int,
        operation: () -> Int
    ) -> (microsecondsPerIteration: Double, checksum: Int) {
        var checksum = 0
        let start = processCPUTime()
        for _ in 0..<iterations {
            checksum &+= operation()
        }
        let elapsed = processCPUTime() - start
        return (
            elapsed * 1_000_000 / Double(iterations),
            checksum
        )
    }

    private func makeFilterFixture() -> [SearchItem] {
        let extensions = ["pdf", "png", "txt", "swift", "jpg", "docx"]
        return (0..<80).map { index in
            let kind: SearchItemKind = switch index % 8 {
            case 0:
                .application
            case 1:
                .folder
            case 2:
                .systemSetting
            default:
                .file
            }
            let ext = extensions[index % extensions.count]
            let url = URL(fileURLWithPath: "/tmp/fixture-\(index).\(ext)")
            return SearchItem(
                id: "fixture:\(index)",
                title: "Fixture \(index)",
                subtitle: url.path,
                kind: kind,
                action: .open(url),
                score: 100_000 - index,
                fileURL: url
            )
        }
    }

    private func waitForScan(_ index: FFFIndex) async throws -> UInt64 {
        for _ in 0..<10_000 {
            let progress = try await index.progress()
            if !progress.isScanning {
                return progress.scannedFiles
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("FFF scan timed out")
        return 0
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
