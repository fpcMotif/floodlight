import AppKit
import FloodlightEngine
import Foundation

/// Presentation snapshot for Clipboard mode's inspector pane.
enum ClipboardInspector: Equatable {
    enum ContentType: String, Equatable {
        case text = "Text"
        case link = "Link"
        case code = "Code"
        case color = "Color"
        case image = "Image"
        case video = "Video"
        case file = "File"
    }

    struct TextClassification: Equatable {
        let contentType: ContentType
        let domain: String?
        let colorHex: String?
        let codeLanguage: String?
        let colorComponents: ColorComponents?
    }

    struct ColorComponents: Equatable {
        let red: Int
        let green: Int
        let blue: Int
        let alpha: Int?

        var rgbDescription: String {
            guard let alpha else {
                return "rgb(\(red), \(green), \(blue))"
            }
            let alphaValue = Double(alpha) / 255
            return "rgba(\(red), \(green), \(blue), \(String(format: "%.2f", alphaValue)))"
        }
    }

    struct FileClassification: Equatable {
        let contentType: ContentType
        let isVideo: Bool
        let isImage: Bool
        let isText: Bool
        let isCode: Bool
    }

    struct TextDetail: Equatable {
        let title: String
        let body: String
        let contentType: ContentType
        let characterCount: Int
        let wordCount: Int
        let lineCount: Int
        let domain: String?
        let colorHex: String?
        let codeLanguage: String?
        let colorComponents: ColorComponents?
        let sourceApp: String
        let sourceAppBundleID: String?
        let createdAt: Date
        let formattedDate: String
        let pinnedAt: Date?
    }

    struct FileDetail: Equatable {
        let name: String
        let path: String
        let type: String
        let contentType: ContentType
        let byteCount: UInt64?
        let isVideo: Bool
        let isImage: Bool
        let isText: Bool
        let isCode: Bool
        let sourceApp: String
        let sourceAppBundleID: String?
        let createdAt: Date
        let formattedDate: String
        let fileURL: URL
        let pinnedAt: Date?
    }

    struct ImageDetail: Equatable {
        /// The Clipboard History entry this describes — what the pane keys
        /// its full-image load and its decoded-image cache on.
        let entryID: String
        let name: String
        let width: Int
        let height: Int
        let byteCount: Int
        let format: String
        /// The stored 128 pt thumbnail, which is what the pane can draw the
        /// instant the selection moves.
        let thumbnailPNG: Data?
        /// A full-size payload exists for this entry. The snapshot says so
        /// rather than carrying the payload: a 15 MB screenshot read on
        /// every republication is what made arrowing stutter (#72).
        let hasFullImage: Bool
        let sourceApp: String
        let sourceAppBundleID: String?
        let createdAt: Date
        let formattedDate: String
        let pinnedAt: Date?
    }

    case text(TextDetail)
    case file(FileDetail)
    case image(ImageDetail)

    var sourceApp: String {
        switch self {
        case let .text(detail): detail.sourceApp
        case let .file(detail): detail.sourceApp
        case let .image(detail): detail.sourceApp
        }
    }

    var sourceAppBundleID: String? {
        switch self {
        case let .text(detail): detail.sourceAppBundleID
        case let .file(detail): detail.sourceAppBundleID
        case let .image(detail): detail.sourceAppBundleID
        }
    }

    /// Everything the inspector pane renders, derived from the entry alone.
    /// `hasFullImage` is a fact about the store the caller has already
    /// established cheaply — the snapshot never reads an image payload
    /// itself, which is what keeps it affordable to recompute whenever the
    /// selection moves.
    static func snapshot(
        for entry: ClipboardEntry,
        hasFullImage: Bool = false
    ) -> ClipboardInspector {
        let sourceApp = sourceAppDisplayName(for: entry.sourceAppBundleID)
        let formattedDate = formattedDetailedDate(entry.createdAt)

        switch entry.kind {
        case .text:
            let text = entry.text
            if let fileURL = parseLocalPath(text) {
                let name = fileURL.lastPathComponent
                let ext = fileURL.pathExtension.lowercased()
                let fileExists = FileManager.default.fileExists(atPath: fileURL.path)
                let classification = classifyFile(url: fileURL, ext: ext)

                return .file(FileDetail(
                    name: name.isEmpty ? text : name,
                    path: text,
                    type: fileType(for: fileURL),
                    contentType: classification.contentType,
                    byteCount: fileExists ? fileByteCount(at: fileURL) : nil,
                    isVideo: classification.isVideo,
                    isImage: classification.isImage,
                    isText: classification.isText,
                    isCode: classification.isCode,
                    sourceApp: sourceApp,
                    sourceAppBundleID: entry.sourceAppBundleID,
                    createdAt: entry.createdAt,
                    formattedDate: formattedDate,
                    fileURL: fileURL,
                    pinnedAt: entry.pinnedAt
                ))
            }

            let classification = classifyText(text)
            let characterCount = text.count
            let wordCount = countWords(text)
            let lineCount = countLines(text)

            return .text(TextDetail(
                title: previewTitle(for: text),
                body: text,
                contentType: classification.contentType,
                characterCount: characterCount,
                wordCount: wordCount,
                lineCount: lineCount,
                domain: classification.domain,
                colorHex: classification.colorHex,
                codeLanguage: classification.codeLanguage,
                colorComponents: classification.colorComponents,
                sourceApp: sourceApp,
                sourceAppBundleID: entry.sourceAppBundleID,
                createdAt: entry.createdAt,
                formattedDate: formattedDate,
                pinnedAt: entry.pinnedAt
            ))

        case .file:
            let url = URL(fileURLWithPath: entry.text)
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            let classification = classifyFile(url: url, ext: ext)
            let fileExists = FileManager.default.fileExists(atPath: url.path)

            return .file(FileDetail(
                name: name.isEmpty ? entry.text : name,
                path: entry.text,
                type: fileType(for: url),
                contentType: classification.contentType,
                byteCount: fileExists ? fileByteCount(at: url) : nil,
                isVideo: classification.isVideo,
                isImage: classification.isImage,
                isText: classification.isText,
                isCode: classification.isCode,
                sourceApp: sourceApp,
                sourceAppBundleID: entry.sourceAppBundleID,
                createdAt: entry.createdAt,
                formattedDate: formattedDate,
                fileURL: url,
                pinnedAt: entry.pinnedAt
            ))

        case .image:
            let width = entry.image?.width ?? 0
            let height = entry.image?.height ?? 0
            let format = imageFormatName(width: width, height: height)

            let thumbnail = entry.image?.thumbnailPNGData

            return .image(ImageDetail(
                entryID: entry.id,
                name: entry.text.isEmpty ? "Image" : entry.text,
                width: width,
                height: height,
                byteCount: entry.image?.byteCount ?? 0,
                format: format,
                thumbnailPNG: thumbnail.flatMap { $0.isEmpty ? nil : $0 },
                hasFullImage: hasFullImage,
                sourceApp: sourceApp,
                sourceAppBundleID: entry.sourceAppBundleID,
                createdAt: entry.createdAt,
                formattedDate: formattedDate,
                pinnedAt: entry.pinnedAt
            ))
        }
    }

    private static func classifyText(_ text: String) -> TextClassification {
        if let (_, domain) = parseURL(text) {
            return TextClassification(
                contentType: .link,
                domain: domain,
                colorHex: nil,
                codeLanguage: nil,
                colorComponents: nil
            )
        }
        if let hex = parseHexColor(text) {
            return TextClassification(
                contentType: .color,
                domain: nil,
                colorHex: hex,
                codeLanguage: nil,
                colorComponents: parseHexColorComponents(text)
            )
        }
        if let code = parseCodeHint(text) {
            return TextClassification(
                contentType: .code,
                domain: nil,
                colorHex: nil,
                codeLanguage: code,
                colorComponents: nil
            )
        }
        return TextClassification(
            contentType: .text,
            domain: nil,
            colorHex: nil,
            codeLanguage: nil,
            colorComponents: nil
        )
    }

    private static func classifyFile(url: URL, ext: String) -> FileClassification {
        let imageExtensions: Set = [
            "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "tif", "bmp", "avif", "ico",
            "icns", "svg",
        ]
        let videoExtensions: Set = [
            "mp4", "mov", "m4v", "webm", "mkv", "avi", "wmv", "flv", "ts", "mpg", "mpeg",
        ]
        let codeExtensions: Set = [
            "json", "py", "swift", "js", "mjs", "cjs", "ts", "mts", "cts", "jsx", "tsx",
            "rs", "go", "c", "cpp", "cc", "cxx", "h", "hpp", "hh", "hxx", "m", "mm",
            "cs", "java", "kt", "kts", "rb", "php", "sh", "bash", "zsh", "fish", "sql",
            "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "less", "lua",
            "vim", "r", "dart", "zig", "nim", "graphql", "gql", "proto",
        ]
        let textExtensions: Set = [
            "md", "markdown", "mdown", "mkdn", "txt", "text", "log", "csv", "tsv",
            "rtf", "env", "ini", "conf", "cfg", "properties",
        ]
        if imageExtensions.contains(ext) {
            return FileClassification(
                contentType: .image,
                isVideo: false,
                isImage: true,
                isText: false,
                isCode: false
            )
        }
        if videoExtensions.contains(ext) {
            return FileClassification(
                contentType: .video,
                isVideo: true,
                isImage: false,
                isText: false,
                isCode: false
            )
        }
        if codeExtensions.contains(ext) {
            return FileClassification(
                contentType: .code,
                isVideo: false,
                isImage: false,
                isText: true,
                isCode: true
            )
        }
        if textExtensions.contains(ext) {
            return FileClassification(
                contentType: .text,
                isVideo: false,
                isImage: false,
                isText: true,
                isCode: false
            )
        }
        return FileClassification(
            contentType: .file,
            isVideo: false,
            isImage: false,
            isText: false,
            isCode: false
        )
    }

    static func parseLocalPath(_ text: String) -> URL? {
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

        return URL(fileURLWithPath: path)
    }

    static func parseURL(_ text: String) -> (url: URL, domain: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return (url, domain)
    }

    static func parseHexColor(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        let hex = String(trimmed.dropFirst())
        guard hex.count == 3 || hex.count == 6 || hex.count == 8 else { return nil }
        guard hex.allSatisfy(\.isHexDigit) else { return nil }
        return "#" + hex.uppercased()
    }

    static func parseHexColorComponents(_ text: String) -> ColorComponents? {
        guard let hex = parseHexColor(text) else { return nil }
        let digits = String(hex.dropFirst())
        var value: UInt64 = 0
        guard Scanner(string: digits).scanHexInt64(&value) else { return nil }

        switch digits.count {
        case 3:
            let red = Int((value >> 8) & 0xF) * 17
            let green = Int((value >> 4) & 0xF) * 17
            let blue = Int(value & 0xF) * 17
            return ColorComponents(red: red, green: green, blue: blue, alpha: nil)
        case 6:
            let red = Int((value >> 16) & 0xFF)
            let green = Int((value >> 8) & 0xFF)
            let blue = Int(value & 0xFF)
            return ColorComponents(red: red, green: green, blue: blue, alpha: nil)
        case 8:
            let red = Int((value >> 24) & 0xFF)
            let green = Int((value >> 16) & 0xFF)
            let blue = Int((value >> 8) & 0xFF)
            let alpha = Int(value & 0xFF)
            return ColorComponents(red: red, green: green, blue: blue, alpha: alpha)
        default:
            return nil
        }
    }

    static func parseCodeHint(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        {
            if (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil {
                return "JSON"
            }
        }
        if trimmed.contains("func ") || trimmed.contains("struct ") || trimmed
            .contains("import ") || trimmed.contains("class ")
        {
            return "Code"
        }
        if trimmed.contains("const ") || trimmed.contains("function ") || trimmed
            .contains("export ")
        {
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

    static func countWords(_ text: String) -> Int {
        let words = text.split { $0.isWhitespace || $0.isNewline }
        return words.count
    }

    static func countLines(_ text: String) -> Int {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        return max(1, lines.count)
    }

    static func codeLines(_ text: String, limit: Int = 200) -> [String] {
        // Empty input is one blank line. Non-empty input splits on every
        // Unicode newline, including the `\r\n` grapheme cluster Swift treats
        // as a single Character — splitting on `"\n"` alone would leave a
        // CRLF-joined remainder intact.
        guard !text.isEmpty else { return [""] }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .prefix(limit)
            .map(String.init)
        return Array(lines)
    }

    /// Locale-aware: a 12-hour locale sees "Today at 3:03 PM", a 24-hour one
    /// "Today at 15:03". Seconds are dropped — the list already shows the
    /// entry's age, and a wall-clock second is never what the user recalls.
    static func formattedDetailedDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today at \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday at \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func imageFormatName(width: Int, height: Int) -> String {
        "PNG Image"
    }

    private static func previewTitle(for text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return singleLine.isEmpty ? "(Empty text)" : singleLine
    }

    private static func fileType(for url: URL) -> String {
        if url.hasDirectoryPath { return "Folder" }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "mp4", "mov", "m4v", "webm", "mkv", "avi": return "Video"
        case "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff", "svg": return "Image"
        case "json": return "JSON"
        case "md", "markdown", "mdown", "mkdn": return "Markdown"
        case "txt", "text": return "Plain Text"
        case "swift", "rs", "ts", "js", "py", "go", "c", "cpp", "h", "sh": return "Source Code"
        case "zip", "tar", "gz", "dmg": return "Archive"
        case "": return "File"
        default: return ext.uppercased()
        }
    }

    private static func fileByteCount(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return nil }
        guard let size = values?.fileSize, size > 0 else { return nil }
        return UInt64(size)
    }

    private static func sourceAppDisplayName(for bundleID: String?) -> String {
        ClipboardSourceApp.displayName(for: bundleID)
    }
}
