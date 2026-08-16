import FloodlightEngine
import FloodlightTestSupport
import Foundation
import XCTest

final class PathNavigatorTests: XCTestCase {
    private var fileManager: FileManager!
    private var tree: TemporaryTree!
    private var homeURL: URL!

    override func setUpWithError() throws {
        fileManager = .default
        tree = try TemporaryTree(label: "PathNavigatorTests")
        homeURL = tree.root

        try tree.makeDirectory("Downloads")
        try tree.makeDirectory("Projects/floodlight")
        try tree.makeDirectory("Documents/Work")
        try tree.makeFile("Downloads/report.pdf")
    }

    override func tearDown() {
        tree = nil
        fileManager = nil
        homeURL = nil
    }

    func testTrailingSlashResolvesExistingDirectoryUnderRoot() {
        let result = PathNavigator.resolve(
            query: "Downloads/",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.folderItem.kind, .folder)
        XCTAssertEqual(result?.folderItem.title, "Downloads/")
        XCTAssertEqual(result?.folderItem.score, SearchItemRanking.pathNavigation)
        XCTAssertEqual(
            result?.directoryURL.standardizedFileURL,
            tree.root.appendingPathComponent("Downloads").standardizedFileURL
        )
        XCTAssertEqual(result?.remainder, "")
    }

    func testTildePathExpandsToHomeDirectory() {
        let result = PathNavigator.resolve(
            query: "~/Downloads",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.folderItem.kind, .folder)
        XCTAssertEqual(result?.folderItem.title, "Downloads/")
        XCTAssertEqual(
            result?.directoryURL.standardizedFileURL,
            homeURL.appendingPathComponent("Downloads").standardizedFileURL
        )
    }

    func testTildeWithTrailingSlashExpandsCorrectly() {
        let result = PathNavigator.resolve(
            query: "~/Downloads/",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.folderItem.title, "Downloads/")
        XCTAssertEqual(
            result?.directoryURL.standardizedFileURL,
            homeURL.appendingPathComponent("Downloads").standardizedFileURL
        )
    }

    func testBareTildeResolvesToHomeDirectory() {
        let result = PathNavigator.resolve(
            query: "~/",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.folderItem.kind, .folder)
        XCTAssertEqual(result?.directoryURL.standardizedFileURL, homeURL.standardizedFileURL)
    }

    func testCaseInsensitiveTrailingSlashResolution() {
        let result = PathNavigator.resolve(
            query: "downloads/",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.folderItem.title, "Downloads/")
        XCTAssertEqual(
            result?.directoryURL.standardizedFileURL,
            tree.root.appendingPathComponent("Downloads").standardizedFileURL
        )
    }

    func testAbsolutePosixPathResolution() {
        let result = PathNavigator.resolve(
            query: "/Applications",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.folderItem.kind, .folder)
        XCTAssertEqual(result?.folderItem.title, "Applications/")
        XCTAssertEqual(result?.directoryURL.path, "/Applications")
    }

    func testPathWithRemainderExtractsDirectoryAndRemainder() {
        let result = PathNavigator.resolve(
            query: "Downloads/report",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.folderItem.title, "Downloads/")
        XCTAssertEqual(
            result?.directoryURL.standardizedFileURL,
            tree.root.appendingPathComponent("Downloads").standardizedFileURL
        )
        XCTAssertEqual(result?.remainder, "report")
    }

    func testNestedPathResolvesCorrectly() {
        let result = PathNavigator.resolve(
            query: "Projects/floodlight/",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.folderItem.title, "floodlight/")
        XCTAssertEqual(
            result?.directoryURL.standardizedFileURL,
            tree.root.appendingPathComponent("Projects/floodlight").standardizedFileURL
        )
        XCTAssertEqual(result?.remainder, "")
    }

    func testNonExistentPathReturnsNil() {
        let result = PathNavigator.resolve(
            query: "NonExistentDirectory/",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNil(result)
    }

    func testNonPathQueryReturnsNil() {
        let result = PathNavigator.resolve(
            query: "plain search query",
            rootURL: tree.root,
            homeURL: homeURL,
            fileManager: fileManager
        )

        XCTAssertNil(result)
    }
}
