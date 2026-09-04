import Foundation

struct FileTextPreview: Equatable, Sendable {
    let lines: [String]
    let isTruncated: Bool
    let isEmpty: Bool
}

enum FileTextPreviewDecoder {
    static let maxPreviewBytes = 64 * 1_024
    static let maxPreviewLines = 200

    static func decode(
        at url: URL,
        maxBytes: Int = maxPreviewBytes,
        maxLines: Int = maxPreviewLines
    ) -> FileTextPreview? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else {
            return nil
        }
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fileHandle.close() }

        let rawData: Data
        do {
            rawData = try (fileHandle.read(upToCount: maxBytes + 1)) ?? Data()
        } catch {
            return nil
        }

        if rawData.isEmpty {
            return FileTextPreview(lines: [], isTruncated: false, isEmpty: true)
        }

        let isByteTruncated = rawData.count > maxBytes
        var dataToDecode = isByteTruncated ? Data(rawData.prefix(maxBytes)) : rawData
        if isByteTruncated {
            dataToDecode = trimmingIncompleteTrailingCharacter(dataToDecode)
        }

        guard let text = decodeString(from: dataToDecode) else {
            return nil
        }

        // UTF-8 input was already screened for NUL bytes; this catches the
        // UTF-16 branches, where every ASCII character carries a zero byte.
        if text.contains("\0") {
            return nil
        }

        if text.isEmpty {
            return FileTextPreview(lines: [], isTruncated: false, isEmpty: true)
        }

        let allLines = ClipboardInspector.codeLines(text, limit: maxLines + 1)
        let isLineTruncated = allLines.count > maxLines
        var lines = isLineTruncated ? Array(allLines.prefix(maxLines)) : allLines
        if isByteTruncated, !isLineTruncated, lines.count > 1 {
            // The byte cutoff lands mid-line rather than mid-character (that
            // case is handled above): the last line is partial, not real
            // content, so it is dropped rather than shown truncated mid-word.
            lines.removeLast()
        }
        let isTruncated = isByteTruncated || isLineTruncated

        return FileTextPreview(
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

    /// Byte-truncating at `maxBytes` can land in the middle of a multibyte
    /// character, and strict decoding would then reject the whole prefix.
    /// Trim the tail back to a character boundary; this may also drop one
    /// complete trailing character, which is harmless in a preview that is
    /// already marked truncated.
    private static func trimmingIncompleteTrailingCharacter(_ data: Data) -> Data {
        let isLittleEndianUTF16 = data.starts(with: [0xFF, 0xFE])
        let isBigEndianUTF16 = data.starts(with: [0xFE, 0xFF])
        guard isLittleEndianUTF16 || isBigEndianUTF16 else {
            var trimmed = data
            var droppedContinuationBytes = 0
            while droppedContinuationBytes < 3, let last = trimmed.last, last & 0xC0 == 0x80 {
                trimmed.removeLast()
                droppedContinuationBytes += 1
            }
            if let last = trimmed.last, last & 0xC0 == 0xC0 {
                trimmed.removeLast()
            }
            return trimmed
        }

        var payload = Data(data.dropFirst(2))
        if !payload.count.isMultiple(of: 2) {
            payload.removeLast()
        }
        if payload.count >= 2 {
            let tail = Array(payload.suffix(2))
            let codeUnit: UInt16 = if isLittleEndianUTF16 {
                UInt16(tail[0]) | (UInt16(tail[1]) << 8)
            } else {
                (UInt16(tail[0]) << 8) | UInt16(tail[1])
            }
            if (0xD800...0xDBFF).contains(codeUnit) {
                payload.removeLast(2)
            }
        }
        var result = Data(data.prefix(2))
        result.append(payload)
        return result
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

    private var cache: [CacheKey: FileTextPreview?] = [:]

    init() {}

    private func makeKey(for url: URL) -> CacheKey? {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: standardized)
        else {
            return nil
        }
        let modificationDate = attributes[.modificationDate] as? Date ?? .distantPast
        let fileSize = attributes[.size] as? UInt64 ?? 0
        return CacheKey(path: standardized, modificationDate: modificationDate, fileSize: fileSize)
    }

    func immediatePreview(for url: URL) -> FileTextPreview? {
        guard let key = makeKey(for: url) else { return nil }
        return cache[key] ?? nil
    }

    func preview(for url: URL) async -> FileTextPreview? {
        guard let key = makeKey(for: url) else { return nil }
        if let cached = cache[key] {
            return cached
        }

        // The bounded read still touches the disk; keep it off the main
        // actor so a slow volume never stalls the panel's layout pass.
        let preview = await Task.detached(priority: .userInitiated) {
            FileTextPreviewDecoder.decode(at: url)
        }.value

        if cache.count >= 128 {
            cache.removeAll(keepingCapacity: true)
        }
        // `.some(nil)` records an unreadable file so it is not re-read on
        // every reselection; a bare `nil` here would erase the key instead.
        cache[key] = .some(preview)
        return preview
    }
}
