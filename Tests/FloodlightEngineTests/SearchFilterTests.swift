import Foundation
import XCTest
@testable import FloodlightEngine

final class SearchFilterTests: XCTestCase {
    func testPrimaryFiltersSeparateAppsFilesAndFolders() {
        let app = item(kind: .application, path: "/Applications/Preview.app")
        let file = item(kind: .file, path: "/Users/test/Notes.txt")
        let folder = item(kind: .folder, path: "/Users/test/Documents")

        XCTAssertEqual(SearchResultFilter.primary, [.all, .applications, .files, .folders])
        XCTAssertTrue(SearchResultFilter.all.includes(app))
        XCTAssertTrue(SearchResultFilter.applications.includes(app))
        XCTAssertFalse(SearchResultFilter.applications.includes(file))
        XCTAssertTrue(SearchResultFilter.files.includes(file))
        XCTAssertFalse(SearchResultFilter.files.includes(folder))
        XCTAssertTrue(SearchResultFilter.folders.includes(folder))
    }

    func testDynamicFiltersUseFileTypeAndSettingsKind() throws {
        let pdf = item(kind: .file, path: "/Users/test/Report.PDF")
        let image = item(kind: .file, path: "/Users/test/Photo.heic")
        let document = item(kind: .file, path: "/Users/test/Notes.md")
        let setting = try SearchItem(
            title: "Bluetooth",
            subtitle: "System Settings",
            kind: .systemSetting,
            action: .open(
                XCTUnwrap(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings"))
            ),
            score: 10
        )

        XCTAssertTrue(SearchResultFilter.pdfs.includes(pdf))
        XCTAssertTrue(SearchResultFilter.images.includes(image))
        XCTAssertTrue(SearchResultFilter.documents.includes(document))
        XCTAssertTrue(SearchResultFilter.settings.includes(setting))
        XCTAssertFalse(SearchResultFilter.images.includes(pdf))
        XCTAssertFalse(SearchResultFilter.documents.includes(pdf))
    }

    func testEBookAndPublicationFormatsAreIncludedInDocumentFilter() {
        let ebookExtensions = ["epub", "mobi", "azw", "azw3", "djvu", "fb2", "cbr", "cbz"]

        for ext in ebookExtensions {
            let uppercaseFile = item(
                kind: .file,
                path: "/Users/test/Downloads/book.\(ext.uppercased())"
            )
            let lowercaseFile = item(kind: .file, path: "/Users/test/Downloads/book.\(ext)")

            XCTAssertTrue(
                SearchResultFilter.documents.includes(uppercaseFile),
                "Expected .\(ext) to be included in documents"
            )
            XCTAssertTrue(
                SearchResultFilter.documents.includes(lowercaseFile),
                "Expected .\(ext) to be included in documents"
            )
            XCTAssertTrue(SearchResultFilter.files.includes(lowercaseFile))
            XCTAssertTrue(SearchResultFilter.all.includes(lowercaseFile))
            XCTAssertFalse(SearchResultFilter.images.includes(lowercaseFile))
            XCTAssertFalse(SearchResultFilter.pdfs.includes(lowercaseFile))
            XCTAssertFalse(SearchResultFilter.applications.includes(lowercaseFile))
            XCTAssertFalse(SearchResultFilter.settings.includes(lowercaseFile))
        }
    }

    func testSinglePassFilterCountsMatchFilterPredicates() {
        let items = [
            item(kind: .application, path: "/Applications/Floodlight.app"),
            item(kind: .folder, path: "/Users/test/Documents"),
            item(kind: .systemSetting, path: nil),
            item(kind: .file, path: "/Users/test/Downloads/guide.pdf"),
            item(kind: .file, path: "/Users/test/Desktop/photo.png"),
            item(kind: .file, path: "/Users/test/Documents/notes.txt"),
            item(kind: .file, path: "/Users/test/Downloads/book.epub"),
            item(kind: .file, path: "/Users/test/Downloads/handbook.mobi"),
            item(kind: .file, path: "/Users/test/Downloads/manual.azw3"),
            item(kind: .web, path: nil),
        ]
        let counts = SearchFilterCounts(items: items)

        for filter in SearchResultFilter.allCases {
            XCTAssertEqual(
                counts[filter],
                items.lazy.filter(filter.includes).count,
                "Incorrect count for \(filter)"
            )
        }
    }

    private func item(kind: SearchItemKind, path: String?) -> SearchItem {
        let url = path.map { URL(fileURLWithPath: $0, isDirectory: kind == .folder) }
        let actionURL = url ?? URL(fileURLWithPath: "/tmp/\(kind.rawValue)")
        return SearchItem(
            title: url?.lastPathComponent ?? kind.label,
            subtitle: path ?? kind.label,
            kind: kind,
            action: .open(actionURL),
            score: 10,
            fileURL: url
        )
    }
}
