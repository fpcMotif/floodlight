import FloodlightEngine
import Foundation

/// Builders for the values the search pipeline moves around, plus
/// generators that produce them randomly.
///
/// Every existing test file rolls its own `makeApplication`/`makeSetting`
/// helpers; these are the shared versions, so a property test and a
/// hand-written example test are provably talking about the same shapes.
package enum SearchFixtures {
    package static func application(
        id: String? = nil,
        name: String,
        score: Int = SearchItemRanking.application,
        directory: String = "/Applications"
    ) -> SearchItem {
        let url = URL(fileURLWithPath: "\(directory)/\(name).app", isDirectory: true)
        return SearchItem(
            id: id ?? "application:\(url.path)",
            title: name,
            subtitle: directory,
            kind: .application,
            action: .open(url),
            score: score,
            fileURL: url
        )
    }

    package static func file(
        id: String? = nil,
        name: String,
        score: Int = SearchItemRanking.content,
        directory: String = "/Users/example/code",
        modifiedAt: Date? = nil,
        fileSize: UInt64? = nil
    ) -> SearchItem {
        let url = URL(fileURLWithPath: "\(directory)/\(name)")
        return SearchItem(
            id: id ?? "file:\(url.path)",
            title: name,
            subtitle: url.deletingLastPathComponent().lastPathComponent + "/" + name,
            kind: .file,
            action: .open(url),
            score: score,
            fileURL: url,
            modifiedAt: modifiedAt,
            fileSize: fileSize
        )
    }

    package static func folder(
        id: String? = nil,
        name: String,
        score: Int = SearchItemRanking.content,
        directory: String = "/Users/example"
    ) -> SearchItem {
        let url = URL(fileURLWithPath: "\(directory)/\(name)", isDirectory: true)
        return SearchItem(
            id: id ?? "folder:\(url.path)",
            title: name,
            subtitle: name,
            kind: .folder,
            action: .open(url),
            score: score,
            fileURL: url
        )
    }

    package static func setting(
        id: String? = nil,
        title: String,
        score: Int = SearchItemRanking.setting
    ) -> SearchItem {
        SearchItem(
            id: id ?? "setting:com.apple.\(title)",
            title: title,
            subtitle: "System Settings",
            kind: .systemSetting,
            action: .open(
                URL(string: "x-apple.systempreferences:com.apple.test")
                    ?? URL(fileURLWithPath: "/")
            ),
            score: score
        )
    }

    package static func web(
        id: String = "web-search",
        query: String = "example",
        score: Int = Int.min
    ) -> SearchItem {
        SearchItem(
            id: id,
            title: "Search the Web for “\(query)”",
            subtitle: "Open in your default browser",
            kind: .web,
            action: .open(
                URL(string: "https://www.google.com/search?q=example")
                    ?? URL(fileURLWithPath: "/")
            ),
            score: score
        )
    }

    package static func calculator(answer: String = "144") -> SearchItem {
        SearchItem(
            id: "calculator",
            title: answer,
            subtitle: "12 * 12 = \(answer) · Press Return to copy",
            kind: .calculator,
            action: .copy(answer),
            score: SearchItemRanking.calculator
        )
    }

    package static func assistant(
        id: String = "keyword-engine:claude",
        command: String = "claude",
        arguments: [String] = ["-p", "explain"]
    ) -> SearchItem {
        SearchItem(
            id: id,
            title: "Ask Claude: explain",
            subtitle: "Press Return to ask",
            kind: .assistant,
            action: .askAssistant(command: command, arguments: arguments),
            score: SearchItemRanking.keywordEngine
        )
    }
}

// MARK: - Generators over the search model

package enum SearchGenerators {
    package static let kind = Gen<SearchItemKind>.element(of: [
        .application, .assistant, .calculator, .file, .folder, .systemSetting, .web,
    ])

    package static let filter = Gen<SearchResultFilter>.element(
        of: SearchResultFilter.allCases
    )

    package static let fileExtension = Gen<String>.element(
        of: AdversarialCorpus.fileExtensions
    )

    /// Scores spanning every published band plus the extremes, so ranking
    /// properties get exercised at `Int.min` (the web fallback's real
    /// value) as well as in the ordinary middle.
    package static let score = Gen<Int>.frequency([
        (6, .int(in: -5_000...250_000)),
        (2, .element(of: [
            SearchItemRanking.keywordEngine,
            SearchItemRanking.calculator,
            SearchItemRanking.application,
            SearchItemRanking.setting,
            SearchItemRanking.content,
            SearchItemRanking.webPromoted,
        ])),
        (1, .element(of: [Int.min, Int.max, 0, -1, 1])),
    ])

    /// A `SearchItem` whose kind, extension, and score vary independently,
    /// with a unique-per-value identifier so a generated array can be fed
    /// to code that de-duplicates by ID without collapsing.
    package static func item(uniqueSuffix: Bool = true) -> Gen<SearchItem> {
        Gen<SearchItem>(
            generate: { rng in
                let itemKind = kind.generate(&rng)
                let itemScore = score.generate(&rng)
                let ext = fileExtension.generate(&rng)
                let name = Gen<String>.lowercaseASCII.generate(&rng)
                let discriminator = uniqueSuffix
                    ? String(UInt64.random(in: 0...UInt64.max, using: &rng), radix: 36)
                    : ""
                let base = name.isEmpty ? "item" : name
                let fileName = ext.isEmpty ? base : "\(base).\(ext)"
                let url = URL(fileURLWithPath: "/tmp/floodlight/\(discriminator)/\(fileName)")
                return SearchItem(
                    id: "\(itemKind.rawValue):\(discriminator):\(fileName)",
                    title: base,
                    subtitle: url.path,
                    kind: itemKind,
                    action: .open(url),
                    score: itemScore,
                    fileURL: itemKind == .file || itemKind == .folder || itemKind == .application
                        ? url
                        : nil
                )
            }
        )
    }

    package static func items(count: ClosedRange<Int> = 0...40) -> Gen<[SearchItem]> {
        Gen<SearchItem>.array(of: item(), count: count)
    }
}

// MARK: - Filesystem and defaults scaffolding

/// A temporary directory that deletes itself, with helpers for building the
/// small file trees the index and catalog tests need.
package final class TemporaryTree {
    package let root: URL
    private let fileManager = FileManager.default

    package init(label: String = "FloodlightTests") throws {
        // `realpath` first: on macOS the temporary directory lives behind
        // the `/var` → `/private/var` symlink, and the FFF index derives
        // every result's relative path from the root it was handed. Given
        // the unresolved spelling it walks real paths that no longer sit
        // under that root, and quietly returns nothing.
        root = Self.canonical(FileManager.default.temporaryDirectory)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    package static func canonical(_ url: URL) -> URL {
        let resolved = url.path.withCString { path -> String? in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard let resolved else { return url.standardizedFileURL }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    deinit {
        try? fileManager.removeItem(at: root)
    }

    @discardableResult
    package func makeFile(_ relativePath: String, contents: String = "") throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    package func makeDirectory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    package func remove() {
        try? fileManager.removeItem(at: root)
    }
}

/// An isolated `UserDefaults` suite that removes its persistent domain on
/// teardown, so a store test can never leak into `.standard` or into the
/// next test's expectations.
package final class IsolatedDefaults: @unchecked Sendable {
    package let suiteName: String
    package let defaults: UserDefaults

    package init(label: String = "FloodlightTests") throws {
        suiteName = "\(label)-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw IsolatedDefaultsError.couldNotCreateSuite(suiteName)
        }
        self.defaults = defaults
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

package enum IsolatedDefaultsError: LocalizedError {
    case couldNotCreateSuite(String)

    package var errorDescription: String? {
        switch self {
        case let .couldNotCreateSuite(name):
            "Could not create an isolated UserDefaults suite named \(name)"
        }
    }
}
