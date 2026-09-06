import Darwin
import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest
@testable import Floodlight

/// The budget for the keystroke that used to stutter: republishing the board's
/// rows while a large screenshot is selected.
///
/// Before #72 the inspector snapshot and the preview affordance were getters
/// the view evaluated, so each republication pulled the entry's whole payload
/// out of SQLite, decoded it, and wrote a temporary file. Both are published
/// values now, and this bounds what a republication costs — plus asserts the
/// two things it must no longer do: read the payload, or write a file.
@MainActor
final class ClipboardBoardPerformanceTests: XCTestCase {
    func testClipboardRepublicationWithAnImageSelectedStaysUnderBudget() throws {
        // Big enough that a payload read would swamp everything else here:
        // reading and decoding four megabytes is milliseconds, and the budget
        // below is in microseconds.
        let payload = Data(repeating: 0xAB, count: 4 * 1_024 * 1_024)
        let store = ClipboardHistoryStore.inMemory()
        // The image lands mid-history so the two queries below rank it
        // differently, and the whole set stays inside the store's 200-row
        // search limit so neither query can drop it.
        for index in 0..<100 {
            _ = store.record(text: "meeting note #\(index)", sourceAppBundleID: "com.apple.Notes")
        }
        let imageEntry = try XCTUnwrap(store.recordImage(
            pngData: payload,
            tiffData: nil,
            thumbnailPNGData: ClipboardImageTestData.thumbnail,
            width: 2_880,
            height: 1_800,
            displayName: "note screenshot"
        ))
        for index in 100..<150 {
            _ = store.record(text: "meeting note #\(index)", sourceAppBundleID: "com.apple.Notes")
        }

        let coordinator = try makeCoordinator(clipboardStore: store)
        coordinator.query = "clip"
        coordinator.handleTab()

        let imageRowID = "clipboard:\(imageEntry.id)"
        let imageRow = try XCTUnwrap(coordinator.results.first { $0.id == imageRowID })
        coordinator.select(imageRow)

        // Two queries the image entry matches from a different rank, so every
        // flip republishes a different row set and genuinely recomputes the
        // selection's snapshot rather than reusing the memoized one.
        let queries = ["note", "screenshot"]
        for query in queries {
            coordinator.query = query
            XCTAssertEqual(coordinator.selectedID, imageRowID, "the image stays selected")
        }

        let sampleCount = _isDebugAssertConfiguration() ? 3 : 11
        let iterations = _isDebugAssertConfiguration() ? 5 : 25

        var samples: [Double] = []
        var inspectedImages = 0
        for _ in 0..<sampleCount {
            let start = processCPUTime()
            for _ in 0..<iterations {
                for query in queries {
                    coordinator.query = query
                    // Exactly what the board's body reads on every pass. The
                    // counter keeps the reads from being optimized away in
                    // release, and reading these is what used to cost a
                    // four-megabyte SQLite read and a file write.
                    if case .image = coordinator.clipboardInspector,
                       coordinator.isSelectionPreviewable
                    {
                        inspectedImages += 1
                    }
                }
            }
            let elapsedSeconds = processCPUTime() - start
            let microsecondsPerPublication = (elapsedSeconds * 1_000_000.0) /
                Double(iterations * queries.count)
            samples.append(microsecondsPerPublication)
        }
        XCTAssertEqual(
            inspectedImages,
            sampleCount * iterations * queries.count,
            "every publication should have left the image entry inspected and previewable"
        )

        let medianMicroseconds = median(samples)

        print(
            "FLOODLIGHT_BENCH clipboard_republish_us="
                + String(format: "%.3f", medianMicroseconds)
                + " entries=\(store.count) payload_bytes=\(payload.count)"
        )

        guard case let .image(detail) = coordinator.clipboardInspector else {
            return XCTFail("the image entry should still be the inspected selection")
        }
        XCTAssertTrue(detail.hasFullImage)
        XCTAssertEqual(detail.thumbnailPNG, ClipboardImageTestData.thumbnail)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: previewURL(entryID: imageEntry.id).path),
            "republishing must not materialize Quick Look's temporary file"
        )

        // Bounded budget: a republication is a search plus a projection over
        // 151 entries. Loose enough for a shared runner, tight enough that a
        // four-megabyte read reappearing on this path fails the gate.
        XCTAssertLessThan(medianMicroseconds, 5_000)
    }

    private func makeCoordinator(clipboardStore: ClipboardHistoryStore) throws
        -> SearchCoordinator
    {
        let tree = try TemporaryTree(label: "ClipboardBoardPerformance")
        return try SearchCoordinator(
            sourceSearch: SourceSearchEngine(
                files: ScriptedFileSource(),
                applications: ScriptedCatalog(),
                settings: ScriptedCatalog()
            ),
            recentStore: RecentStore(defaults: IsolatedDefaults().defaults),
            blocklistStore: BlocklistStore(defaults: IsolatedDefaults().defaults),
            clipboardStore: clipboardStore,
            rootURL: tree.root,
            assistantRunner: ScriptedAssistantRunner(),
            onDismiss: {}
        )
    }

    private func previewURL(entryID: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FloodlightClipboardPreviews", isDirectory: true)
            .appendingPathComponent("\(entryID).png")
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count.isMultiple(of: 2) {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2.0
        }
        return sorted[count / 2]
    }

    private func processCPUTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        return user + system
    }
}
