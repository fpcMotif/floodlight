import FloodlightEngine
import FloodlightTestSupport
import Foundation
import Testing

struct PathNavigatorTests {
    private func makeTree() throws -> TemporaryTree {
        let tree = try TemporaryTree(label: "PathNavigatorTests")
        try tree.makeDirectory("Downloads")
        try tree.makeDirectory("Projects/floodlight")
        try tree.makeDirectory("Documents/Work")
        try tree.makeFile("Downloads/report.pdf")
        return tree
    }

    @Test func trailingSlashResolvesExistingDirectoryUnderRoot() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "Downloads/",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result != nil)
        #expect(result?.folderItem.kind == .folder)
        #expect(result?.folderItem.title == "Downloads/")
        #expect(result?.folderItem.score == SearchItemRanking.pathNavigation)
        #expect(
            result?.directoryURL.standardizedFileURL
                == tree.root.appendingPathComponent("Downloads").standardizedFileURL
        )
        #expect(result?.remainder.isEmpty == true)
    }

    @Test func tildePathExpandsToHomeDirectory() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "~/Downloads",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result != nil)
        #expect(result?.folderItem.kind == .folder)
        #expect(result?.folderItem.title == "Downloads/")
        #expect(
            result?.directoryURL.standardizedFileURL
                == tree.root.appendingPathComponent("Downloads").standardizedFileURL
        )
    }

    @Test func tildeWithTrailingSlashExpandsCorrectly() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "~/Downloads/",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result != nil)
        #expect(result?.folderItem.title == "Downloads/")
        #expect(
            result?.directoryURL.standardizedFileURL
                == tree.root.appendingPathComponent("Downloads").standardizedFileURL
        )
    }

    @Test func bareTildeResolvesToHomeDirectory() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "~/",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result != nil)
        #expect(result?.folderItem.kind == .folder)
        #expect(result?.directoryURL.standardizedFileURL == tree.root.standardizedFileURL)
    }

    @Test func caseInsensitiveTrailingSlashResolution() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "downloads/",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result != nil)
        #expect(result?.folderItem.title == "Downloads/")
        #expect(
            result?.directoryURL.standardizedFileURL
                == tree.root.appendingPathComponent("Downloads").standardizedFileURL
        )
    }

    @Test func absolutePosixPathResolution() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "/Applications",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result != nil)
        #expect(result?.folderItem.kind == .folder)
        #expect(result?.folderItem.title == "Applications/")
        #expect(result?.directoryURL.path == "/Applications")
    }

    @Test func pathWithRemainderExtractsDirectoryAndRemainder() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "Downloads/report",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result != nil)
        #expect(result?.folderItem.title == "Downloads/")
        #expect(
            result?.directoryURL.standardizedFileURL
                == tree.root.appendingPathComponent("Downloads").standardizedFileURL
        )
        #expect(result?.remainder == "report")
    }

    @Test func nestedPathResolvesCorrectly() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "Projects/floodlight/",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result != nil)
        #expect(result?.folderItem.title == "floodlight/")
        #expect(
            result?.directoryURL.standardizedFileURL
                == tree.root.appendingPathComponent("Projects/floodlight").standardizedFileURL
        )
        #expect(result?.remainder.isEmpty == true)
    }

    @Test func nonExistentPathReturnsNil() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "NonExistentDirectory/",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result == nil)
    }

    @Test func nonPathQueryReturnsNil() throws {
        let tree = try makeTree()
        let result = PathNavigator.resolve(
            query: "plain search query",
            rootURL: tree.root,
            homeURL: tree.root,
            fileManager: .default
        )

        #expect(result == nil)
    }
}
