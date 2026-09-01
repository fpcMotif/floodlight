import AppKit
import Foundation
import QuickLookThumbnailing

@MainActor
final class FileThumbnailCache {
    static let shared = FileThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 128
    }

    func cachedThumbnail(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func thumbnail(for url: URL, maxDimension: CGFloat = 320) async -> NSImage? {
        let path = url.path
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }

        let image = await Self.generateThumbnail(for: url, maxDimension: maxDimension)
        if let image {
            cache.setObject(image, forKey: path as NSString)
        }
        return image
    }

    @concurrent
    private nonisolated static func generateThumbnail(
        for url: URL,
        maxDimension: CGFloat
    ) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let ext = url.pathExtension.lowercased()
        let imageExtensions: Set = [
            "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "tif", "bmp", "avif", "ico",
            "icns",
        ]
        let videoExtensions: Set = [
            "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv", "ts", "mpg", "mpeg",
        ]

        guard imageExtensions.contains(ext) || videoExtensions.contains(ext) else {
            return nil
        }

        let size = CGSize(width: maxDimension, height: maxDimension)
        let scale: CGFloat = 2.0
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )

        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            return representation.nsImage
        } catch {
            if imageExtensions.contains(ext), let image = NSImage(contentsOf: url) {
                return image
            }
            return nil
        }
    }
}
