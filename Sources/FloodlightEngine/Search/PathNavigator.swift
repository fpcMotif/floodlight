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

package enum PathNavigator {
    package static func resolve(
        query: String,
        rootURL: URL? = nil,
        homeURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> ResolvedPath? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let isPathSyntax = trimmed.hasPrefix("~") || trimmed.hasPrefix("/") || trimmed.contains("/")
        guard isPathSyntax else { return nil }

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
        } else if path.hasPrefix(homePath) {
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
