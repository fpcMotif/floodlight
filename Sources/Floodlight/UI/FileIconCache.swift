import AppKit
import Foundation

@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()

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

        let icon = await Self.loadWorkspaceIcon(for: path)
        if let icon {
            cache.setObject(icon, forKey: path as NSString)
        }
        return icon
    }

    /// `@concurrent` is deliberate. Under approachable concurrency a plain
    /// nonisolated async method inherits the caller's actor; icon lookup can
    /// hit disk and must leave the panel free to type.
    @concurrent
    private nonisolated static func loadWorkspaceIcon(for path: String) async -> NSImage? {
        NSWorkspace.shared.icon(forFiles: [path])
    }
}
