import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest
@testable import Floodlight

/// The budget for the keystroke that used to stutter: producing the board's
/// publication while a large screenshot is selected.
///
/// Before #72 the inspector snapshot and the preview affordance were getters
/// the view evaluated, so each republication pulled the entry's whole payload
/// out of SQLite, decoded it, and wrote a temporary file. Both are values
/// Clipboard Search publishes now (#85), and this bounds what a publication
/// costs — plus asserts the two things it must no longer do: read the
/// payload, or write a file.
@MainActor
final class ClipboardSearchPerformanceTests: XCTestCase {
    func testClipboardPublicationWithAnImageSelectedStaysUnderBudget() throws {
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
        _ = try XCTUnwrap(store.recordImage(
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

        let tree = try TemporaryTree(label: "ClipboardSearchPerformance")
        let previewDirectory = tree.root.appendingPathComponent("previews", isDirectory: true)
        let search = ClipboardSearch(store: store, previewDirectory: previewDirectory)

        let opening = search.publication(query: "", selectedFilter: .all, selection: nil)
        let imageRow = try XCTUnwrap(opening.visibleRows.first { $0.title == "note screenshot" })
        let selection = SearchResultSelection(id: imageRow.id, origin: .user)

        // Two queries the image entry matches from a different rank, so every
        // flip publishes a different row set and genuinely recomputes the
        // selection's facts rather than reusing the memoized ones.
        let queries = ["note", "screenshot"]
        for query in queries {
            let publication = search.publication(
                query: query,
                selectedFilter: .all,
                selection: selection
            )
            XCTAssertEqual(publication.selection?.id, imageRow.id, "the image stays selected")
        }

        let sampleCount = _isDebugAssertConfiguration() ? 3 : 11
        let iterations = _isDebugAssertConfiguration() ? 5 : 25

        var samples: [Double] = []
        var inspectedImages = 0
        for _ in 0..<sampleCount {
            let start = processCPUTime()
            for _ in 0..<iterations {
                for query in queries {
                    _ = search.publication(query: query, selectedFilter: .all, selection: selection)
                    // Exactly what the board's body reads on every pass. The
                    // counter keeps the reads from being optimized away in
                    // release, and reading these is what used to cost a
                    // four-megabyte SQLite read and a file write.
                    if case .image = search.inspector, search.isSelectionPreviewable {
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

        guard case let .image(detail) = search.inspector else {
            return XCTFail("the image entry should still be the inspected selection")
        }
        XCTAssertTrue(detail.hasFullImage)
        XCTAssertEqual(detail.thumbnailPNG, ClipboardImageTestData.thumbnail)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: previewDirectory.path),
            "publishing must not materialize Quick Look's temporary file"
        )

        // Bounded budget: a publication is a search plus a projection over
        // 151 entries. Loose enough for a shared runner, tight enough that a
        // four-megabyte read reappearing on this path fails the gate.
        XCTAssertLessThan(medianMicroseconds, 5_000)
    }
}
