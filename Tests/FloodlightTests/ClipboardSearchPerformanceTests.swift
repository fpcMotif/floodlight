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

    /// The budget for a keystroke over a full board: a thousand entries of
    /// every kind the board shows, searched and projected to rows.
    ///
    /// Before #73 every text row was classified from scratch on every
    /// keystroke — a 20 KB JSON snippet parsed, a copied path stat'ed —
    /// none of which depends on the query. The classification is stored
    /// with the entry now and projection reads it, so this bounds what is
    /// left: the store search and the row build. A future row decoration
    /// that parses text again lands here.
    func testProjectingAThousandEntryBoardStaysUnderBudget() throws {
        let tree = try TemporaryTree(label: "ClipboardProjectionPerformance")
        let existingFile = tree.root.appendingPathComponent("design.png")
        try Data("png".utf8).write(to: existingFile)
        let store = ClipboardHistoryStore.inMemory()
        for index in 0..<1_000 {
            record(sample: index, into: store, root: tree.root, existingFile: existingFile)
        }
        XCTAssertEqual(store.count, 1_000)
        let search = ClipboardSearch(
            store: store,
            previewDirectory: tree.root.appendingPathComponent("previews", isDirectory: true)
        )

        // Two queries the whole board answers — the empty one, and a single
        // letter every sample contains — so each flip misses the one-deep
        // memo and does what a keystroke does: search, then build every row.
        let queries = ["", "e"]
        for query in queries {
            let publication = search.publication(query: query, selectedFilter: .all, selection: nil)
            XCTAssertEqual(publication.visibleRows.count, 1_000, "query \(query)")
        }

        let sampleCount = _isDebugAssertConfiguration() ? 3 : 11
        let iterations = _isDebugAssertConfiguration() ? 3 : 10

        var samples: [Double] = []
        var rowsBuilt = 0
        for _ in 0..<sampleCount {
            let start = processCPUTime()
            for _ in 0..<iterations {
                for query in queries {
                    rowsBuilt += search.publication(
                        query: query,
                        selectedFilter: .all,
                        selection: nil
                    ).allRows.count
                }
            }
            let elapsedSeconds = processCPUTime() - start
            samples.append((elapsedSeconds * 1_000_000.0) / Double(iterations * queries.count))
        }
        XCTAssertEqual(rowsBuilt, sampleCount * iterations * queries.count * 1_000)
        let keystrokeMicroseconds = median(samples)

        // The chip switch the memo exists for: same query, same history.
        samples.removeAll()
        for _ in 0..<sampleCount {
            let start = processCPUTime()
            for _ in 0..<iterations {
                for filter in [SearchResultFilter.text, .all] {
                    _ = search.publication(query: "", selectedFilter: filter, selection: nil)
                }
            }
            let elapsedSeconds = processCPUTime() - start
            samples.append((elapsedSeconds * 1_000_000.0) / Double(iterations * 2))
        }
        let chipSwitchMicroseconds = median(samples)

        print(
            "FLOODLIGHT_BENCH clipboard_board_keystroke_us="
                + String(format: "%.3f", keystrokeMicroseconds)
                + " clipboard_chip_switch_us="
                + String(format: "%.3f", chipSwitchMicroseconds)
                + " entries=\(store.count)"
        )

        // Bounded budgets, in microseconds per publication, measured at
        // about 1,800 and 60 in release. A keystroke is the store search
        // plus a thousand rows; a hundred 20 KB JSON entries parsed again
        // would add over ten milliseconds and fail it, as would walking
        // their graphemes for the title. A chip switch is the memo hit plus
        // the scoping; losing the memo puts it at the keystroke's cost.
        XCTAssertLessThan(keystrokeMicroseconds, 8_000)
        XCTAssertLessThan(chipSwitchMicroseconds, 1_000)
    }

    /// One of each kind the board shows, every text containing the letter
    /// the keystroke query above searches for. The JSON is the expensive
    /// case: 20 KB that the serializer used to parse per row per keystroke.
    private func record(
        sample index: Int,
        into store: ClipboardHistoryStore,
        root: URL,
        existingFile: URL
    ) {
        switch index % 10 {
        case 0:
            store.record(text: "{\"index\": \(index), \"items\": [\(Self.jsonItems)]}")
        case 1:
            store.record(text: "\(root.path)/missing/screen-\(index).png")
        case 2:
            store.record(text: existingFile.path)
        case 3:
            store.record(text: "https://example.org/issues/\(index)")
        case 4:
            store.record(text: "#3498DE")
        case 5:
            store.record(text: "func performSearch\(index)() async throws -> [SearchItem] {}")
        case 6:
            store.recordFile(path: "\(root.path)/report-\(index).pdf")
        case 7:
            store.recordImage(
                pngData: ClipboardImageTestData.png,
                thumbnailPNGData: ClipboardImageTestData.thumbnail,
                width: 640,
                height: 480,
                displayName: "Screen \(index)"
            )
        default:
            store.record(
                text: "Meeting note \(index): discussed the seam and the budget",
                sourceAppBundleID: "com.apple.Notes"
            )
        }
    }

    private static let jsonItems = (0..<600)
        .map { "{\"id\": \($0), \"name\": \"item \($0)\"}" }
        .joined(separator: ", ")
}
