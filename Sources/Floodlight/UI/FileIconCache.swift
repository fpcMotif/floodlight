import AppKit
import Foundation

final class FileIconCache: @unchecked Sendable {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(
        label: "com.floodlight.file-icons",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {
        cache.countLimit = 256
    }

    func cachedIcon(for url: URL) -> NSImage? {
        cache.object(forKey: url.path as NSString)
    }

    func icon(for url: URL) async -> NSImage? {
        let path = url.path
        if let cached = cache.object(forKey: path as NSString) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            queue.async { [self, path] in
                let key = path as NSString
                if let cached = cache.object(forKey: key) {
                    continuation.resume(returning: cached)
                    return
                }

                let icon = NSWorkspace.shared.icon(forFiles: [path])
                if let icon {
                    cache.setObject(icon, forKey: key)
                }
                continuation.resume(returning: icon)
            }
        }
    }
}
