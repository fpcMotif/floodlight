import Foundation

package struct ResolvedPath: Equatable, Sendable {
    // periphery:ignore - in-progress path navigation feature
    package let directoryURL: URL
    package let folderItem: SearchItem
    // periphery:ignore - in-progress path navigation feature
    package let remainder: String

    package init(directoryURL: URL, folderItem: SearchItem, remainder: String = "") {
        self.directoryURL = directoryURL
        self.folderItem = folderItem
        self.remainder = remainder
    }
}

/// The filesystem half of deep path navigation, behind a seam.
///
/// `PathNavigator.resolve` lists directories and stats candidates
/// synchronously. Result Projection used to call it directly, which put that
/// I/O on the main actor once per projection — about four times per
/// keystroke for the same query. Going through this protocol lets the
/// coordinator resolve a query once, off the main actor, and lets a test
/// count what a query costs by handing over a file system it owns.
package protocol PathResolving: Sendable {
    func resolve(query: String, rootURL: URL?) async -> ResolvedPath?
}

package struct FileSystemPathResolver: PathResolving {
    private let makeFileManager: @Sendable () -> FileManager
    private let homeURL: URL?

    /// A `FileManager` factory rather than an instance: resolution runs on
    /// whatever executor `@concurrent` lands it on, and a `FileManager` is
    /// only safe to use from one of those at a time. Each resolution makes
    /// one, uses it, and drops it.
    package init(
        fileManager: @escaping @Sendable () -> FileManager = { FileManager() },
        homeURL: URL? = nil
    ) {
        makeFileManager = fileManager
        self.homeURL = homeURL
    }

    /// `@concurrent` is deliberate. Under approachable concurrency a plain
    /// nonisolated async method inherits its caller's actor, which here is
    /// the main actor — exactly the thread this work exists to leave. The
    /// call stays in the caller's task, so cancellation still applies.
    @concurrent
    package func resolve(query: String, rootURL: URL?) async -> ResolvedPath? {
        PathNavigator.resolve(
            query: query,
            rootURL: rootURL,
            homeURL: homeURL,
            fileManager: makeFileManager()
        )
    }
}

package enum PathNavigator {
    /// Whether a query could name a path at all — a pure string test, no
    /// filesystem.
    ///
    /// The cheap half of `resolve`, exposed so a caller can decline to hop off
    /// the main actor for a query that provably resolves to nothing. `resolve`
    /// still applies it, and still re-applies it to the trimmed query below:
    /// the two are not the same test, and " ~Projects" depends on the
    /// difference.
    package static func hasPathSyntax(_ query: String) -> Bool {
        query.contains("/") || query.hasPrefix("~")
    }

    package static func resolve(
        query: String,
        rootURL: URL? = nil,
        homeURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> ResolvedPath? {
        guard !query.isEmpty else { return nil }
        guard hasPathSyntax(query) else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard hasPathSyntax(trimmed) else { return nil }

        let home = homeURL?.standardizedFileURL ?? fileManager.homeDirectoryForCurrentUser
            .standardizedFileURL
        let candidatePaths = generateCandidatePaths(
            from: trimmed,
            rootURL: rootURL?.standardizedFileURL,
            homeURL: home,
            fileManager: fileManager
        )

        for (url, remainder) in candidatePaths {
            var isDir: ObjCBool = false
            if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let name = url.lastPathComponent
                let displayName = name.isEmpty || name == "/" ? "Home" : name
                let folderItem = SearchItem(
                    id: "folder:\(url.path)",
                    title: "\(displayName)/",
                    subtitle: formatPathSubtitle(url, homeURL: home),
                    kind: .folder,
                    action: .open(url),
                    score: SearchItemRanking.pathNavigation,
                    fileURL: url
                )
                return ResolvedPath(directoryURL: url, folderItem: folderItem, remainder: remainder)
            }
        }

        return nil
    }

    private static func formatPathSubtitle(_ url: URL, homeURL: URL) -> String {
        let path = url.path
        let homePath = homeURL.path
        if path == homePath {
            return "~/"
        }
        if path.hasPrefix(homePath) {
            return "~" + path.dropFirst(homePath.count)
        }
        return path
    }

    private static func generateCandidatePaths(
        from query: String,
        rootURL: URL?,
        homeURL: URL,
        fileManager: FileManager
    ) -> [(URL, remainder: String)] {
        var results: [(URL, remainder: String)] = []

        if query == "~" || query == "~/" {
            return [(homeURL, "")]
        }
        if query.hasPrefix("~/") {
            let subpath = String(query.dropFirst(2))
            let (dirPart, remainder) = splitDirectoryAndRemainder(subpath)
            let cleanDir = dirPart.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fullURL = cleanDir.isEmpty ? homeURL : homeURL.appendingPathComponent(cleanDir)
            results.append((fullURL, remainder))
            if !remainder.isEmpty {
                let fullPath = subpath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                results.append((homeURL.appendingPathComponent(fullPath), ""))
            }
            return results
        }

        if query.hasPrefix("/") {
            let clean = String(query.dropFirst())
            let (dirPart, remainder) = splitDirectoryAndRemainder(clean)
            let fullURL = URL(fileURLWithPath: "/" + dirPart)
            results.append((fullURL, remainder))
            if !remainder.isEmpty {
                results.append((
                    URL(fileURLWithPath: "/" + clean
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
                    ""
                ))
            }
            return results
        }

        let (dirPart, remainder) = splitDirectoryAndRemainder(query)
        let cleanDir = dirPart.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let rootURL {
            if let caseInsensitiveURL = findCaseInsensitiveMatch(
                name: cleanDir,
                under: rootURL,
                fileManager: fileManager
            ) {
                results.append((caseInsensitiveURL, remainder))
            } else {
                results.append((rootURL.appendingPathComponent(cleanDir), remainder))
            }
        }

        if let caseInsensitiveHomeURL = findCaseInsensitiveMatch(
            name: cleanDir,
            under: homeURL,
            fileManager: fileManager
        ) {
            results.append((caseInsensitiveHomeURL, remainder))
        } else {
            results.append((homeURL.appendingPathComponent(cleanDir), remainder))
        }

        return results
    }

    private static func splitDirectoryAndRemainder(_ path: String)
        -> (dirPart: String, remainder: String)
    {
        if path.hasSuffix("/") {
            return (String(path.dropLast()), "")
        }
        if let lastSlash = path.lastIndex(of: "/") {
            let dir = String(path[..<lastSlash])
            let remainder = String(path[path.index(after: lastSlash)...])
            return (dir, remainder)
        }
        return (path, "")
    }

    private static func findCaseInsensitiveMatch(
        name: String,
        under parent: URL,
        fileManager: FileManager
    ) -> URL? {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: parent.path)
        else {
            return nil
        }
        let lower = name.lowercased()
        if let match = contents.first(where: { $0.lowercased() == lower }) {
            return parent.appendingPathComponent(match)
        }
        return nil
    }
}
