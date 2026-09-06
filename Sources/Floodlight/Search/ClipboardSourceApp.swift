import AppKit
import Foundation
import os

/// Resolves a clipboard entry's source bundle identifier to the name the
/// user knows the app by and the icon that goes with it. The list column,
/// the inspector, and the icon cache all come through here, so a row can
/// never say "ghostty" while the icon beside it belongs to something else.
enum ClipboardSourceApp {
    /// System processes whose Launch Services name is not the name their icon
    /// carries, or that it cannot resolve at all.
    private static let knownNames: [String: String] = [
        "com.apple.screencaptureui": "Screenshot",
        "com.apple.finder": "Finder",
    ]

    /// What Launch Services said, memoized.
    ///
    /// The outer optional is "have we asked?"; the inner one is "did it know?".
    /// A screenshot's source has no application URL, and caching that miss is
    /// the point — an inspector that redraws on every keystroke then asks once
    /// per launch rather than once per render.
    private static let urlCache = OSAllocatedUnfairLock<[String: URL?]>(initialState: [:])

    static func displayName(for bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "Clipboard" }
        // Before the lookup, not after it: these are the identifiers Launch
        // Services answers badly or not at all, so asking it first would pay
        // for an answer this table exists to override.
        if let known = knownNames[bundleID] { return known }
        if let applicationURL = applicationURL(for: bundleID) {
            let name = applicationURL.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        guard let lastComponent = bundleID.split(separator: ".").last, !lastComponent.isEmpty else {
            return bundleID
        }
        return String(lastComponent)
    }

    static func applicationURL(for bundleID: String?) -> URL? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = urlCache.withLock({ $0[bundleID] }) { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        urlCache.withLock { $0[bundleID] = url }
        return url
    }
}
