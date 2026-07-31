import Foundation
import XCTest
@testable import Floodlight

final class FFFIndexTests: XCTestCase {
    func testIndexesAndSearchesFilesAndFolders() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
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

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("Floodlight integration test".utf8).write(to: file)
        try Data("%PDF-1.7".utf8).write(to: pdf)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        try Data("ordinary text remains indexed".utf8).write(to: document)
        defer { try? fileManager.removeItem(at: root) }

        let index = FFFIndex(rootURL: root, storageURL: storage)
        try await index.start()

        for _ in 0..<100 {
            let progress = try await index.progress()
            if !progress.isScanning { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        let fileResults = try await index.search("needle")
        XCTAssertTrue(fileResults.contains { $0.url.lastPathComponent == file.lastPathComponent })
        let fileOnlyResults = try await index.searchFiles("needle")
        XCTAssertTrue(fileOnlyResults.contains { $0.url.lastPathComponent == file.lastPathComponent })
        XCTAssertFalse(fileOnlyResults.contains(where: \.isDirectory))

        let downloadResults = try await index.searchFiles("download-guide")
        XCTAssertTrue(downloadResults.contains { $0.url == pdf })
        let desktopResults = try await index.searchFiles("vacation-snapshot")
        XCTAssertTrue(desktopResults.contains { $0.url == image })
        let documentResults = try await index.searchFiles("meeting-brief")
        XCTAssertTrue(documentResults.contains { $0.url == document })

        let folderResults = try await index.search("Projects")
        XCTAssertTrue(folderResults.contains { $0.isDirectory && $0.url.lastPathComponent == "Projects" })
        let directoryOnlyResults = try await index.searchDirectories("Projects")
        XCTAssertTrue(
            directoryOnlyResults.contains {
                $0.isDirectory && $0.url.lastPathComponent == "Projects"
            }
        )

        let contentResults = try await index.searchContent("integration test", timeBudgetMilliseconds: 500)
        XCTAssertTrue(contentResults.contains { $0.url.lastPathComponent == file.lastPathComponent })
    }
}
