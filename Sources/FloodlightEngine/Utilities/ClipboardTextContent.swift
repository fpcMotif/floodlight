import Foundation

/// The red, green, blue, and optional alpha of a copied hex colour, decoded
/// once when the entry is classified.
package struct ClipboardColorComponents: Equatable, Hashable, Sendable {
    package let red: Int
    package let green: Int
    package let blue: Int
    package let alpha: Int?

    package var rgbDescription: String {
        guard let alpha else {
            return "rgb(\(red), \(green), \(blue))"
        }
        let alphaValue = Double(alpha) / 255
        return "rgba(\(red), \(green), \(blue), \(String(format: "%.2f", alphaValue)))"
    }

    /// `#RRGGBB` or `#RRGGBBAA` — the stored form, which `init(hex:)` reads back.
    var hexDescription: String {
        let rgb = String(format: "#%02X%02X%02X", red, green, blue)
        guard let alpha else { return rgb }
        return rgb + String(format: "%02X", alpha)
    }
}

/// In an extension so the memberwise initializer survives for fixtures.
extension ClipboardColorComponents {
    /// Parses `#RGB`, `#RRGGBB`, or `#RRGGBBAA`, surrounding whitespace
    /// allowed. ASCII digits only: `Character.isHexDigit` also accepts
    /// fullwidth forms the scanner cannot read, and a colour the list shows
    /// a swatch for must be one the inspector can decode.
    init?(hex text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let digits = String(trimmed.dropFirst())
        guard [3, 6, 8].contains(digits.count),
              digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt64(digits, radix: 16)
        else {
            return nil
        }

        switch digits.count {
        case 3:
            red = Int((value >> 8) & 0xF) * 17
            green = Int((value >> 4) & 0xF) * 17
            blue = Int(value & 0xF) * 17
            alpha = nil
        case 6:
            red = Int((value >> 16) & 0xFF)
            green = Int((value >> 8) & 0xFF)
            blue = Int(value & 0xFF)
            alpha = nil
        default:
            red = Int((value >> 24) & 0xFF)
            green = Int((value >> 16) & 0xFF)
            blue = Int((value >> 8) & 0xFF)
            alpha = Int(value & 0xFF)
        }
    }
}

/// A copied local path, resolved once: the file URL, and the names the list
/// shows for it. `URL`'s path-component calls are what a thousand rows feel
/// on a keystroke, so they run here rather than in the row builder.
package struct ClipboardPathContent: Equatable, Hashable, Sendable {
    package let url: URL
    /// The last path component, which is `/` at the root; the row falls
    /// back to the text as copied only when there is none at all.
    package let name: String
    /// The parent folder's name, or `nil` when the path sits at the root.
    package let parentFolderName: String?
    /// The extension, lowercased, for picking the row's icon.
    package let fileExtension: String

    package init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        parentFolderName = parent == "/" || parent.isEmpty ? nil : parent
        fileExtension = url.pathExtension.lowercased()
    }
}

/// What a text Clipboard Entry holds, decided once when the entry is recorded
/// and stored beside it (#73). The list reads it for a row's icon and title
/// and the inspector for its detail; neither parses the text again, so a
/// keystroke over a thousand entries costs no JSON parse and no stat.
package enum ClipboardTextContent: Equatable, Hashable, Sendable {
    /// Prose, or anything no other case claims.
    case plain
    /// An `http` or `https` URL; `domain` is its host without a leading `www.`.
    case link(domain: String)
    /// A `#RGB`, `#RRGGBB`, or `#RRGGBBAA` colour.
    case color(ClipboardColorComponents)
    /// Source code, with the hint the inspector shows: `JSON`, `HTML`, or `Code`.
    case code(language: String)
    /// A single-line local path — `/…`, `~/…`, or `file://…` — resolved to a
    /// file URL whether or not anything is at it. History records what was
    /// copied; whether it still exists is the selection's question.
    case path(ClipboardPathContent)

    package static func path(at url: URL) -> ClipboardTextContent {
        .path(ClipboardPathContent(url: url))
    }

    /// The one classifier. Capture runs it when an entry is recorded, and the
    /// store runs it once for rows recorded before it was stored.
    package static func classify(_ text: String) -> ClipboardTextContent {
        if let url = localPath(in: text) {
            return .path(at: url)
        }
        if let domain = linkDomain(in: text) {
            return .link(domain: domain)
        }
        if let color = ClipboardColorComponents(hex: text) {
            return .color(color)
        }
        if let language = codeLanguage(in: text) {
            return .code(language: language)
        }
        return .plain
    }

    // MARK: - Stored form

    /// The two columns the store keeps: a kind, and the one fact it carries.
    var storedForm: (kind: String, detail: String?) {
        switch self {
        case .plain: ("plain", nil)
        case let .link(domain): ("link", domain)
        case let .color(components): ("color", components.hexDescription)
        case let .code(language): ("code", language)
        case let .path(content): ("path", content.url.absoluteString)
        }
    }

    /// `nil` for a row written before the columns existed, or one whose
    /// stored form this build cannot read — the caller classifies again.
    init?(storedKind: String?, storedDetail: String?) {
        switch (storedKind, storedDetail) {
        case ("plain", _):
            self = .plain
        case let ("link", domain?):
            self = .link(domain: domain)
        case let ("color", hex?):
            guard let components = ClipboardColorComponents(hex: hex) else { return nil }
            self = .color(components)
        case let ("code", language?):
            self = .code(language: language)
        case let ("path", string?):
            guard let url = URL(string: string), url.isFileURL else { return nil }
            self = .path(at: url)
        default:
            return nil
        }
    }

    // MARK: - Parsers

    private static func localPath(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // `\r\n` is one Swift Character, so `contains("\n")` misses CRLF.
        guard !trimmed.contains(where: \.isNewline) else { return nil }

        let path: String
        if trimmed.hasPrefix("file://") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            path = url.path
        } else if trimmed.hasPrefix("~/") {
            path = NSString(string: trimmed).expandingTildeInPath
        } else if trimmed.hasPrefix("/") {
            path = trimmed
        } else {
            return nil
        }
        guard !path.isEmpty else { return nil }

        return URL(fileURLWithPath: path)
    }

    private static func linkDomain(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Any one of these makes a snippet read as source, whichever language it
    /// came from: the two branches this replaced both answered "Code", so
    /// Swift's markers and JavaScript's never told the caller apart. Each
    /// marker carries its trailing space, which is what keeps `funcs` and
    /// `classy` from matching.
    private static let codeMarkers = [
        "func ", "struct ", "import ", "class ",
        "const ", "function ", "export ",
    ]

    private static func codeLanguage(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        {
            if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                return "JSON"
            }
        }
        if codeMarkers.contains(where: { trimmed.contains($0) }) {
            return "Code"
        }
        if trimmed.hasPrefix("<!DOCTYPE") || trimmed
            .hasPrefix("<html") ||
            (trimmed.hasPrefix("<") && trimmed.hasSuffix(">") && trimmed.contains("</"))
        {
            return "HTML"
        }
        return nil
    }
}
