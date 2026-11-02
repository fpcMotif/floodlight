import AppKit
import Foundation

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    /// Kept warm across a hide. The inspector shows one source-app icon at a
    /// time, the board reopens on the newest entries, and those come from
    /// the apps used last; a 16-point icon costs little to keep, while a
    /// miss costs a Launch Services lookup on the main actor.
    static let warmCount = 8

    private let cache = NSCache<NSString, NSImage>()
    private var recent: RecentKeys

    init(warmCount: Int = AppIconCache.warmCount) {
        cache.countLimit = 64
        recent = RecentKeys(capacity: warmCount)
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let key = bundleID as NSString
        if let cached = cache.object(forKey: key) {
            recent.touch(bundleID)
            return cached
        }

        // The resolver behind this remembers the identifiers Launch Services
        // cannot place, so an entry whose icon will never resolve — a
        // screenshot's — costs one lookup per launch, not one per render.
        guard let appURL = ClipboardSourceApp.applicationURL(for: bundleID) else {
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: appURL.path)
        image.size = NSSize(width: 16, height: 16)
        cache.setObject(image, forKey: key)
        recent.touch(bundleID)
        return image
    }

    /// Keeps the most recently drawn icons and drops the rest.
    func purgeForHide() {
        recent.keepOnly(in: cache)
    }
}
