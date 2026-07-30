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

        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Floodlight integration test".utf8).write(to: file)
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

        let folderResults = try await index.search("Projects")
        XCTAssertTrue(folderResults.contains { $0.isDirectory && $0.url.lastPathComponent == "Projects" })

        let contentResults = try await index.searchContent("integration test", timeBudgetMilliseconds: 500)
        XCTAssertTrue(contentResults.contains { $0.url.lastPathComponent == file.lastPathComponent })
    }
}
