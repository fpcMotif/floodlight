import Foundation

/// What a Clipboard Entry holds: copied text, a copied file/folder path, or
/// a captured image/screenshot.
package enum ClipboardEntryKind: String, Equatable, Hashable, Sendable {
    case text
    case file
    case image
}

/// Dimensions, hash, size, and thumbnail for a captured clipboard image.
package struct ClipboardImageMetadata: Equatable, Hashable, Sendable {
    package let hash: String
    package let width: Int
    package let height: Int
    package let byteCount: Int
    package let thumbnailPNGData: Data

    package init(
        hash: String,
        width: Int,
        height: Int,
        byteCount: Int,
        thumbnailPNGData: Data
    ) {
        self.hash = hash
        self.width = width
        self.height = height
        self.byteCount = byteCount
        self.thumbnailPNGData = thumbnailPNGData
    }
}

/// Original pasteboard representations of a captured clipboard image.
package struct ClipboardImagePayload: Equatable, Sendable {
    package let png: Data?
    package let tiff: Data?

    package init(png: Data?, tiff: Data?) {
        self.png = png
        self.tiff = tiff
    }
}

/// One immutable captured or pinned Clipboard History entry.
package struct ClipboardEntry: Identifiable, Equatable, Hashable, Sendable {
    package let id: String
    package let text: String
    package let kind: ClipboardEntryKind
    package let createdAt: Date
    package let sourceAppBundleID: String?
    package let pinnedAt: Date?
    package let image: ClipboardImageMetadata?
    /// What the text is — link, colour, code, path, or plain prose — for a
    /// `.text` entry; `nil` for a file or image entry. Decided once, when the
    /// entry is recorded or when the store reads a row that predates it (#73).
    package let textContent: ClipboardTextContent?

    package var isPinned: Bool {
        pinnedAt != nil
    }

    /// A text entry built without a `textContent` classifies itself, so a
    /// fixture reads exactly the way a recorded entry does.
    package init(
        id: String = UUID().uuidString,
        text: String,
        kind: ClipboardEntryKind = .text,
        createdAt: Date = .now,
        sourceAppBundleID: String? = nil,
        pinnedAt: Date? = nil,
        image: ClipboardImageMetadata? = nil,
        textContent: ClipboardTextContent? = nil
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.createdAt = createdAt
        self.sourceAppBundleID = sourceAppBundleID
        self.pinnedAt = pinnedAt
        self.image = image
        self.textContent = kind == .text ? textContent ?? .classify(text) : nil
    }

    func withPinnedAt(_ pinnedAt: Date?) -> ClipboardEntry {
        ClipboardEntry(
            id: id,
            text: text,
            kind: kind,
            createdAt: createdAt,
            sourceAppBundleID: sourceAppBundleID,
            pinnedAt: pinnedAt,
            image: image,
            textContent: textContent
        )
    }
}

/// Retention period for clipboard history.
package enum ClipboardRetention: Equatable, Sendable {
    case days(Int)
    case forever

    package func cutoffDate(from now: Date = .now) -> Date? {
        switch self {
        case let .days(days):
            now.addingTimeInterval(-Double(days) * 86_400)
        case .forever:
            nil
        }
    }
}
