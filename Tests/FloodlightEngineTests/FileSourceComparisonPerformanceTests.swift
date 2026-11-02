import Darwin
import FloodlightTestSupport
import Foundation
import XCTest
@testable import FloodlightEngine

/// ADR 0010's numbers: the Zig index and FFF over the same real home folder,
/// each through the `FileSource` seam the app uses. Zig runs first and is
/// released before FFF starts, so neither engine's memory is billed to the
/// other.
///
/// The Zig source wraps a content source that does nothing, so its row is
/// the cost of name search alone. FFF runs in its production configuration,
/// content index included, because that is what the Zig index replaces for
/// name search and what the app paid before this change.
final class FileSourceComparisonPerformanceTests: XCTestCase {
    private static let queries = [
        "readme", "notes", "invoice pdf", "screenshot", "package swift", "config", "img", "dow",
    ]
    private static let rounds = 15

    func testZigAndFFFOnTheHomeFolder() async throws {
        // A debug build scans and matches several times slower, so its numbers
        // describe nothing a user feels; `make test-performance` runs release.
        try XCTSkipIf(_isDebugAssertConfiguration(), "release-only: run make test-performance")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let storage = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloodlightEngineComparison-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: storage) }

        let zig = try await sample("zig") {
            ZigFileSource(
                content: ScriptedFileSource(),
                rootURL: home,
                storageURL: storage.appendingPathComponent("Zig")
            )
        }
        let fff = try await sample("fff") {
            FFFFileSource(
                index: FFFIndex(
                    rootURL: home,
                    storageURL: storage.appendingPathComponent("FFF"),
                    watch: false,
                    enableHomeDirectoryScanning: true,
                    contentCacheBudget: .launcher
                ),
                rootURL: home
            )
        }

        // Shared runners vary several-fold, so this only catches the index
        // losing its order-of-magnitude lead, not a 10% drift.
        XCTAssertLessThan(zig.p50Milliseconds, max(fff.p50Milliseconds, 5) * 2)
        XCTAssertLessThan(zig.footprintBytes, max(fff.footprintBytes, 1))
    }

    private struct Measurement {
        let p50Milliseconds: Double
        let footprintBytes: Int64
    }

    private func sample(
        _ engine: String,
        makeSource: () -> any FileSource
    ) async throws -> Measurement {
        let before = MemorySample.current()
        let clock = ContinuousClock()
        var source: (any FileSource)? = makeSource()
        let startDuration = try await clock.measure { try await source?.start() }

        var samples: [Double] = []
        var results = 0
        for _ in 0..<Self.rounds {
            for query in Self.queries {
                var page: [SearchItem] = []
                let elapsed = try await clock.measure {
                    page = try await source?.indexedItems(for: query, limit: 12) ?? []
                }
                samples.append(elapsed.milliseconds)
                results += page.count
            }
        }
        let after = MemorySample.current()
        source = nil

        let measurement = Measurement(
            p50Milliseconds: median(samples),
            footprintBytes: after.footprint - before.footprint
        )
        print(
            "FLOODLIGHT_BENCH home_\(engine)"
                + " start_ms=" + String(format: "%.0f", startDuration.milliseconds)
                + " query_p50_ms=" + String(format: "%.3f", measurement.p50Milliseconds)
                + " footprint_delta_mb=" + megabytes(measurement.footprintBytes)
                + " resident_delta_mb=" + megabytes(after.resident - before.resident)
                + " results=\(results)"
        )
        return measurement
    }

    private func megabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_048_576)
    }
}

/// `phys_footprint` is what Activity Monitor calls Memory: dirty and
/// compressed pages only. Clean file-backed pages, which is all a mapped Zig
/// index is, count toward `resident` but not toward it.
private struct MemorySample {
    let footprint: Int64
    let resident: Int64

    static func current() -> MemorySample {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else { return MemorySample(footprint: 0, resident: 0) }
        return MemorySample(
            footprint: Int64(info.ri_phys_footprint),
            resident: Int64(info.ri_resident_size)
        )
    }
}

private extension Duration {
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
