import CFFF
import Darwin
import Foundation

enum FFFIndexError: LocalizedError {
    case invalidResult
    case message(String)

    var errorDescription: String? {
        switch self {
        case .invalidResult:
            "FFF returned an invalid result."
        case .message(let message):
            message
        }
    }
}

final class FFFIndex: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.floodlight.fff", qos: .userInitiated)
    private let searchGenerationLock = NSLock()
    private var latestSearchGeneration: UInt64 = 0
    private var handle: UnsafeMutableRawPointer?
    private var rootURL: URL
    private let homeURL: URL
    private let storageURL: URL?
    private let enableContentIndexing: Bool
    private let includeBinaryFiles: Bool
    private let watch: Bool

    init(
        rootURL: URL,
        storageURL: URL? = nil,
        enableContentIndexing: Bool = true,
        includeBinaryFiles: Bool = true,
        watch: Bool = true,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        // FSEvents reports canonical paths. Resolve symlinked scopes up front
        // so watcher events (notably /var -> /private/var) map back into the
        // same path space as the initial index.
        self.rootURL = Self.canonicalFileURL(rootURL)
        self.homeURL = Self.canonicalFileURL(homeURL)
        self.storageURL = storageURL
        self.enableContentIndexing = enableContentIndexing
        self.includeBinaryFiles = includeBinaryFiles
        self.watch = watch
    }

    deinit {
        if let handle {
            fff_destroy(handle)
        }
    }

    func start() async throws {
        try await perform {
            guard self.handle == nil else { return }

            let fileManager = FileManager.default
            let supportURL = try self.storageURL ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("Floodlight", isDirectory: true)
            try fileManager.createDirectory(at: supportURL, withIntermediateDirectories: true)

            let frecencyPath = supportURL.appendingPathComponent("frecency.lmdb").path
            let historyPath = supportURL.appendingPathComponent("history.lmdb").path
            let environment = ProcessInfo.processInfo.environment
            let logPath = environment["FLOODLIGHT_FFF_LOG"]
            let logLevel = environment["FLOODLIGHT_FFF_LOG_LEVEL"] ?? "info"

            let envelope = Self.withOptionalCString(logPath) { logFile in
                logLevel.withCString { logLevel in
                    self.rootURL.path.withCString { root in
                        frecencyPath.withCString { frecency in
                            historyPath.withCString { history in
                                fff_create_instance3(
                                    root,
                                    frecency,
                                    history,
                                    false,
                                    true,
                                    self.enableContentIndexing,
                                    self.watch,
                                    false,
                                    self.includeBinaryFiles,
                                    logFile,
                                    logFile == nil ? nil : logLevel,
                                    0,
                                    0,
                                    0
                                )
                            }
                        }
                    }
                }
            }

            self.handle = try Self.takeHandle(from: envelope)
        }
    }

    func search(_ query: String, limit: UInt32 = 60) async throws -> [IndexedSearchItem] {
        let requestGeneration = reserveSearchGeneration()
        return try await perform {
            guard self.isLatestSearch(requestGeneration) else {
                throw CancellationError()
            }
            guard let handle = self.handle else {
                throw FFFIndexError.message("The FFF index has not started.")
            }

            let resolvedQuery = Self.resolvePathQuery(
                query,
                rootURL: self.rootURL,
                homeURL: self.homeURL
            )
            if resolvedQuery.fffQuery.isEmpty,
               let exactItem = Self.exactPathItem(
                   at: resolvedQuery.exactURL,
                   rootURL: self.rootURL
               ) {
                return [exactItem]
            }

            let envelope = resolvedQuery.fffQuery.withCString {
                fff_search_mixed(handle, $0, nil, 0, 0, limit, 100, 3)
            }
            guard let envelope else { throw FFFIndexError.invalidResult }
            defer { fff_free_result(envelope) }

            guard envelope.pointee.success else {
                throw FFFIndexError.message(Self.errorMessage(from: envelope))
            }
            guard let raw = envelope.pointee.handle else { return [] }

            let result = raw.assumingMemoryBound(to: FffMixedSearchResult.self)
            defer { fff_free_mixed_search_result(result) }

            var items: [IndexedSearchItem] = (0..<result.pointee.count).compactMap { index in
                guard let item = fff_mixed_search_result_get_item(result, index),
                      let namePointer = item.pointee.display_name,
                      let pathPointer = item.pointee.relative_path else {
                    return nil
                }

                let name = String(cString: namePointer)
                let relativePath = String(cString: pathPointer)

                // Application bundles are provided by ApplicationCatalog as one result.
                let components = relativePath.split(separator: "/")
                if components.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) {
                    return nil
                }

                let scorePointer = fff_mixed_search_result_get_score(result, index)
                let score = Int(scorePointer?.pointee.total ?? 0)
                let isDirectory = item.pointee.item_type == 1
                let url = self.rootURL.appendingPathComponent(relativePath, isDirectory: isDirectory)

                return IndexedSearchItem(
                    name: name,
                    relativePath: relativePath,
                    url: url,
                    isDirectory: isDirectory,
                    score: score,
                    modified: item.pointee.modified,
                    size: item.pointee.size
                )
            }

            if let exactItem = Self.exactPathItem(
                at: resolvedQuery.exactURL,
                rootURL: self.rootURL
            ) {
                items.removeAll { $0.url.standardizedFileURL == exactItem.url.standardizedFileURL }
                items.insert(exactItem, at: 0)
            }

            return Array(items.prefix(Int(limit)))
        }
    }

    func searchFiles(_ query: String, limit: UInt32 = 60) async throws -> [IndexedSearchItem] {
        let requestGeneration = reserveSearchGeneration()
        return try await perform {
            guard self.isLatestSearch(requestGeneration) else {
                throw CancellationError()
            }
            guard let handle = self.handle else {
                throw FFFIndexError.message("The FFF index has not started.")
            }

            let envelope = query.withCString {
                fff_search(handle, $0, nil, 0, 0, limit, 100, 3)
            }
            guard let envelope else { throw FFFIndexError.invalidResult }
            defer { fff_free_result(envelope) }

            guard envelope.pointee.success else {
                throw FFFIndexError.message(Self.errorMessage(from: envelope))
            }
            guard let raw = envelope.pointee.handle else { return [] }

            let result = raw.assumingMemoryBound(to: FffSearchResult.self)
            defer { fff_free_search_result(result) }

            return (0..<result.pointee.count).compactMap { index in
                guard let item = fff_search_result_get_item(result, index),
                      let namePointer = item.pointee.file_name,
                      let pathPointer = item.pointee.relative_path else {
                    return nil
                }

                let relativePath = String(cString: pathPointer)
                if relativePath.split(separator: "/").dropLast()
                    .contains(where: { $0.lowercased().hasSuffix(".app") }) {
                    return nil
                }

                let scorePointer = fff_search_result_get_score(result, index)
                let url = self.rootURL.appendingPathComponent(relativePath)
                return IndexedSearchItem(
                    name: String(cString: namePointer),
                    relativePath: relativePath,
                    url: url,
                    isDirectory: false,
                    score: Int(scorePointer?.pointee.total ?? 0),
                    modified: item.pointee.modified,
                    size: item.pointee.size
                )
            }
        }
    }

    func searchDirectories(
        _ query: String,
        limit: UInt32 = 24
    ) async throws -> [IndexedSearchItem] {
        let requestGeneration = reserveSearchGeneration()
        return try await perform {
            guard self.isLatestSearch(requestGeneration) else {
                throw CancellationError()
            }
            guard let handle = self.handle else {
                throw FFFIndexError.message("The FFF index has not started.")
            }

            let envelope = query.withCString {
                fff_search_directories(handle, $0, nil, 0, 0, limit)
            }
            guard let envelope else { throw FFFIndexError.invalidResult }
            defer { fff_free_result(envelope) }

            guard envelope.pointee.success else {
                throw FFFIndexError.message(Self.errorMessage(from: envelope))
            }
            guard let raw = envelope.pointee.handle else { return [] }

            let result = raw.assumingMemoryBound(to: FffDirSearchResult.self)
            defer { fff_free_dir_search_result(result) }

            return (0..<result.pointee.count).compactMap { index in
                guard let item = fff_dir_search_result_get_item(result, index),
                      let namePointer = item.pointee.dir_name,
                      let pathPointer = item.pointee.relative_path else {
                    return nil
                }

                let relativePath = String(cString: pathPointer)
                if relativePath.split(separator: "/")
                    .contains(where: { $0.lowercased().hasSuffix(".app") }) {
                    return nil
                }

                let scorePointer = fff_dir_search_result_get_score(result, index)
                return IndexedSearchItem(
                    name: String(cString: namePointer),
                    relativePath: relativePath,
                    url: self.rootURL.appendingPathComponent(
                        relativePath,
                        isDirectory: true
                    ),
                    isDirectory: true,
                    score: Int(scorePointer?.pointee.total ?? 0),
                    modified: 0,
                    size: 0
                )
            }
        }
    }

    private func reserveSearchGeneration() -> UInt64 {
        searchGenerationLock.lock()
        defer { searchGenerationLock.unlock() }
        latestSearchGeneration &+= 1
        return latestSearchGeneration
    }

    private func isLatestSearch(_ generation: UInt64) -> Bool {
        searchGenerationLock.lock()
        defer { searchGenerationLock.unlock() }
        return generation == latestSearchGeneration
    }

    func progress() async throws -> IndexProgress {
        try await perform {
            guard let handle = self.handle else {
                throw FFFIndexError.message("The FFF index has not started.")
            }

            let envelope = fff_get_scan_progress(handle)
            guard let envelope else { throw FFFIndexError.invalidResult }
            defer { fff_free_result(envelope) }

            guard envelope.pointee.success else {
                throw FFFIndexError.message(Self.errorMessage(from: envelope))
            }
            guard let raw = envelope.pointee.handle else { throw FFFIndexError.invalidResult }

            let progress = raw.assumingMemoryBound(to: FffScanProgress.self)
            defer { fff_free_scan_progress(progress) }
            return IndexProgress(
                scannedFiles: progress.pointee.scanned_files_count,
                isScanning: progress.pointee.is_scanning,
                isWatcherReady: progress.pointee.is_watcher_ready
            )
        }
    }

    func searchContent(
        _ query: String,
        limit: UInt32 = 16,
        timeBudgetMilliseconds: UInt64 = 35
    ) async throws -> [IndexedContentItem] {
        try await perform {
            guard let handle = self.handle else {
                throw FFFIndexError.message("The FFF index has not started.")
            }
            guard !query.isEmpty else { return [] }

            let envelope = query.withCString {
                fff_live_grep(
                    handle,
                    $0,
                    0,
                    10 * 1_024 * 1_024,
                    1,
                    true,
                    0,
                    limit,
                    timeBudgetMilliseconds,
                    0,
                    0,
                    false
                )
            }
            guard let envelope else { throw FFFIndexError.invalidResult }
            defer { fff_free_result(envelope) }

            guard envelope.pointee.success else {
                throw FFFIndexError.message(Self.errorMessage(from: envelope))
            }
            guard let raw = envelope.pointee.handle else { return [] }

            let result = raw.assumingMemoryBound(to: FffGrepResult.self)
            defer { fff_free_grep_result(result) }

            return (0..<fff_grep_result_get_count(result)).compactMap { index in
                guard let match = fff_grep_result_get_match(result, index),
                      let pathPointer = fff_grep_match_get_relative_path(match),
                      let namePointer = fff_grep_match_get_file_name(match),
                      let contentPointer = fff_grep_match_get_line_content(match) else {
                    return nil
                }

                let relativePath = String(cString: pathPointer)
                if relativePath.split(separator: "/").dropLast()
                    .contains(where: { $0.lowercased().hasSuffix(".app") }) {
                    return nil
                }

                let snippet = String(cString: contentPointer)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return IndexedContentItem(
                    name: String(cString: namePointer),
                    relativePath: relativePath,
                    url: self.rootURL.appendingPathComponent(relativePath),
                    line: fff_grep_match_get_line_number(match),
                    snippet: snippet
                )
            }
        }
    }

    func rescan() async throws {
        try await perform {
            guard let handle = self.handle else {
                throw FFFIndexError.message("The FFF index has not started.")
            }
            try Self.requireSuccess(fff_scan_files(handle))
        }
    }

    func changeRoot(to url: URL) async throws {
        try await perform {
            let standardized = Self.canonicalFileURL(url)
            guard let handle = self.handle else {
                // Onboarding can choose the scope before the first scan starts.
                // `start()` will create FFF with this canonical root.
                self.rootURL = standardized
                return
            }
            try standardized.path.withCString {
                try Self.requireSuccess(fff_restart_index(handle, $0))
            }
            self.rootURL = standardized
        }
    }

    func track(query: String, selectedURL: URL) {
        queue.async {
            guard let handle = self.handle,
                  selectedURL.path.hasPrefix(self.rootURL.path) else {
                return
            }
            let envelope = query.withCString { queryPointer in
                selectedURL.path.withCString { pathPointer in
                    fff_track_query(handle, queryPointer, pathPointer)
                }
            }
            if let envelope {
                fff_free_result(envelope)
            }
        }
    }

    private func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func requireSuccess(_ envelope: UnsafeMutablePointer<FffResult>?) throws {
        guard let envelope else { throw FFFIndexError.invalidResult }
        defer { fff_free_result(envelope) }
        guard envelope.pointee.success else {
            throw FFFIndexError.message(errorMessage(from: envelope))
        }
    }

    private static func withOptionalCString<Result>(
        _ value: String?,
        _ body: (UnsafePointer<CChar>?) -> Result
    ) -> Result {
        guard let value else { return body(nil) }
        return value.withCString(body)
    }

    private static func canonicalFileURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        let resolvedPath = standardized.path.withCString { path -> String? in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard let resolvedPath else { return standardized }
        return URL(fileURLWithPath: resolvedPath, isDirectory: standardized.hasDirectoryPath)
    }

    private struct ResolvedPathQuery {
        let fffQuery: String
        let exactURL: URL?
    }

    /// Converts shell-style home paths into the relative path space used by FFF.
    /// It also records exact path-like queries so a matching folder cannot be
    /// crowded out of a mixed result page by files with similar names.
    private static func resolvePathQuery(
        _ query: String,
        rootURL: URL,
        homeURL: URL
    ) -> ResolvedPathQuery {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepsDirectorySuffix = trimmed.hasSuffix("/")

        let candidate: URL?
        let requiresTranslation: Bool
        if trimmed == "~" || trimmed == "~/" {
            candidate = homeURL
            requiresTranslation = true
        } else if trimmed.hasPrefix("~/") {
            candidate = homeURL.appendingPathComponent(String(trimmed.dropFirst(2)))
            requiresTranslation = true
        } else if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed)
            requiresTranslation = true
        } else if trimmed.contains("/") {
            candidate = rootURL.appendingPathComponent(trimmed)
            requiresTranslation = false
        } else {
            candidate = nil
            requiresTranslation = false
        }

        guard let candidate else {
            return ResolvedPathQuery(fffQuery: trimmed, exactURL: nil)
        }

        let standardizedCandidate = candidate.standardizedFileURL
        guard let relativePath = relativePath(of: standardizedCandidate, within: rootURL) else {
            return ResolvedPathQuery(fffQuery: trimmed, exactURL: nil)
        }

        var fffQuery = requiresTranslation ? relativePath : trimmed
        if requiresTranslation, keepsDirectorySuffix, !fffQuery.isEmpty {
            fffQuery += "/"
        }
        return ResolvedPathQuery(fffQuery: fffQuery, exactURL: standardizedCandidate)
    }

    private static func exactPathItem(at url: URL?, rootURL: URL) -> IndexedSearchItem? {
        guard let url,
              let relativePath = relativePath(of: url, within: rootURL) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }

        let components = relativePath.split(separator: "/")
        if components.dropLast().contains(where: { $0.lowercased().hasSuffix(".app") }) {
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes?[.modificationDate] as? Date).map {
            UInt64(max(0, $0.timeIntervalSince1970))
        } ?? 0
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0

        return IndexedSearchItem(
            name: url.lastPathComponent,
            relativePath: relativePath,
            url: url,
            isDirectory: isDirectory.boolValue,
            // An explicitly typed path should rank above fuzzy matches.
            score: 300_000,
            modified: modified,
            size: size
        )
    }

    private static func relativePath(of url: URL, within rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        if candidatePath == rootPath {
            return ""
        }

        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard candidatePath.hasPrefix(prefix) else { return nil }
        return String(candidatePath.dropFirst(prefix.count))
    }

    private static func takeHandle(
        from envelope: UnsafeMutablePointer<FffResult>?
    ) throws -> UnsafeMutableRawPointer {
        guard let envelope else { throw FFFIndexError.invalidResult }
        defer { fff_free_result(envelope) }
        guard envelope.pointee.success else {
            throw FFFIndexError.message(errorMessage(from: envelope))
        }
        guard let handle = envelope.pointee.handle else { throw FFFIndexError.invalidResult }
        return handle
    }

    private static func errorMessage(from envelope: UnsafeMutablePointer<FffResult>) -> String {
        guard let pointer = envelope.pointee.error else { return "Unknown FFF error." }
        return String(cString: pointer)
    }
}
