import AppKit
import AVFoundation
import Foundation
import ImageIO
import QuickLookThumbnailing

/// Pure, nonisolated decode policy so tests can drive each step without the cache.
enum FileThumbnailDecoder {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp", "avif", "ico",
        "icns", "svg",
    ]
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv", "ts", "mpg", "mpeg",
    ]

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Downsampled ImageIO decode: no XPC round trip, no daemon queueing —
    /// just the bytes already on disk. ImageIO can't read SVG, so that one
    /// extension falls back to `NSImage(contentsOf:)`, which resolves it
    /// through the SVG renderer instead.
    static func decodeImage(at url: URL, maxDimension: CGFloat) -> NSImage? {
        if url.pathExtension.lowercased() == "svg" {
            return NSImage(contentsOf: url)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension * 2),
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Header-only probe: reads the pixel dimensions ImageIO already parsed
    /// off the file's metadata, without decoding a single pixel. Lets a
    /// preview reserve the right box before the real thumbnail is ready.
    /// ImageIO can't read SVG headers, and decoding one just to measure it
    /// gives up the whole point of a cheap probe, so SVG returns nil here —
    /// callers fall back to the full decode for that extension.
    static func pixelSize(at url: URL) -> CGSize? {
        guard isImage(url), url.pathExtension.lowercased() != "svg" else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
              as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0
        else {
            return nil
        }

        // `decodeImage` always passes kCGImageSourceCreateThumbnailWithTransform,
        // which bakes EXIF orientation into the decoded pixels: orientations
        // 5-8 rotate 90 degrees, so width and height swap. Match that here,
        // or a rotated photo reserves a placeholder the wrong shape.
        let orientation = properties[kCGImagePropertyOrientation] as? Int
        if let orientation, (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }

    static func quickLookThumbnail(at url: URL, maxDimension: CGFloat) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxDimension, height: maxDimension),
            scale: 2,
            representationTypes: .thumbnail
        )
        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            return representation.nsImage
        } catch {
            return nil
        }
    }

    static func decodeVideoFrame(at url: URL, maxDimension: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension * 2, height: maxDimension * 2)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
        } catch {
            return nil
        }
    }

    /// Direct-first ordering. Images decode in-process via ImageIO — zero
    /// IPC, no daemon to schedule against — and only fall back to
    /// QuickLook's generator when ImageIO can't make sense of the bytes.
    /// Videos need a real frame decoder, which QuickLook already owns and
    /// caches system-wide, so they go through QuickLook first and fall back
    /// to a raw AVAssetImageGenerator read only if the daemon comes back
    /// empty.
    static func thumbnail(at url: URL, maxDimension: CGFloat) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        if isImage(url) {
            if let image = decodeImage(at: url, maxDimension: maxDimension) {
                return image
            }
            return await quickLookThumbnail(at: url, maxDimension: maxDimension)
        }

        if isVideo(url) {
            if let image = await quickLookThumbnail(at: url, maxDimension: maxDimension) {
                return image
            }
            return await decodeVideoFrame(at: url, maxDimension: maxDimension)
        }

        return nil
    }
}

@MainActor
final class FileThumbnailCache {
    static let shared = FileThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let pixelSizeCache = NSCache<NSString, NSValue>()

    init() {
        cache.countLimit = 128
        pixelSizeCache.countLimit = 128
    }

    nonisolated static func isVideo(_ url: URL) -> Bool {
        FileThumbnailDecoder.isVideo(url)
    }

    func cachedThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    /// A decoded thumbnail already knows its own size; short of that, probe
    /// the header rather than wait on a full async decode. Memoized so a
    /// view that re-lays-out against the same URL doesn't reopen the file
    /// on every pass — a failed probe included, stored as `.zero`, since a
    /// corrupt image would otherwise be reopened on every pass forever.
    func placeholderPixelSize(for url: URL) -> CGSize? {
        let path = url.path
        if let cached = cache.object(forKey: path as NSString) {
            return cached.size
        }
        if let probed = pixelSizeCache.object(forKey: path as NSString) {
            return probed.sizeValue == .zero ? nil : probed.sizeValue
        }
        let size = FileThumbnailDecoder.pixelSize(at: url)
        pixelSizeCache.setObject(NSValue(size: size ?? .zero), forKey: path as NSString)
        return size
    }

    func thumbnail(for url: URL, maxDimension: CGFloat = 320) async -> NSImage? {
        let path = url.path
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }

        let image = await Self.generate(for: url, maxDimension: maxDimension)
        if let image {
            cache.setObject(image, forKey: path as NSString)
        }
        return image
    }

    @concurrent
    private nonisolated static func generate(
        for url: URL,
        maxDimension: CGFloat
    ) async -> NSImage? {
        await FileThumbnailDecoder.thumbnail(at: url, maxDimension: maxDimension)
    }
}
