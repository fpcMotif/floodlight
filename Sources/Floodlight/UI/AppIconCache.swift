import AppKit
import Foundation

@MainActor
final class AppIconCache {
    static let shared = AppIconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 64
    }

    func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let key = bundleID as NSString
        if let cached = cache.object(forKey: key) {
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
        return image
    }
}
