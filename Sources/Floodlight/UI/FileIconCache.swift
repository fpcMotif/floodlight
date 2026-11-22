import AppKit
import Foundation

@MainActor
final class FileIconCache {
    static let shared = FileIconCache()

    private let cache = NSCache<NSString, NSImage>()

    init() {
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

    /// Drops everything. A hide resets the query, and an empty query shows
    /// no file rows, so nothing here is on screen at the next summon; the
    /// next search refills it off the main actor, where a miss costs the
    /// row a placeholder for a frame and never costs a keystroke.
    func purgeForHide() {
        cache.removeAllObjects()
    }

    /// `@concurrent` is deliberate. Under approachable concurrency a plain
    /// nonisolated async method inherits the caller's actor; icon lookup can
    /// hit disk and must leave the panel free to type.
    @concurrent
    private nonisolated static func loadWorkspaceIcon(for path: String) async -> NSImage? {
        NSWorkspace.shared.icon(forFiles: [path])
    }
}
