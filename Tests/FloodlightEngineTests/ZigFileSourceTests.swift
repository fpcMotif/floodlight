import FloodlightTestSupport
import Foundation
import Testing
@testable import FloodlightEngine

/// The FFFFileSource lifecycle tests in FFFIndexTests, run against the Zig
/// index through the same `FileSource` seam: each operation returns only once
/// a query can see its result.
struct ZigFileSourceTests {
    @Test func startReturnsWithASearchableInitialSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.createFiles(count: 4_000, in: fixture.root)
        let sentinel = try fixture.write("ready-source-sentinel.txt", in: fixture.root)

        let source = fixture.source(rootURL: fixture.root)
        try await source.start()

        let results = try await source.indexedItems(for: "ready-source-sentinel", limit: 12)
        #expect(results.contains { $0.fileURL == sentinel })
    }

    @Test func scopeChangeReturnsWithTheNewSnapshotSearchable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.directory("Original")
        let selected = try fixture.directory("Selected")
        fixture.createFiles(count: 4_000, in: selected)
        let sentinel = try fixture.write("ready-scope-sentinel.txt", in: selected)

        let content = ScriptedFileSource()
        let source = fixture.source(rootURL: original, content: content)
        try await source.start()
        try await source.changeScope(to: selected)

        let results = try await source.indexedItems(for: "ready-scope-sentinel", limit: 12)
        #expect(results.contains { $0.fileURL == sentinel })
        #expect(content.lifecycle == ["start", "scope"])
    }

    @Test func rebuildReturnsWithTheUpdatedSnapshotSearchable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let content = ScriptedFileSource()
        let source = fixture.source(rootURL: fixture.root, content: content)
        try await source.start()

        fixture.createFiles(count: 4_000, in: fixture.root)
        let sentinel = try fixture.write("ready-rebuild-sentinel.txt", in: fixture.root)
        try await source.rebuild()

        let results = try await source.indexedItems(for: "ready-rebuild-sentinel", limit: 12)
        #expect(results.contains { $0.fileURL == sentinel })
        #expect(content.lifecycle == ["start", "rebuild"])
    }

    @Test func canChooseScopeBeforeInitialIndexStarts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.directory("Original")
        let selected = try fixture.directory("Selected")
        let selectedFile = try fixture.write("onboarding-scope-result.txt", in: selected)

        let source = fixture.source(rootURL: original)
        try await source.changeScope(to: selected)
        try await source.start()

        let results = try await source.indexedItems(for: "onboarding-scope-result", limit: 12)
        #expect(results.contains { $0.fileURL == selectedFile })
    }

    @Test func failedScopeChangeKeepsThePreviousIndexSearchable() async throws {
        enum Failure: Error { case expected }
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.directory("Original")
        let selected = try fixture.directory("Selected")
        let kept = try fixture.write("kept-scope-sentinel.txt", in: original)

        let source = fixture.source(
            rootURL: original,
            content: ScriptedFileSource(changeScopeError: Failure.expected)
        )
        try await source.start()
        await #expect(throws: Failure.self) { try await source.changeScope(to: selected) }

        let results = try await source.indexedItems(for: "kept-scope-sentinel", limit: 12)
        #expect(results.contains { $0.fileURL == kept })
    }

    @Test func returnsFoldersAndFilesButNotApplicationBundleContents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let projects = try fixture.directory("Projects")
        let notes = try fixture.write("needle-design-notes.md", in: projects)
        let bundle = try fixture.directory("Needle Launcher.app")
        let executable = try fixture.write("needle-launcher", in: bundle)

        let source = fixture.source(rootURL: fixture.root)
        try await source.start()

        let files = try await source.indexedItems(for: "needle", limit: 12)
        #expect(files.contains { $0.fileURL == notes && $0.kind == .file })
        #expect(files.contains { $0.fileURL == bundle && $0.kind == .application })
        #expect(!files.contains { $0.fileURL == executable })

        let folders = try await source.indexedItems(for: "projects", limit: 12)
        #expect(folders.contains { $0.title == "Projects/" && $0.kind == .folder })
    }

    @Test func contentSearchAndSelectionTrackingStayOnTheWrappedSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let match = SearchItem(
            id: "content:match",
            title: "match.txt",
            subtitle: "match.txt:1 · needle",
            kind: .file,
            action: .open(fixture.root),
            score: SearchItemRanking.content
        )
        let content = ScriptedFileSource(content: [match])
        let source = fixture.source(rootURL: fixture.root, content: content)
        try await source.start()

        let results = try await source.contentItems(for: "needle")
        source.track(query: "needle", selectedURL: fixture.root)

        #expect(results == [match])
        #expect(content.tracked.map(\.url) == [fixture.root])
    }

    @Test func contentSearchStillRunsOnFFFGrep() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = try fixture.write(
            "grep-target.txt",
            in: fixture.root,
            contents: "zig-content-probe"
        )

        let source = ZigFileSource(
            content: FFFFileSource(
                index: FFFIndex(rootURL: fixture.root, storageURL: fixture.storage, watch: false),
                rootURL: fixture.root
            ),
            rootURL: fixture.root,
            storageURL: fixture.storage
        )
        try await source.start()

        let results = try await source.contentItems(for: "zig-content-probe")
        #expect(results.contains { $0.fileURL?.lastPathComponent == file.lastPathComponent })
    }
}

/// A scratch folder outside the scanned root for the index file, so a build
/// never indexes its own output.
private struct Fixture {
    let parent: URL
    let root: URL
    let storage: URL
    private let fileManager = FileManager.default

    init() throws {
        parent = FFFIndex.canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent("FloodlightZigSourceTests-\(UUID().uuidString)")
        root = parent.appendingPathComponent("Root", isDirectory: true)
        storage = parent.appendingPathComponent("Storage", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func source(
        rootURL: URL,
        content: any FileSource = ScriptedFileSource()
    ) -> ZigFileSource {
        ZigFileSource(content: content, rootURL: rootURL, storageURL: storage)
    }

    func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ name: String, in directory: URL, contents: String = "ready") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func createFiles(count: Int, in directory: URL) {
        for index in 0..<count {
            fileManager.createFile(
                atPath: directory.appendingPathComponent("fixture-\(index).txt").path,
                contents: Data()
            )
        }
    }

    func remove() {
        try? fileManager.removeItem(at: parent)
    }
}
