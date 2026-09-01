import FloodlightEngine
import Foundation

/// Presentation snapshot for Clipboard mode's inspector pane.
enum ClipboardInspector: Equatable {
    struct TextDetail: Equatable {
        let title: String
        let body: String
        let sourceApp: String
        let createdAt: Date
    }

    struct FileDetail: Equatable {
        let name: String
        let path: String
        let type: String
        let byteCount: UInt64?
        let sourceApp: String
        let createdAt: Date
        let fileURL: URL
    }

    struct ImageDetail: Equatable {
        let name: String
        let width: Int
        let height: Int
        let byteCount: Int
        let previewPNG: Data?
        let sourceApp: String
        let createdAt: Date
    }

    case text(TextDetail)
    case file(FileDetail)
    case image(ImageDetail)

    static func snapshot(
        for entry: ClipboardEntry,
        imagePNG: Data? = nil
    ) -> ClipboardInspector {
        let sourceApp = sourceAppDisplayName(for: entry.sourceAppBundleID)
        switch entry.kind {
        case .text:
            return .text(TextDetail(
                title: previewTitle(for: entry.text),
                body: entry.text,
                sourceApp: sourceApp,
                createdAt: entry.createdAt
            ))
        case .file:
            let url = URL(fileURLWithPath: entry.text)
            let name = url.lastPathComponent
            return .file(FileDetail(
                name: name.isEmpty ? entry.text : name,
                path: entry.text,
                type: fileType(for: url),
                byteCount: fileByteCount(at: url),
                sourceApp: sourceApp,
                createdAt: entry.createdAt,
                fileURL: url
            ))
        case .image:
            return .image(ImageDetail(
                name: entry.text.isEmpty ? "Image" : entry.text,
                width: entry.image?.width ?? 0,
                height: entry.image?.height ?? 0,
                byteCount: entry.image?.byteCount ?? 0,
                previewPNG: imagePNG ?? entry.image?.thumbnailPNGData,
                sourceApp: sourceApp,
                createdAt: entry.createdAt
            ))
        }
    }

    private static func previewTitle(for text: String) -> String {
        let singleLine = text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return singleLine.isEmpty ? "(Empty text)" : singleLine
    }

    private static func fileType(for url: URL) -> String {
        if url.hasDirectoryPath { return "Folder" }
        let ext = url.pathExtension
        if ext.isEmpty { return "File" }
        return ext.uppercased()
    }

    private static func fileByteCount(at url: URL) -> UInt64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return nil }
        guard let size = values?.fileSize, size > 0 else { return nil }
        return UInt64(size)
    }

    private static func sourceAppDisplayName(for bundleID: String?) -> String {
        guard let bundleID, !bundleID.isEmpty else { return "Clipboard" }
        guard let lastComponent = bundleID.split(separator: ".").last, !lastComponent.isEmpty else {
            return bundleID
        }
        if lastComponent.lowercased() == "finder" {
            return "Finder"
        }
        return String(lastComponent)
    }
}
