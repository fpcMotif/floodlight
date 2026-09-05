import AppKit
import Foundation
import os

/// Resolves a clipboard entry's source bundle identifier to the name the
/// user knows the app by. The list column and the inspector both come
/// through here, so a row can never say "ghostty" while the inspector
/// beside it says "Ghostty".
enum ClipboardSourceApp {
    /// System processes Launch Services cannot resolve by identifier, mapped
    /// to the name their icon carries.
    private static let knownNames: [String: String] = [
        "com.apple.screencaptureui": "Screenshot",
        "com.apple.finder": "Finder",
    ]

    /// Launch Services is asked once per bundle identifier; the projection
    /// runs on every keystroke and must not repeat that lookup per row.
    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    static func displayName(for bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "Clipboard" }
        if let cached = cache.withLock({ $0[bundleID] }) {
            return cached
        }
        let name = resolve(bundleID)
        cache.withLock { $0[bundleID] = name }
        return name
    }

    private static func resolve(_ bundleID: String) -> String {
        if let known = knownNames[bundleID] {
            return known
        }
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let name = appURL.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        guard let lastComponent = bundleID.split(separator: ".").last, !lastComponent.isEmpty else {
            return bundleID
        }
        return String(lastComponent)
    }
}
