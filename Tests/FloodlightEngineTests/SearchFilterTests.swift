import Foundation
import Testing
@testable import FloodlightEngine

struct SearchFilterTests {
    @Test func primaryFiltersSeparateAppsFilesAndFolders() {
        let app = item(kind: .application, path: "/Applications/Preview.app")
        let file = item(kind: .file, path: "/Users/test/Notes.txt")
        let folder = item(kind: .folder, path: "/Users/test/Documents")

        #expect(SearchResultFilter.primary == [.all, .applications, .files, .folders])
        #expect(SearchResultFilter.all.includes(app))
        #expect(SearchResultFilter.applications.includes(app))
        #expect(!(SearchResultFilter.applications.includes(file)))
        #expect(SearchResultFilter.files.includes(file))
        #expect(!(SearchResultFilter.files.includes(folder)))
        #expect(SearchResultFilter.folders.includes(folder))
    }

    @Test func dynamicFiltersUseFileTypeAndSettingsKind() throws {
        let pdf = item(kind: .file, path: "/Users/test/Report.PDF")
        let image = item(kind: .file, path: "/Users/test/Photo.heic")
        let document = item(kind: .file, path: "/Users/test/Notes.md")
        let setting = try SearchItem(
            title: "Bluetooth",
            subtitle: "System Settings",
            kind: .systemSetting,
            action: .open(
                #require(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings"))
            ),
            score: 10
        )

        #expect(SearchResultFilter.pdfs.includes(pdf))
        #expect(SearchResultFilter.images.includes(image))
        #expect(SearchResultFilter.documents.includes(document))
        #expect(SearchResultFilter.settings.includes(setting))
        #expect(!(SearchResultFilter.images.includes(pdf)))
        #expect(!(SearchResultFilter.documents.includes(pdf)))
    }

    @Test(arguments: ["epub", "mobi", "azw", "azw3", "djvu", "fb2", "cbr", "cbz"])
    func eBookAndPublicationFormatsAreIncludedInDocumentFilter(ext: String) {
        let uppercaseFile = item(
            kind: .file,
            path: "/Users/test/Downloads/book.\(ext.uppercased())"
        )
        let lowercaseFile = item(kind: .file, path: "/Users/test/Downloads/book.\(ext)")

        #expect(
            SearchResultFilter.documents.includes(uppercaseFile),
            "Expected .\(ext) to be included in documents"
        )
        #expect(
            SearchResultFilter.documents.includes(lowercaseFile),
            "Expected .\(ext) to be included in documents"
        )
        #expect(SearchResultFilter.files.includes(lowercaseFile))
        #expect(SearchResultFilter.all.includes(lowercaseFile))
        #expect(!(SearchResultFilter.images.includes(lowercaseFile)))
        #expect(!(SearchResultFilter.pdfs.includes(lowercaseFile)))
        #expect(!(SearchResultFilter.applications.includes(lowercaseFile)))
        #expect(!(SearchResultFilter.settings.includes(lowercaseFile)))
    }

    @Test(arguments: SearchResultFilter.allCases)
    func singlePassFilterCountsMatchFilterPredicates(filter: SearchResultFilter) {
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

        #expect(
            counts[filter] == items.lazy.filter(filter.includes).count,
            "Incorrect count for \(filter)"
        )
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
