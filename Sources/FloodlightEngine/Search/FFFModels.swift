import Foundation

package enum FFFIndexError: LocalizedError, Sendable {
    case invalidResult
    case message(String)

    package var errorDescription: String? {
        switch self {
        case .invalidResult:
            "FFF returned an invalid result."
        case let .message(message):
            message
        }
    }
}

/// A file or directory returned by an FFF filename search.
package struct FFFSearchResult: Equatable, Sendable {
    package let name: String
    package let relativePath: String
    package let url: URL
    package let isDirectory: Bool
    package let score: Int
    package let modified: UInt64
    package let size: UInt64

    package init(
        name: String,
        relativePath: String,
        url: URL,
        isDirectory: Bool,
        score: Int,
        modified: UInt64,
        size: UInt64
    ) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.isDirectory = isDirectory
        self.score = score
        self.modified = modified
        self.size = size
    }
}

/// A line of file content returned by an FFF content search.
package struct FFFContentMatch: Equatable, Sendable {
    package let name: String
    package let relativePath: String
    package let url: URL
    package let line: UInt64
    package let snippet: String

    package init(
        name: String,
        relativePath: String,
        url: URL,
        line: UInt64,
        snippet: String
    ) {
        self.name = name
        self.relativePath = relativePath
        self.url = url
        self.line = line
        self.snippet = snippet
    }
}

/// The current state of the asynchronous FFF scan and filesystem watcher.
package struct FFFIndexProgress: Equatable, Sendable {
    package let scannedFiles: UInt64
    package let isScanning: Bool
    package let isWatcherReady: Bool

    package init(scannedFiles: UInt64, isScanning: Bool, isWatcherReady: Bool) {
        self.scannedFiles = scannedFiles
        self.isScanning = isScanning
        self.isWatcherReady = isWatcherReady
    }
}

package typealias IndexedSearchItem = FFFSearchResult
