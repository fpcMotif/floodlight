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
    }

    struct FileClassification: Equatable {
        let isVideo: Bool
        let isImage: Bool
        let isText: Bool
        let isCode: Bool
    }

    struct TextDetail: Equatable {
        let body: String
        /// The classification the entry was recorded with (#73). The type
        /// label and the one fact it carries are read off it below, never
        /// derived from the body, so the inspector cannot disagree with
        /// the list's icon.
        let content: ClipboardTextContent?
        let characterCount: Int
        let wordCount: Int
        let lineCount: Int
        let sourceApp: String
        let sourceAppBundleID: String?
        let formattedDate: String
        let pinnedAt: Date?

        var contentType: ContentType {
            switch content {
            case .link?: .link
            case .color?: .color
            case .code?: .code
            case .plain?, .path?, nil: .text
            }
        }

        var domain: String? {
            if case let .link(domain)? = content { domain } else { nil }
        }

        var codeLanguage: String? {
            if case let .code(language)? = content { language } else { nil }
        }

        var colorComponents: ClipboardColorComponents? {
            if case let .color(components)? = content { components } else { nil }
        }
    }

    struct FileDetail: Equatable {
        let name: String
        let path: String
        let type: String
        let byteCount: UInt64?
        let isVideo: Bool
        let isImage: Bool
        let isText: Bool
        let isCode: Bool
        let sourceApp: String
        let sourceAppBundleID: String?
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
        /// The stored 128 pt thumbnail, which is what the pane can draw the
        /// instant the selection moves.
        let thumbnailPNG: Data?
        /// A full-size payload exists for this entry. The snapshot says so
        /// rather than carrying the payload: a 15 MB screenshot read on
        /// every republication is what made arrowing stutter (#72).
        let hasFullImage: Bool
        let sourceApp: String
        let sourceAppBundleID: String?
        let formattedDate: String
        let pinnedAt: Date?
    }

    case text(TextDetail)
    case file(FileDetail)
    case image(ImageDetail)

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
            if case let .path(path) = entry.textContent {
                return .file(fileDetail(
                    entry: entry,
                    url: path.url,
                    path: entry.text,
                    sourceApp: sourceApp,
                    formattedDate: formattedDate
                ))
            }

            let text = entry.text
            return .text(TextDetail(
                body: text,
                content: entry.textContent,
                characterCount: text.count,
                wordCount: countWords(text),
                lineCount: countLines(text),
                sourceApp: sourceApp,
                sourceAppBundleID: entry.sourceAppBundleID,
                formattedDate: formattedDate,
                pinnedAt: entry.pinnedAt
            ))

        case .file:
            return .file(fileDetail(
                entry: entry,
                url: URL(fileURLWithPath: entry.text),
                path: entry.text,
                sourceApp: sourceApp,
                formattedDate: formattedDate
            ))

        case .image:
            let width = entry.image?.width ?? 0
            let height = entry.image?.height ?? 0

            let thumbnail = entry.image?.thumbnailPNGData

            return .image(ImageDetail(
                entryID: entry.id,
                name: entry.text.isEmpty ? "Image" : entry.text,
                width: width,
                height: height,
                byteCount: entry.image?.byteCount ?? 0,
                thumbnailPNG: thumbnail.flatMap { $0.isEmpty ? nil : $0 },
                hasFullImage: hasFullImage,
                sourceApp: sourceApp,
                sourceAppBundleID: entry.sourceAppBundleID,
                formattedDate: formattedDate,
                pinnedAt: entry.pinnedAt
            ))
        }
    }

    /// The one place a `FileDetail` is built.
    ///
    /// Both paths that produce one — a `.file` entry, and a `.text` entry whose
    /// body was classified as a local path — describe the same thing and
    /// differ only in where the URL and the displayed path come from.
    private static func fileDetail(
        entry: ClipboardEntry,
        url: URL,
        path: String,
        sourceApp: String,
        formattedDate: String
    ) -> FileDetail {
        let name = url.lastPathComponent
        let classification = classifyFile(ext: url.pathExtension.lowercased())
        let fileExists = FileManager.default.fileExists(atPath: url.path)
        return FileDetail(
            name: name.isEmpty ? path : name,
            path: path,
            type: fileType(for: url),
            byteCount: fileExists ? fileByteCount(at: url) : nil,
            isVideo: classification.isVideo,
            isImage: classification.isImage,
            isText: classification.isText,
            isCode: classification.isCode,
            sourceApp: sourceApp,
            sourceAppBundleID: entry.sourceAppBundleID,
            formattedDate: formattedDate,
            fileURL: url,
            pinnedAt: entry.pinnedAt
        )
    }

    private static func classifyFile(ext: String) -> FileClassification {
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
                isVideo: false,
                isImage: true,
                isText: false,
                isCode: false
            )
        }
        if videoExtensions.contains(ext) {
            return FileClassification(
                isVideo: true,
                isImage: false,
                isText: false,
                isCode: false
            )
        }
        if codeExtensions.contains(ext) {
            return FileClassification(
                isVideo: false,
                isImage: false,
                isText: true,
                isCode: true
            )
        }
        if textExtensions.contains(ext) {
            return FileClassification(
                isVideo: false,
                isImage: false,
                isText: true,
                isCode: false
            )
        }
        return FileClassification(
            isVideo: false,
            isImage: false,
            isText: false,
            isCode: false
        )
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
