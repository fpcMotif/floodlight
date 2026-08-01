import Foundation
import XCTest
@testable import Floodlight

@MainActor
final class SearchCoordinatorTests: XCTestCase {
    func testRealResultReplacesAutomaticWebFallbackSelection() {
        let folder = makeFolder()
        let web = makeWebResult()

        XCTAssertEqual(
            SearchCoordinator.reconciledSelectionID(
                previousSelection: web.id,
                results: [folder, web],
                resetSelection: false,
                promoteWebFallback: true
            ),
            folder.id
        )
    }

    func testUserSelectedWebFallbackRemainsSelected() {
        let folder = makeFolder()
        let web = makeWebResult()

        XCTAssertEqual(
            SearchCoordinator.reconciledSelectionID(
                previousSelection: web.id,
                results: [folder, web],
                resetSelection: false,
                promoteWebFallback: false
            ),
            web.id
        )
    }

    private func makeFolder() -> SearchItem {
        let url = URL(fileURLWithPath: "/Users/example/code", isDirectory: true)
        return SearchItem(
            id: "folder:\(url.path)",
            title: "code",
            subtitle: "code",
            kind: .folder,
            action: .open(url),
            score: 300_000,
            fileURL: url
        )
    }

    private func makeWebResult() -> SearchItem {
        SearchItem(
            id: "web-search",
            title: "Search the Web",
            subtitle: "Open in your default browser",
            kind: .web,
            action: .open(URL(string: "https://example.com")!),
            score: Int.min
        )
    }
}
