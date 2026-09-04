import Foundation

package struct FileTextPreview: Equatable, Sendable {
    package let isCode: Bool
    package let lines: [String]
    package let isTruncated: Bool
    package let isEmpty: Bool

    package init(
        isCode: Bool,
        lines: [String],
        isTruncated: Bool,
        isEmpty: Bool
    ) {
        self.isCode = isCode
        self.lines = lines
        self.isTruncated = isTruncated
        self.isEmpty = isEmpty
    }
}

package enum FileTextPreviewDecoder {
    package static let maxPreviewBytes = 64 * 1_024
    package static let maxPreviewLines = 200

    package static func decode(
        at url: URL,
        isCode: Bool,
        maxBytes: Int = maxPreviewBytes,
        maxLines: Int = maxPreviewLines
    ) -> FileTextPreview? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        let rawData: Data
        do {
            rawData = try (fileHandle.read(upToCount: maxBytes + 1)) ?? Data()
        } catch {
            return nil
        }

        if rawData.isEmpty {
            return FileTextPreview(
                isCode: isCode,
                lines: [],
                isTruncated: false,
                isEmpty: true
            )
        }

        let isByteTruncated = rawData.count > maxBytes
        let dataToDecode = isByteTruncated ? rawData.prefix(maxBytes) : rawData

        guard let text = decodeString(from: Data(dataToDecode)) else {
            return nil
        }

        if text.contains("\0") {
            return nil
        }

        let allLines = ClipboardInspector.codeLines(text, limit: maxLines + 1)
        let isLineTruncated = allLines.count > maxLines
        let lines = isLineTruncated ? Array(allLines.prefix(maxLines)) : allLines
        let isTruncated = isByteTruncated || isLineTruncated

        return FileTextPreview(
            isCode: isCode,
            lines: lines,
            isTruncated: isTruncated,
            isEmpty: lines.isEmpty
        )
    }

    private static func decodeString(from data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            let stripped = data.dropFirst(3)
            if stripped.contains(0x00) { return nil }
            return String(data: stripped, encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        if data.contains(0x00) {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor
final class FileTextPreviewCache {
    static let shared = FileTextPreviewCache()

    private struct CacheKey: Hashable {
        let path: String
        let modificationDate: Date
        let fileSize: UInt64
    }

    private var cache: [CacheKey: FileTextPreview] = [:]

    init() {}

    private func makeKey(for url: URL) -> CacheKey? {
        let standardized = url.standardizedFileURL.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: standardized)
        else {
            return nil
        }
        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        let fileSize = attributes[.size] as? UInt64 ?? 0
        return CacheKey(path: standardized, modificationDate: modificationDate, fileSize: fileSize)
    }

    func immediatePreview(for url: URL, isCode: Bool) -> FileTextPreview? {
        guard let key = makeKey(for: url) else { return nil }
        return cache[key]
    }

    func preview(for url: URL, isCode: Bool) async -> FileTextPreview? {
        guard let key = makeKey(for: url) else { return nil }
        if let existing = cache[key] {
            return existing
        }

        let preview = await Task.detached(priority: .userInitiated) {
            FileTextPreviewDecoder.decode(at: url, isCode: isCode)
        }.value

        if let preview {
            if cache.count >= 128 {
                cache.removeAll(keepingCapacity: true)
            }
            cache[key] = preview
        }
        return preview
    }
}
