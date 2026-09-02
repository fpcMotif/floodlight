import AppKit
import FloodlightTestSupport
import Foundation
import Testing
@testable import Floodlight

@MainActor
struct FileThumbnailCacheTests {
    private let tree: TemporaryTree

    init() throws {
        tree = try TemporaryTree(label: "FileThumbnailCache")
    }

    // MARK: - Fixtures

    private func makePNG(at url: URL) throws {
        try makeBitmapImage(at: url, type: .png)
    }

    private func makeJPEG(at url: URL) throws {
        try makeBitmapImage(at: url, type: .jpeg)
    }

    private func makeBitmapImage(at url: URL, type: NSBitmapImageRep.FileType) throws {
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
        let blue = NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.86, alpha: 1)
        let red = NSColor(calibratedRed: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        for y in 0..<16 {
            for x in 0..<24 {
                representation.setColor(x < 12 ? blue : red, atX: x, y: y)
            }
        }

        let data = try #require(representation.representation(using: type, properties: [:]))
        try data.write(to: url)
    }

    private func makeSVG(at url: URL) throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="16">\
        <rect width="24" height="16" fill="#3498db"/></svg>
        """
        try Data(svg.utf8).write(to: url)
    }

    // MARK: - Direct decode

    @Test func pngDecodesDirectlyWithoutQuickLook() throws {
        let url = tree.root.appendingPathComponent("swatch.png")
        try makePNG(at: url)

        let image = try #require(FileThumbnailDecoder.decodeImage(at: url, maxDimension: 64))
        #expect(image.size.width > 0)
    }

    @Test func jpegDecodesDirectly() throws {
        let url = tree.root.appendingPathComponent("swatch.jpg")
        try makeJPEG(at: url)

        let image = try #require(FileThumbnailDecoder.decodeImage(at: url, maxDimension: 64))
        #expect(image.size.width > 0)
    }

    @Test func svgDecodesThroughNSImage() throws {
        let url = tree.root.appendingPathComponent("icon.svg")
        try makeSVG(at: url)

        let image = FileThumbnailDecoder.decodeImage(at: url, maxDimension: 64)
        #expect(image != nil)
    }

    // MARK: - Fallthrough and failure paths

    @Test func missingFileYieldsNil() async {
        let url = tree.root.appendingPathComponent("nope.png")
        let image = await FileThumbnailDecoder.thumbnail(at: url, maxDimension: 64)
        #expect(image == nil)
    }

    @Test func unsupportedExtensionYieldsNil() async throws {
        let url = tree.root.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: url)

        let image = await FileThumbnailDecoder.thumbnail(at: url, maxDimension: 64)
        #expect(image == nil)
    }

    @Test func corruptImageFallsThroughToNil() async throws {
        let url = tree.root.appendingPathComponent("broken.png")
        let garbage = Data([
            0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04,
            0xFF, 0xFE, 0xFD, 0x10, 0x20, 0x30, 0x40, 0x50,
        ])
        try garbage.write(to: url)

        #expect(FileThumbnailDecoder.decodeImage(at: url, maxDimension: 64) == nil)
        _ = await FileThumbnailDecoder.thumbnail(at: url, maxDimension: 64)
    }

    @Test func garbageVideoFallsThroughToNil() async throws {
        let url = tree.root.appendingPathComponent("clip.mp4")
        let garbage = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF,
        ])
        try garbage.write(to: url)

        let frame = await FileThumbnailDecoder.decodeVideoFrame(at: url, maxDimension: 64)
        #expect(frame == nil)
        _ = await FileThumbnailDecoder.thumbnail(at: url, maxDimension: 64)
    }

    // MARK: - Cache

    @Test func cacheReturnsTheSameObjectOnSecondLookup() async throws {
        let url = tree.root.appendingPathComponent("cached.png")
        try makePNG(at: url)

        let cache = FileThumbnailCache()
        let firstLookup = await cache.thumbnail(for: url)
        let first = try #require(firstLookup)
        let cached = try #require(cache.cachedThumbnail(for: url))
        #expect(first === cached)

        let secondLookup = await cache.thumbnail(for: url)
        let second = try #require(secondLookup)
        #expect(first === second)
    }

    // MARK: - Extension classification

    @Test func extensionClassificationIsCaseInsensitive() {
        #expect(FileThumbnailCache.isImage(URL(fileURLWithPath: "/tmp/A.PNG")))
        #expect(FileThumbnailCache.isVideo(URL(fileURLWithPath: "/tmp/b.MOV")))
        #expect(!FileThumbnailCache.isImage(URL(fileURLWithPath: "/tmp/c.txt")))
    }
}
