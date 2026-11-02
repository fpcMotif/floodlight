import AppKit
import Foundation

/// The caches behind result rows and the Clipboard Inspector, and the one
/// thing the panel asks of them when it hides: give back what the next
/// summon will not draw.
///
/// The panel stays built across hides so a summon only orders it front;
/// these caches are what that leaves to grow. Each cache decides its own
/// warm set at its `purgeForHide()`, and this type is the single call site,
/// so #88's shared Row Asset loader can absorb it whole rather than hunt
/// down five calls. Injected so a test can hide a panel over fresh caches
/// instead of the process-wide ones other suites read concurrently.
@MainActor
struct RowAssetCaches {
    let appIcons: AppIconCache
    let fileIcons: FileIconCache
    let clipboardImages: ClipboardImageCache
    let textPreviews: FileTextPreviewCache
    let thumbnails: FileThumbnailCache

    static var shared: RowAssetCaches {
        RowAssetCaches(
            appIcons: .shared,
            fileIcons: .shared,
            clipboardImages: .shared,
            textPreviews: .shared,
            thumbnails: .shared
        )
    }

    func purgeForHide() {
        appIcons.purgeForHide()
        fileIcons.purgeForHide()
        clipboardImages.purgeForHide()
        textPreviews.purgeForHide()
        thumbnails.purgeForHide()
    }
}

/// The last few keys a cache handed out, newest last.
///
/// `NSCache` can neither list what it holds nor say what it evicted, so a
/// cache that keeps a warm set across a purge has to remember the keys
/// itself. A linear scan is fine: the capacity is a handful, not the
/// cache's whole count.
struct RecentKeys {
    let capacity: Int
    private var keys: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func touch(_ key: String) {
        if let index = keys.firstIndex(of: key) {
            keys.remove(at: index)
        }
        keys.append(key)
        if keys.count > capacity {
            keys.removeFirst(keys.count - capacity)
        }
    }

    /// Empties `cache` but for the remembered keys it still holds. An entry
    /// `NSCache` already evicted under memory pressure stays evicted.
    func keepOnly(in cache: NSCache<NSString, some AnyObject>) {
        let warm = keys.compactMap { key in
            cache.object(forKey: key as NSString).map { (key, $0) }
        }
        cache.removeAllObjects()
        for (key, object) in warm {
            cache.setObject(object, forKey: key as NSString)
        }
    }
}
