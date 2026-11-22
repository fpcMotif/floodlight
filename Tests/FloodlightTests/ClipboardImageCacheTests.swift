import AppKit
import Foundation
import Testing
@testable import Floodlight

/// The board's decoded-image cache. Two caches with different lifetimes, and
/// the difference between them is load-bearing: `FloodlightPanel.hide()` drops
/// the full images and keeps the warm thumbnails, so reopening the board redraws
/// the rows it opens on without a fresh round of decodes.
@MainActor
struct ClipboardImageCacheTests {
    /// A real bitmap. `ClipboardImageTestData.png` is 64 bytes of 0xAB, which
    /// the store is happy to treat as opaque but `NSImage(data:)` cannot
    /// decode — every assertion here would pass vacuously on nil.
    private static func png(width: Int = 8, height: Int = 8) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func thumbnailDecodesOnceAndReturnsTheSameInstance() throws {
        let cache = ClipboardImageCache()
        let data = Self.png()

        let first = try #require(cache.thumbnail(entryID: "a", data: data))
        let second = try #require(cache.thumbnail(entryID: "a", data: data))

        // Identity, not equality: a second decode would produce an equal image
        // and hide the fact that the cache did nothing.
        #expect(first === second)
    }

    @Test func thumbnailKeysOnTheEntryRatherThanTheBytes() throws {
        let cache = ClipboardImageCache()

        let first = try #require(cache.thumbnail(entryID: "a", data: Self.png()))
        let second = try #require(cache.thumbnail(entryID: "b", data: Self.png()))

        #expect(first !== second)
    }

    @Test func undecodableBytesAreNotCachedAsAFailure() {
        let cache = ClipboardImageCache()

        #expect(cache.thumbnail(entryID: "bad", data: Data(repeating: 0xAB, count: 64)) == nil)
        // A later good payload for the same entry still decodes — a nil is not
        // remembered, so a truncated read cannot poison the entry for the session.
        #expect(cache.thumbnail(entryID: "bad", data: Self.png()) != nil)
    }

    @Test func aFullImageIsNotCachedUntilItIsLoaded() async throws {
        let cache = ClipboardImageCache()
        let data = Self.png()

        #expect(cache.cachedFullImage(entryID: "a") == nil)
        let loaded = try #require(await cache.fullImage(entryID: "a") { data })
        #expect(cache.cachedFullImage(entryID: "a") === loaded)
    }

    @Test func aFullImageIsReadOnlyOnAMiss() async {
        let cache = ClipboardImageCache()
        let data = Self.png()
        let reads = OSAllocatedUnfairLockCounter()

        _ = await cache.fullImage(entryID: "a") { reads.increment()
            return data
        }
        _ = await cache.fullImage(entryID: "a") { reads.increment()
            return data
        }

        // The payload closure is the SQLite read of a blob that can be 15 MB.
        #expect(reads.value == 1)
    }

    @Test func anEmptyOrMissingPayloadYieldsNothing() async {
        let cache = ClipboardImageCache()

        #expect(await cache.fullImage(entryID: "empty") { Data() } == nil)
        #expect(await cache.fullImage(entryID: "missing") { nil } == nil)
    }

    @Test func aHideDropsFullImagesAndKeepsTheWarmThumbnails() async throws {
        let cache = ClipboardImageCache(warmThumbnailCount: 1)
        let data = Self.png()

        let cold = try #require(cache.thumbnail(entryID: "cold", data: data))
        let warm = try #require(cache.thumbnail(entryID: "warm", data: data))
        _ = try #require(await cache.fullImage(entryID: "warm") { data })

        cache.purgeForHide()

        #expect(cache.cachedFullImage(entryID: "warm") == nil)
        // By identity. `!= nil` would also pass if the warm thumbnail had been
        // evicted and silently re-decoded, which is exactly the regression
        // this guards — `FloodlightPanel.hide()` calls this on every dismissal.
        #expect(cache.thumbnail(entryID: "warm", data: data) === warm)
        #expect(cache.thumbnail(entryID: "cold", data: data) !== cold)
    }

    /// A hit counts as use. Without it the warm set would be the thumbnails
    /// decoded last, not the ones the board drew last.
    @Test func aThumbnailDrawnFromTheCacheStaysWarm() throws {
        let cache = ClipboardImageCache(warmThumbnailCount: 1)
        let data = Self.png()

        let first = try #require(cache.thumbnail(entryID: "first", data: data))
        _ = try #require(cache.thumbnail(entryID: "second", data: data))
        _ = cache.thumbnail(entryID: "first", data: data)

        cache.purgeForHide()

        #expect(cache.thumbnail(entryID: "first", data: data) === first)
    }
}

/// A counter the escaping, `Sendable` payload closure can bump.
private final class OSAllocatedUnfairLockCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
