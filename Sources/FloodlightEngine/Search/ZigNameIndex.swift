import FloodlightCore
import Foundation

package enum ZigFileIndexError: LocalizedError, Sendable {
    case build(code: Int32)
    case open(code: Int32)

    package var errorDescription: String? {
        switch self {
        case let .build(code):
            "The file index could not be built (error \(code))."
        case let .open(code):
            "The file index could not be opened (error \(code))."
        }
    }
}

/// One mapped index file from `core/`. A handle is immutable once open, so any
/// thread may search it at once; it closes when the last holder lets go,
/// which is what lets a scope change swap in a new index while a query is
/// still reading the old one.
final class ZigNameIndex: @unchecked Sendable {
    /// The engine's own ceiling on hits per query.
    private static let maxHits = 256
    /// Zig rebuilds paths into a 4 KB scratch buffer, so nothing longer comes back.
    private static let maxPathBytes = 4_096

    let rootURL: URL
    private let handle: OpaquePointer

    private init(rootURL: URL, handle: OpaquePointer) {
        self.rootURL = rootURL
        self.handle = handle
    }

    deinit {
        fl_index_close(handle)
    }

    /// Scans `rootURL` into `fileURL` and maps the result. The walk is one
    /// blocking C call that takes seconds on a home folder, so it runs on a
    /// dispatch thread rather than holding a cooperative-pool thread or the
    /// caller's actor for that long.
    static func build(root rootURL: URL, at fileURL: URL) async throws -> ZigNameIndex {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try buildAndOpen(root: rootURL, at: fileURL) })
            }
        }
    }

    private static func buildAndOpen(root rootURL: URL, at fileURL: URL) throws -> ZigNameIndex {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The build writes through a temporary file and a rename, so a handle
        // still mapping the previous file keeps reading its own inode.
        let built = rootURL.path.withCString { root in
            fileURL.path.withCString { fl_index_build(root, $0) }
        }
        guard built >= 0 else { throw ZigFileIndexError.build(code: built) }

        var handle: OpaquePointer?
        let opened = fileURL.path.withCString { fl_index_open($0, &handle) }
        guard opened == 0, let handle else { throw ZigFileIndexError.open(code: opened) }
        return ZigNameIndex(rootURL: rootURL, handle: handle)
    }

    /// The best `limit` files and folders for `query`, best first. Hits inside
    /// an application bundle are dropped: ApplicationCatalog already returns
    /// each app as one result. The full engine page is requested so the drop
    /// still leaves `limit` results to return.
    func search(_ query: String, limit: Int) -> [IndexedSearchItem] {
        var hits = [fl_hit](repeating: fl_hit(), count: Self.maxHits)
        let count = query.withCString { fl_search(handle, $0, &hits, UInt32(Self.maxHits)) }
        var path = [CChar](repeating: 0, count: Self.maxPathBytes)
        var items: [IndexedSearchItem] = []
        for hit in hits.prefix(Int(count)) where items.count < limit {
            let length = fl_relative_path(handle, hit.id, &path, UInt32(Self.maxPathBytes))
            guard length > 0,
                  let relativePath = String(
                      validating: path.prefix(Int(length)).map { UInt8(bitPattern: $0) },
                      as: UTF8.self
                  )
            else { continue }
            if FFFIndex.hasApplicationBundleComponent(in: relativePath) { continue }
            let isDirectory = fl_is_dir(handle, hit.id)
            let url = rootURL.appendingPathComponent(relativePath, isDirectory: isDirectory)
            // The index stores names only. A stat per result to fill in date
            // and size would be disk I/O on every keystroke, and the result
            // row already hides a zero size.
            items.append(IndexedSearchItem(
                name: url.lastPathComponent,
                relativePath: relativePath,
                url: url,
                isDirectory: isDirectory,
                score: Int(hit.score),
                modified: 0,
                size: 0
            ))
        }
        return items
    }
}
