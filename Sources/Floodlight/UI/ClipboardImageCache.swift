import AppKit
import Foundation

/// Decoded Clipboard History images, keyed by entry — the board's
/// counterpart to `FileIconCache` and `FileThumbnailCache`.
///
/// Two caches rather than one, because the two answer different questions.
/// A thumbnail is what a list row and the inspector can draw the instant a
/// selection lands, and dozens are on screen at once. A full-size image is
/// what the inspector fills in afterwards, only for the entry the user
/// actually stopped on, and one of them can be 15 MB.
@MainActor
final class ClipboardImageCache {
    static let shared = ClipboardImageCache()

    private let thumbnails = NSCache<NSString, NSImage>()
    private let fullImages = NSCache<NSString, NSImage>()

    init() {
        thumbnails.countLimit = 256
        fullImages.countLimit = 8
    }

    /// The decoded thumbnail for an entry. `NSImage(data:)` in a view body
    /// decodes on every evaluation; entries are immutable, so one decode per
    /// entry is all the list and the inspector between them ever need.
    func thumbnail(entryID: String, data: Data) -> NSImage? {
        let key = entryID as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }

    /// A full-size image already decoded during this session — what lets
    /// arrowing back onto an entry show the real picture immediately rather
    /// than flashing its thumbnail again.
    func cachedFullImage(entryID: String) -> NSImage? {
        fullImages.object(forKey: entryID as NSString)
    }

    /// The entry's full-size image. `payload` is the store read, and it runs
    /// off the main actor with the decode, because pulling a 15 MB blob out
    /// of SQLite is the expensive half. Only called on a cache miss.
    func fullImage(
        entryID: String,
        payload: @escaping @Sendable () -> Data?
    ) async -> NSImage? {
        let key = entryID as NSString
        if let cached = fullImages.object(forKey: key) { return cached }
        guard let image = await Self.decode(payload) else { return nil }
        fullImages.setObject(image, forKey: key)
        return image
    }

    /// Dropped when the panel hides: a 15 MB screenshot has no reason to
    /// outlive the board that showed it. Thumbnails are small and stay, so
    /// reopening the board is not a fresh round of decodes.
    func removeFullImages() {
        fullImages.removeAllObjects()
    }

    /// Both halves are cancellable, and both checks earn their place:
    /// arrowing quickly through large screenshots would otherwise finish
    /// reading and decoding every entry it passed over.
    @concurrent
    private nonisolated static func decode(
        _ payload: @Sendable () -> Data?
    ) async -> NSImage? {
        guard !Task.isCancelled, let data = payload(), !data.isEmpty else { return nil }
        guard !Task.isCancelled else { return nil }
        return NSImage(data: data)
    }
}
