import AppKit
import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

/// What a hide gives back. The panel stays built across hides so a summon
/// only orders it front; these are the per-session caches and model state
/// that would otherwise sit in a hidden panel. Every cache here is a fresh
/// instance, never `.shared`, because other suites read the shared ones
/// concurrently and a purge from here would race them.
@MainActor
@Suite(.serialized)
struct RowAssetCachesTests {
    private let tree: TemporaryTree

    init() throws {
        tree = try TemporaryTree(label: "RowAssetCaches")
    }

    private func makeCaches() -> RowAssetCaches {
        RowAssetCaches(
            appIcons: AppIconCache(),
            fileIcons: FileIconCache(),
            clipboardImages: ClipboardImageCache(),
            textPreviews: FileTextPreviewCache(),
            thumbnails: FileThumbnailCache()
        )
    }

    private func makeTextFile() throws -> URL {
        let url = tree.root.appendingPathComponent("notes.txt")
        try "Shopping list".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makePNG() throws -> URL {
        let url = tree.root.appendingPathComponent("shot.png")
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 24,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }

    // MARK: - Each cache's warm set

    /// App icons keep a warm set, and a hit is what keeps one warm. Finder
    /// and Safari stand in for two source apps because every Mac has both.
    @Test func appIconsKeepOnlyTheMostRecentlyDrawn() throws {
        let cache = AppIconCache(warmCount: 1)
        _ = try #require(cache.icon(for: "com.apple.Safari"))
        let finder = try #require(cache.icon(for: "com.apple.finder"))

        cache.purgeForHide()

        #expect(cache.icon(for: "com.apple.finder") === finder)
    }

    @Test func fileIconsAreDroppedEntirely() async throws {
        let cache = FileIconCache()
        let url = try makeTextFile()
        _ = try #require(await cache.icon(for: url))
        #expect(cache.cachedIcon(for: url) != nil)

        cache.purgeForHide()

        #expect(cache.cachedIcon(for: url) == nil)
    }

    @Test func fileThumbnailsAreDroppedEntirely() async throws {
        let cache = FileThumbnailCache()
        let url = try makePNG()
        _ = try #require(await cache.thumbnail(for: url))
        #expect(cache.cachedThumbnail(for: url) != nil)

        cache.purgeForHide()

        #expect(cache.cachedThumbnail(for: url) == nil)
    }

    @Test func textPreviewsAreDroppedEntirely() async throws {
        let cache = FileTextPreviewCache()
        let url = try makeTextFile()
        _ = try #require(await cache.preview(for: url))
        #expect(cache.immediatePreview(for: url) != nil)

        cache.purgeForHide()

        #expect(cache.immediatePreview(for: url) == nil)
    }

    // MARK: - The panel's hide

    @Test func hidingThePanelPurgesTheCachesItWasGiven() async throws {
        let caches = makeCaches()
        let textURL = try makeTextFile()
        let imageURL = try makePNG()
        _ = try #require(await caches.textPreviews.preview(for: textURL))
        _ = try #require(await caches.thumbnails.thumbnail(for: imageURL))
        let controller = FloodlightPanelController(
            model: makeSearchCoordinatorWithInertPresentation(),
            rowAssets: caches
        )

        controller.hide()

        #expect(caches.textPreviews.immediatePreview(for: textURL) == nil)
        #expect(caches.thumbnails.cachedThumbnail(for: imageURL) == nil)
    }

    /// A hidden panel holds no rows. The visible rows go with the query; the
    /// clipboard rows Clipboard Search memoizes go too, which the clock makes
    /// observable: memoized rows still say what the clock said when they
    /// were built, rebuilt rows say what it says now.
    @Test func hidingThePanelReleasesTheSessionsRows() throws {
        let store = ClipboardHistoryStore.inMemory()
        let minuteStart = Date(timeIntervalSinceReferenceDate: 780_000_000)
        _ = try #require(store.record(text: "Snippet", date: minuteStart.addingTimeInterval(-30)))
        _ = try #require(store.record(text: "Tick", date: minuteStart))
        var now = minuteStart
        let search = ClipboardSearch(
            store: store,
            previewDirectory: tree.root,
            now: { now }
        )
        let model = SearchCoordinator(clipboardSearch: search, onDismiss: {})
        let controller = FloodlightPanelController(model: model, rowAssets: makeCaches())
        model.showClipboardHistory()
        #expect(model.results.count == 2)

        now = minuteStart.addingTimeInterval(59)
        controller.hide()

        #expect(model.results.isEmpty)
        let reopened = search.publication(query: "", selectedFilter: .all, selection: nil)
        let ages = reopened.visibleRows.map(\.subtitle)
        #expect(ages == ["Clipboard · just now", "Clipboard · 1m"])
    }
}
