import Darwin
import Foundation
import Testing
@testable import FloodlightEngine

struct FFFIndexTests {
    @Test func fileSourceStartReturnsWithASearchableInitialSnapshot() async throws {
        let fileManager = FileManager.default
        let root = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent("FloodlightReadySourceTests-\(UUID().uuidString)")
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        createFixtureFiles(count: 4_000, in: root, fileManager: fileManager)
        let sentinel = root.appendingPathComponent("ready-source-sentinel.txt")
        try Data("ready".utf8).write(to: sentinel)
        defer { try? fileManager.removeItem(at: root) }

        let source = FFFFileSource(
            index: FFFIndex(
                rootURL: root,
                storageURL: storage,
                enableContentIndexing: false,
                includeBinaryFiles: false,
                watch: false
            ),
            rootURL: root
        )

        try await source.start()

        let results = try await source.indexedItems(for: "ready-source-sentinel", limit: 12)
        #expect(results.contains { $0.fileURL == sentinel })
    }

    @Test func fileSourceScopeChangeReturnsWithTheNewSnapshotSearchable() async throws {
        let fileManager = FileManager.default
        let parent = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent("FloodlightReadyScopeTests-\(UUID().uuidString)")
        let originalRoot = parent.appendingPathComponent("Original", isDirectory: true)
        let selectedRoot = parent.appendingPathComponent("Selected", isDirectory: true)
        let storage = parent.appendingPathComponent("Storage", isDirectory: true)
        try fileManager.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        createFixtureFiles(count: 4_000, in: selectedRoot, fileManager: fileManager)
        let sentinel = selectedRoot.appendingPathComponent("ready-scope-sentinel.txt")
        try Data("ready".utf8).write(to: sentinel)
        defer { try? fileManager.removeItem(at: parent) }

        let source = FFFFileSource(
            index: FFFIndex(
                rootURL: originalRoot,
                storageURL: storage,
                enableContentIndexing: false,
                includeBinaryFiles: false,
                watch: false
            ),
            rootURL: originalRoot
        )
        try await source.start()

        try await source.changeScope(to: selectedRoot)

        let results = try await source.indexedItems(for: "ready-scope-sentinel", limit: 12)
        #expect(results.contains { $0.fileURL == sentinel })
    }

    @Test func fileSourceRebuildReturnsWithTheUpdatedSnapshotSearchable() async throws {
        let fileManager = FileManager.default
        let root = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent("FloodlightReadyRebuildTests-\(UUID().uuidString)")
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let source = FFFFileSource(
            index: FFFIndex(
                rootURL: root,
                storageURL: storage,
                enableContentIndexing: false,
                includeBinaryFiles: false,
                watch: false
            ),
            rootURL: root
        )
        try await source.start()

        createFixtureFiles(count: 4_000, in: root, fileManager: fileManager)
        let sentinel = root.appendingPathComponent("ready-rebuild-sentinel.txt")
        try Data("ready".utf8).write(to: sentinel)
        try await source.rebuild()

        let results = try await source.indexedItems(for: "ready-rebuild-sentinel", limit: 12)
        #expect(results.contains { $0.fileURL == sentinel })
    }

    @Test func canChooseScopeBeforeInitialIndexStarts() async throws {
        let fileManager = FileManager.default
        let parent = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent("FloodlightPreflightScopeTests-\(UUID().uuidString)")
        let originalRoot = parent.appendingPathComponent("Original", isDirectory: true)
        let selectedRoot = parent.appendingPathComponent("Selected", isDirectory: true)
        let selectedFile = selectedRoot.appendingPathComponent("onboarding-scope-result.txt")
        let storage = parent.appendingPathComponent("Storage", isDirectory: true)
        try fileManager.createDirectory(at: originalRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
        try Data("selected before startup".utf8).write(to: selectedFile)
        defer { try? fileManager.removeItem(at: parent) }

        let index = FFFIndex(rootURL: originalRoot, storageURL: storage)
        try await index.changeRoot(to: selectedRoot)
        try await index.start()
        try await assertEventually("The scope selected during onboarding was not indexed") {
            try await index.searchFiles("onboarding-scope-result").contains {
                sameFileURL($0.url, selectedFile)
            }
        }
    }

    @Test func indexesAndSearchesFilesAndFolders() async throws {
        let fileManager = FileManager.default
        let root = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent("FloodlightTests-\(UUID().uuidString)", isDirectory: true)
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        let folder = root.appendingPathComponent("Projects", isDirectory: true)
        let file = folder.appendingPathComponent("needle-design-notes.md")
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let desktop = root.appendingPathComponent("Desktop", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let pdf = downloads.appendingPathComponent("download-guide.pdf")
        let image = desktop.appendingPathComponent("vacation-snapshot.png")
        let document = documents.appendingPathComponent("meeting-brief.txt")
        let downloadedApplication = downloads
            .appendingPathComponent("Sample Launcher.app", isDirectory: true)
        let applicationExecutable = downloadedApplication
            .appendingPathComponent("Contents/MacOS/sample-launcher")
        let ancestorOnlyFolder = root
            .appendingPathComponent("Reference", isDirectory: true)
        let deeplyNestedFile = ancestorOnlyFolder
            .appendingPathComponent("Archive/2026/release-notes.txt")

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: applicationExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: deeplyNestedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("Floodlight integration test".utf8).write(to: file)
        try Data("%PDF-1.7".utf8).write(to: pdf)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try Data("ordinary text remains indexed".utf8).write(to: document)
        try Data("application executable".utf8).write(to: applicationExecutable)
        try Data("nested folder coverage".utf8).write(to: deeplyNestedFile)
        defer { try? fileManager.removeItem(at: root) }

        let index = FFFIndex(rootURL: root, storageURL: storage)
        try await index.start()

        for _ in 0..<100 {
            let progress = try await index.progress()
            if !progress.isScanning { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        let fileResults = try await index.search("needle")
        #expect(fileResults.contains { $0.url.lastPathComponent == file.lastPathComponent })
        let fileOnlyResults = try await index.searchFiles("needle")
        #expect(fileOnlyResults
            .contains { $0.url.lastPathComponent == file.lastPathComponent })
        let hasDirectory = fileOnlyResults.contains(where: \.isDirectory)
        #expect(!hasDirectory)

        let downloadResults = try await index.searchFiles("download-guide")
        #expect(downloadResults.contains { $0.url == pdf })
        let desktopResults = try await index.searchFiles("vacation-snapshot")
        #expect(desktopResults.contains { $0.url == image })
        let documentResults = try await index.searchFiles("meeting-brief")
        #expect(documentResults.contains { $0.url == document })

        let applicationResults = try await index.search("Sample Launcher")
        let application = try #require(applicationResults.first { sameFileURL(
            $0.url,
            downloadedApplication
        ) })
        let applicationSearchItem = application.makeSearchItem()
        #expect(application.isApplicationBundle)
        #expect(applicationSearchItem.kind == .application)
        #expect(applicationSearchItem.title == "Sample Launcher")
        #expect(applicationSearchItem.id == "application:\(downloadedApplication.path)")

        let ancestorResults = try await index.searchDirectories("Reference")
        #expect(ancestorResults.contains { sameFileURL($0.url, ancestorOnlyFolder) })

        let folderResults = try await index.search("Projects")
        #expect(folderResults
            .contains { $0.isDirectory && $0.url.lastPathComponent == "Projects" })
        let directoryOnlyResults = try await index.searchDirectories("Projects")
        #expect(directoryOnlyResults.contains {
            $0.isDirectory && $0.url.lastPathComponent == "Projects"
        })

        let contentResults = try await index.searchContent(
            "integration test",
            timeBudgetMilliseconds: 500
        )
        #expect(contentResults
            .contains { $0.url.lastPathComponent == file.lastPathComponent })
    }

    @Test func exactAndTildePathsKeepDirectoriesVisibleInMixedResults() async throws {
        let fileManager = FileManager.default
        let root = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent(
                "FloodlightPathQueryTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        let code = root.appendingPathComponent("code", isDirectory: true)
        let minion = code.appendingPathComponent("minion", isDirectory: true)
        try fileManager.createDirectory(at: minion, withIntermediateDirectories: true)
        for index in 0..<80 {
            let package = minion.appendingPathComponent("package-\(index)", isDirectory: true)
            try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("export default \(index)".utf8).write(
                to: package.appendingPathComponent("index.ts")
            )
        }
        defer { try? fileManager.removeItem(at: root) }

        let index = FFFIndex(rootURL: root, storageURL: storage, homeURL: root)
        try await index.start()
        try await assertEventually("FFF did not finish the path-query fixture scan") {
            let progress = try await index.progress()
            return !progress.isScanning
        }

        let relativeResults = try await index.search("code/minion", limit: 12)
        #expect(relativeResults.first?.url.standardizedFileURL == minion.standardizedFileURL)
        #expect(relativeResults.first?.isDirectory == true)

        let homeResults = try await index.search("~/code", limit: 12)
        #expect(homeResults.first?.url.standardizedFileURL == code.standardizedFileURL)
        #expect(homeResults.first?.isDirectory == true)

        let directoryOnlyResults = try await index.search("code/minion/", limit: 12)
        let allDirectories = directoryOnlyResults.allSatisfy(\.isDirectory)
        #expect(allDirectories)
    }

    @Test func liveWatcherUpdatesFilesAndFolders() async throws {
        let fileManager = FileManager.default
        let root = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent(
                "FloodlightWatcherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let index = FFFIndex(rootURL: root, storageURL: storage)
        try await index.start()
        try await assertEventually("FFF's live watcher did not become ready") {
            let progress = try await index.progress()
            return !progress.isScanning && progress.isWatcherReady
        }

        let createdFolder = root.appendingPathComponent("Live Projects", isDirectory: true)
        let createdFile = createdFolder.appendingPathComponent("fresh-report.txt")
        try fileManager.createDirectory(at: createdFolder, withIntermediateDirectories: true)
        try Data("new file".utf8).write(to: createdFile)

        try await assertEventually(
            "A created file and its containing folder were not added to the live index"
        ) {
            let files = try await index.searchFiles("fresh-report")
            let folders = try await index.searchDirectories("Live Projects")
            return files.contains { sameFileURL($0.url, createdFile) }
                && folders.contains {
                    sameFileURL($0.url, createdFolder)
                }
        }

        let renamedFile = createdFolder.appendingPathComponent("renamed-report.txt")
        try fileManager.moveItem(at: createdFile, to: renamedFile)
        try await assertEventually("Renaming a file did not replace its path in the live index") {
            let oldResults = try await index.searchFiles("fresh-report")
            let newResults = try await index.searchFiles("renamed-report")
            return !oldResults.contains {
                sameFileURL($0.url, createdFile)
            } && newResults.contains {
                sameFileURL($0.url, renamedFile)
            }
        }

        let renamedFolder = root.appendingPathComponent("Archived Projects", isDirectory: true)
        let movedFile = renamedFolder.appendingPathComponent(renamedFile.lastPathComponent)
        try fileManager.moveItem(at: createdFolder, to: renamedFolder)
        try await assertEventually("Renaming a folder did not remove its old path") {
            let results = try await index.searchDirectories("Live Projects")
            return !results.contains {
                sameFileURL($0.url, createdFolder)
            }
        }
        try await assertEventually("Renaming a folder did not add its new path") {
            try await index.searchDirectories("Archived Projects").contains {
                sameFileURL($0.url, renamedFolder)
            }
        }
        try await assertEventually("Renaming a folder did not update its descendant file paths") {
            try await index.searchFiles("renamed-report").contains {
                sameFileURL($0.url, movedFile)
            }
        }

        try fileManager.removeItem(at: renamedFolder)
        try await assertEventually(
            "Deleting a folder did not evict it and its descendants from the live index"
        ) {
            let folders = try await index.searchDirectories("Archived Projects")
            let files = try await index.searchFiles("renamed-report")
            return !folders.contains {
                sameFileURL($0.url, renamedFolder)
            } && !files.contains {
                sameFileURL($0.url, movedFile)
            }
        }
    }

    @Test func liveWatcherUpdatesFileContent() async throws {
        let fileManager = FileManager.default
        let root = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent(
                "FloodlightContentWatcherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        let file = root.appendingPathComponent("content-notes.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("obsolete content sentinel".utf8).write(to: file)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -5)],
            ofItemAtPath: file.path
        )
        defer { try? fileManager.removeItem(at: root) }

        let index = FFFIndex(rootURL: root, storageURL: storage)
        try await index.start()
        try await assertEventually("FFF's content watcher did not become ready") {
            let progress = try await index.progress()
            return !progress.isScanning && progress.isWatcherReady
        }
        try await assertEventually("Initial file content was not searchable") {
            try await index.searchContent(
                "obsolete content sentinel",
                timeBudgetMilliseconds: 500
            ).contains { sameFileURL($0.url, file) }
        }

        try Data("updated content sentinel".utf8).write(to: file)
        try await assertEventually("Modifying a file did not replace its searchable content") {
            let oldResults = try await index.searchContent(
                "obsolete content sentinel",
                timeBudgetMilliseconds: 500
            )
            let newResults = try await index.searchContent(
                "updated content sentinel",
                timeBudgetMilliseconds: 500
            )
            return !oldResults.contains { sameFileURL($0.url, file) }
                && newResults.contains { sameFileURL($0.url, file) }
        }

        let addedFile = root.appendingPathComponent("added-content.txt")
        try Data("created content sentinel".utf8).write(to: addedFile)
        try await assertEventually(
            "Content from a newly created file was not added to the live index"
        ) {
            try await index.searchContent(
                "created content sentinel",
                timeBudgetMilliseconds: 500
            ).contains { sameFileURL($0.url, addedFile) }
        }

        let renamedFile = root.appendingPathComponent("renamed-content.txt")
        try fileManager.moveItem(at: addedFile, to: renamedFile)
        try await assertEventually("Renaming a file did not update its content-search result URL") {
            let results = try await index.searchContent(
                "created content sentinel",
                timeBudgetMilliseconds: 500
            )
            return !results.contains { sameFileURL($0.url, addedFile) }
                && results.contains { sameFileURL($0.url, renamedFile) }
        }

        try fileManager.removeItem(at: renamedFile)
        try await assertEventually("Deleting a file did not remove its content-search results") {
            try await index.searchContent(
                "created content sentinel",
                timeBudgetMilliseconds: 500
            ).allSatisfy { !sameFileURL($0.url, renamedFile) }
        }

        try fileManager.removeItem(at: file)
        try await assertEventually(
            "Deleting an initially indexed file did not remove its content-search results"
        ) {
            try await index.searchContent(
                "updated content sentinel",
                timeBudgetMilliseconds: 500
            ).allSatisfy { !sameFileURL($0.url, file) }
        }
    }

    @Test func liveWatcherUpdatesApplicationBundlesInsideTheSearchScope() async throws {
        let fileManager = FileManager.default
        let root = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent(
                "FloodlightApplicationWatcherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let index = FFFIndex(rootURL: root, storageURL: storage)
        try await index.start()
        try await assertEventually("FFF's application-bundle watcher did not become ready") {
            let progress = try await index.progress()
            return !progress.isScanning && progress.isWatcherReady
        }

        let application = root.appendingPathComponent("Orbit Test.app", isDirectory: true)
        let executable = application.appendingPathComponent("Contents/MacOS/orbit-test")
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("executable".utf8).write(to: executable)

        try await assertEventually(
            "A created application bundle was not added as one launchable result"
        ) {
            try await index.search("Orbit Test").contains {
                sameFileURL($0.url, application)
                    && $0.isApplicationBundle
            }
        }

        let renamedApplication = root.appendingPathComponent("Nova Test.app", isDirectory: true)
        try fileManager.moveItem(at: application, to: renamedApplication)
        try await assertEventually("Renaming an application did not remove its old result") {
            let results = try await index.search("Orbit Test")
            return !results.contains {
                sameFileURL($0.url, application)
            }
        }
        try await assertEventually("Renaming an application did not add its new result") {
            try await index.search("Nova Test").contains {
                sameFileURL($0.url, renamedApplication)
                    && $0.isApplicationBundle
            }
        }

        try fileManager.removeItem(at: renamedApplication)
        try await assertEventually(
            "Deleting an application bundle did not remove its launchable result"
        ) {
            try await index.search("Nova Test").allSatisfy {
                !sameFileURL($0.url, renamedApplication)
            }
        }
    }

    @Test func liveWatcherMovesInitiallyIndexedFolderWithoutCorruptingOtherEntries() async throws {
        let fileManager = FileManager.default
        let root = canonicalFileURL(fileManager.temporaryDirectory)
            .appendingPathComponent(
                "FloodlightSeededWatcherTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let storage = root.appendingPathComponent(".storage", isDirectory: true)
        let seededFolder = root.appendingPathComponent("A Seeded Folder", isDirectory: true)
        let seededFile = seededFolder.appendingPathComponent("seed-record.txt")
        let survivorFolder = root.appendingPathComponent("Z Survivor Folder", isDirectory: true)
        let survivorFile = survivorFolder.appendingPathComponent("survivor-record.txt")
        try fileManager.createDirectory(at: seededFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: survivorFolder, withIntermediateDirectories: true)
        try Data("seeded folder token".utf8).write(to: seededFile)
        try Data("survivor content token".utf8).write(to: survivorFile)
        defer { try? fileManager.removeItem(at: root) }

        let index = FFFIndex(rootURL: root, storageURL: storage)
        try await index.start()
        try await assertEventually("FFF's seeded-folder watcher did not become ready") {
            let progress = try await index.progress()
            return !progress.isScanning && progress.isWatcherReady
        }

        let movedFolder = root.appendingPathComponent("Moved Seeded Folder", isDirectory: true)
        let movedFile = movedFolder.appendingPathComponent(seededFile.lastPathComponent)
        try fileManager.moveItem(at: seededFolder, to: movedFolder)
        try await assertEventually("Moving an initially indexed folder left its old path behind") {
            let folders = try await index.searchDirectories("A Seeded Folder")
            let files = try await index.searchFiles("seed-record")
            return !folders.contains { sameFileURL($0.url, seededFolder) }
                && !files.contains { sameFileURL($0.url, seededFile) }
        }
        try await assertEventually("Moving an initially indexed folder did not add its new path") {
            let folders = try await index.searchDirectories("Moved Seeded Folder")
            let files = try await index.searchFiles("seed-record")
            return folders.contains { sameFileURL($0.url, movedFolder) }
                && files.contains { sameFileURL($0.url, movedFile) }
        }
        try await assertEventually("Moving another folder corrupted unaffected content entries") {
            let files = try await index.searchFiles("survivor-record")
            let content = try await index.searchContent(
                "survivor content token",
                timeBudgetMilliseconds: 500
            )
            return files.contains { sameFileURL($0.url, survivorFile) }
                && content.contains { sameFileURL($0.url, survivorFile) }
        }

        try fileManager.removeItem(at: movedFolder)
        try await assertEventually("Deleting the moved folder left indexed descendants behind") {
            let folders = try await index.searchDirectories("Moved Seeded Folder")
            let files = try await index.searchFiles("seed-record")
            return !folders.contains { sameFileURL($0.url, movedFolder) }
                && !files.contains { sameFileURL($0.url, movedFile) }
        }
    }

    private func assertEventually(
        _ message: String,
        timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () async throws -> Bool
    ) async throws {
        let succeeded = try await eventually(timeout: timeout, condition)
        #expect(succeeded, "\(message)", sourceLocation: sourceLocation)
    }

    private func createFixtureFiles(
        count: Int,
        in directory: URL,
        fileManager: FileManager
    ) {
        for index in 0..<count {
            fileManager.createFile(
                atPath: directory.appendingPathComponent("fixture-\(index).txt").path,
                contents: Data()
            )
        }
    }

    private func canonicalFileURL(_ url: URL) -> URL {
        let resolvedPath = url.path.withCString { path -> String? in
            guard let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        guard let resolvedPath else { return url.standardizedFileURL }
        return URL(fileURLWithPath: resolvedPath, isDirectory: true)
    }

    private func sameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.path == rhs.path
    }

    private func eventually(
        timeout: TimeInterval = 5,
        pollInterval: Duration = .milliseconds(25),
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: pollInterval)
        } while Date() < deadline
        return false
    }
}
