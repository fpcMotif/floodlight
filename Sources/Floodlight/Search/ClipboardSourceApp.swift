import AppKit
import Foundation
import os

/// Resolves a clipboard entry's source bundle identifier to the name the
/// user knows the app by and the icon that goes with it. The list column,
/// the inspector, and the icon cache all come through here, so a row can
/// never say "ghostty" while the icon beside it belongs to something else.
final class ClipboardSourceApp: Sendable {
    /// What one bundle identifier resolves to. `applicationURL` is `nil` when
    /// Launch Services cannot place the identifier — a screenshot's source is
    /// one of those. The miss is cached like any other answer, so an inspector
    /// that redraws on every keystroke asks once per launch, not once per render.
    struct Resolution: Sendable {
        let name: String
        let applicationURL: URL?
    }

    static let shared = ClipboardSourceApp()

    /// System processes whose Launch Services name is not the name their icon
    /// carries, or that it cannot resolve at all.
    private static let knownNames: [String: String] = [
        "com.apple.screencaptureui": "Screenshot",
        "com.apple.finder": "Finder",
    ]

    private let locateApplication: @Sendable (String) -> URL?
    private let cache = OSAllocatedUnfairLock<[String: Resolution]>(initialState: [:])

    init(
        locateApplication: @escaping @Sendable (String) -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
    ) {
        self.locateApplication = locateApplication
    }

    static func displayName(for bundleID: String?) -> String {
        shared.resolution(for: bundleID)?.name ?? "Clipboard"
    }

    static func applicationURL(for bundleID: String?) -> URL? {
        shared.resolution(for: bundleID)?.applicationURL
    }

    func resolution(for bundleID: String?) -> Resolution? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = cache.withLock({ $0[bundleID] }) {
            return cached
        }
        let applicationURL = locateApplication(bundleID)
        let resolved = Resolution(
            name: Self.name(for: bundleID, applicationURL: applicationURL),
            applicationURL: applicationURL
        )
        cache.withLock { $0[bundleID] = resolved }
        return resolved
    }

    private static func name(for bundleID: String, applicationURL: URL?) -> String {
        if let known = knownNames[bundleID] {
            return known
        }
        if let applicationURL {
            let name = applicationURL.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        guard let lastComponent = bundleID.split(separator: ".").last, !lastComponent.isEmpty else {
            return bundleID
        }
        return String(lastComponent)
    }
}
