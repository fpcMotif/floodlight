import Foundation
import XCTest
@testable import Floodlight

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

    func testDynamicFiltersUseFileTypeAndSettingsKind() {
        let pdf = item(kind: .file, path: "/Users/test/Report.PDF")
        let image = item(kind: .file, path: "/Users/test/Photo.heic")
        let document = item(kind: .file, path: "/Users/test/Notes.md")
        let setting = SearchItem(
            title: "Bluetooth",
            subtitle: "System Settings",
            kind: .systemSetting,
            action: .open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!),
            score: 10
        )

        XCTAssertTrue(SearchResultFilter.pdfs.includes(pdf))
        XCTAssertTrue(SearchResultFilter.images.includes(image))
        XCTAssertTrue(SearchResultFilter.documents.includes(document))
        XCTAssertTrue(SearchResultFilter.settings.includes(setting))
        XCTAssertFalse(SearchResultFilter.images.includes(pdf))
        XCTAssertFalse(SearchResultFilter.documents.includes(pdf))
    }

    private func item(kind: SearchItemKind, path: String) -> SearchItem {
        let url = URL(fileURLWithPath: path, isDirectory: kind == .folder)
        return SearchItem(
            title: url.lastPathComponent,
            subtitle: path,
            kind: kind,
            action: .open(url),
            score: 10,
            fileURL: url
        )
    }
}
