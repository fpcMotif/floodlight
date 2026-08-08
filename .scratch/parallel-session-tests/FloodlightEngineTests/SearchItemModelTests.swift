import Foundation
import XCTest
@testable import FloodlightEngine

/// Comprehensive tests for the search item model layer — `SearchItemKind`,
/// `SearchItemAction`, `SearchItem`, `SearchItemPage`, `SearchFilterOption`,
/// `AssistantRun`, `AssistantAnswerState`, and `SearchItemIconSource`.
final class SearchItemModelTests: XCTestCase {

    // MARK: - SearchItemKind

    func testKindLabels() {
        XCTAssertEqual(SearchItemKind.application.label, "Application")
        XCTAssertEqual(SearchItemKind.assistant.label, "AI Assistant")
        XCTAssertEqual(SearchItemKind.calculator.label, "Calculator")
        XCTAssertEqual(SearchItemKind.file.label, "File")
        XCTAssertEqual(SearchItemKind.folder.label, "Folder")
        XCTAssertEqual(SearchItemKind.systemSetting.label, "System Setting")
        XCTAssertEqual(SearchItemKind.web.label, "Web Search")
    }

    func testKindSymbolNames() {
        XCTAssertEqual(SearchItemKind.application.symbolName, "app.dashed")
        XCTAssertEqual(SearchItemKind.assistant.symbolName, "sparkles")
        XCTAssertEqual(SearchItemKind.calculator.symbolName, "plus.forwardslash.minus")
        XCTAssertEqual(SearchItemKind.file.symbolName, "doc")
        XCTAssertEqual(SearchItemKind.folder.symbolName, "folder")
        XCTAssertEqual(SearchItemKind.systemSetting.symbolName, "gearshape")
        XCTAssertEqual(SearchItemKind.web.symbolName, "globe")
    }

    func testKindRawValuesAreStable() {
        XCTAssertEqual(SearchItemKind.application.rawValue, "application")
        XCTAssertEqual(SearchItemKind.assistant.rawValue, "assistant")
        XCTAssertEqual(SearchItemKind.calculator.rawValue, "calculator")
        XCTAssertEqual(SearchItemKind.file.rawValue, "file")
        XCTAssertEqual(SearchItemKind.folder.rawValue, "folder")
        XCTAssertEqual(SearchItemKind.systemSetting.rawValue, "systemSetting")
        XCTAssertEqual(SearchItemKind.web.rawValue, "web")
    }

    func testKindIsHashable() {
        let set: Set<SearchItemKind> = [.application, .file, .folder, .application]
        XCTAssertEqual(set.count, 3)
    }

    // MARK: - SearchItemAction

    func testActionEquality() {
        XCTAssertEqual(SearchItemAction.copy("hello"), SearchItemAction.copy("hello"))
        XCTAssertNotEqual(SearchItemAction.copy("hello"), SearchItemAction.copy("world"))
        XCTAssertEqual(
            SearchItemAction.open(URL(fileURLWithPath: "/tmp")),
            SearchItemAction.open(URL(fileURLWithPath: "/tmp"))
        )
        XCTAssertNotEqual(
            SearchItemAction.open(URL(fileURLWithPath: "/tmp")),
            SearchItemAction.open(URL(fileURLWithPath: "/other"))
        )
        XCTAssertEqual(SearchItemAction.showFloodlightSettings, SearchItemAction.showFloodlightSettings)
        XCTAssertEqual(
            SearchItemAction.askAssistant(command: "claude", arguments: ["-p", "hi"]),
            SearchItemAction.askAssistant(command: "claude", arguments: ["-p", "hi"])
        )
        XCTAssertNotEqual(
            SearchItemAction.askAssistant(command: "claude", arguments: ["-p", "hi"]),
            SearchItemAction.askAssistant(command: "codex", arguments: ["-p", "hi"])
        )
        XCTAssertNotEqual(
            SearchItemAction.askAssistant(command: "claude", arguments: ["-p", "hi"]),
            SearchItemAction.askAssistant(command: "claude", arguments: ["-p", "bye"])
        )
    }

    func testActionIsHashable() {
        let actions: Set<SearchItemAction> = [
            .copy("a"), .copy("a"), .showFloodlightSettings,
            .open(URL(fileURLWithPath: "/tmp")),
        ]
        XCTAssertEqual(actions.count, 3)
    }

    func testActionsFromDifferentCasesAreNotEqual() {
        XCTAssertNotEqual(SearchItemAction.copy("x"), .showFloodlightSettings)
        XCTAssertNotEqual(
            SearchItemAction.open(URL(fileURLWithPath: "/tmp")),
            .askAssistant(command: "c", arguments: [])
        )
    }

    // MARK: - SearchItemIconSource

    func testIconSourceEquality() {
        XCTAssertEqual(SearchItemIconSource.inferred, .inferred)
        XCTAssertEqual(SearchItemIconSource.floodlightApplication, .floodlightApplication)
        XCTAssertNotEqual(SearchItemIconSource.inferred, .floodlightApplication)
    }

    func testIconSourceIsHashable() {
        let set: Set<SearchItemIconSource> = [.inferred, .floodlightApplication, .inferred]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - SearchItem

    func testDefaultIDIsDerivedFromKindTitleAndSubtitle() {
        let item = SearchItem(
            title: "Safari",
            subtitle: "/Applications",
            kind: .application,
            action: .open(URL(fileURLWithPath: "/Applications/Safari.app")),
            score: 100
        )
        XCTAssertEqual(item.id, "application:Safari:/Applications")
    }

    func testExplicitIDOverridesDefault() {
        let item = SearchItem(
            id: "custom-id",
            title: "Safari",
            subtitle: "/Applications",
            kind: .application,
            action: .open(URL(fileURLWithPath: "/Applications/Safari.app")),
            score: 100
        )
        XCTAssertEqual(item.id, "custom-id")
    }

    func testIsPreviewableForFileWithURL() {
        let item = SearchItem(
            title: "report.pdf",
            subtitle: "/Users/test",
            kind: .file,
            action: .open(URL(fileURLWithPath: "/Users/test/report.pdf")),
            score: 100,
            fileURL: URL(fileURLWithPath: "/Users/test/report.pdf")
        )
        XCTAssertTrue(item.isPreviewable)
    }

    func testIsNotPreviewableForFileWithoutURL() {
        let item = SearchItem(
            title: "report.pdf",
            subtitle: "/Users/test",
            kind: .file,
            action: .open(URL(fileURLWithPath: "/Users/test/report.pdf")),
            score: 100
        )
        XCTAssertFalse(item.isPreviewable)
    }

    func testIsNotPreviewableForNonFileKinds() {
        for kind in [SearchItemKind.application, .assistant, .calculator, .folder, .systemSetting, .web] {
            let item = SearchItem(
                title: "test",
                subtitle: "test",
                kind: kind,
                action: .copy("test"),
                score: 100,
                fileURL: URL(fileURLWithPath: "/tmp/test")
            )
            XCTAssertFalse(item.isPreviewable, "\(kind) should not be previewable")
        }
    }

    func testFileExtensionIsLowercased() {
        let item = SearchItem(
            title: "report",
            subtitle: "/test",
            kind: .file,
            action: .open(URL(fileURLWithPath: "/test/Report.PDF")),
            score: 100,
            fileURL: URL(fileURLWithPath: "/test/Report.PDF")
        )
        // fileExtension is fileprivate, but we can test it indirectly through
        // SearchResultFilter.pdfs.includes
        XCTAssertTrue(SearchResultFilter.pdfs.includes(item))
    }

    func testFileExtensionIsEmptyForNonFileKinds() {
        let item = SearchItem(
            title: "test",
            subtitle: "test",
            kind: .application,
            action: .copy("test"),
            score: 100,
            fileURL: URL(fileURLWithPath: "/test/thing.pdf")
        )
        // Non-file kinds should not match file-type filters
        XCTAssertFalse(SearchResultFilter.pdfs.includes(item))
        XCTAssertFalse(SearchResultFilter.images.includes(item))
        XCTAssertFalse(SearchResultFilter.documents.includes(item))
    }

    func testSearchItemEquality() {
        let item1 = SearchItem(
            id: "same", title: "A", subtitle: "B", kind: .file,
            action: .copy("x"), score: 10
        )
        let item2 = SearchItem(
            id: "same", title: "A", subtitle: "B", kind: .file,
            action: .copy("x"), score: 10
        )
        let item3 = SearchItem(
            id: "same", title: "A", subtitle: "B", kind: .file,
            action: .copy("x"), score: 20
        )
        XCTAssertEqual(item1, item2)
        XCTAssertNotEqual(item1, item3, "different score should make items unequal")
    }

    func testSearchItemIsHashable() {
        let item = SearchItem(
            title: "test", subtitle: "sub", kind: .file,
            action: .copy("x"), score: 10
        )
        let set: Set<SearchItem> = [item, item]
        XCTAssertEqual(set.count, 1)
    }

    // MARK: - SearchItemPage

    func testPageStoresItemsAndTotalMatched() {
        let items = (0..<5).map { i in
            SearchItem(title: "item\(i)", subtitle: "", kind: .file,
                       action: .copy(""), score: i)
        }
        let page = SearchItemPage(items: items, totalMatched: 100)
        XCTAssertEqual(page.items.count, 5)
        XCTAssertEqual(page.totalMatched, 100)
    }

    func testEmptyPage() {
        let page = SearchItemPage(items: [], totalMatched: 0)
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.totalMatched, 0)
    }

    // MARK: - SearchFilterOption

    func testFilterOptionProperties() {
        let option = SearchFilterOption(filter: .applications, count: 5, isLoading: false)
        XCTAssertEqual(option.filter, .applications)
        XCTAssertEqual(option.count, 5)
        XCTAssertFalse(option.isLoading)
        XCTAssertEqual(option.id, .applications)
    }

    func testFilterOptionEquality() {
        let opt1 = SearchFilterOption(filter: .files, count: 3, isLoading: true)
        let opt2 = SearchFilterOption(filter: .files, count: 3, isLoading: true)
        let opt3 = SearchFilterOption(filter: .files, count: 3, isLoading: false)
        let opt4 = SearchFilterOption(filter: .all, count: 3, isLoading: true)
        XCTAssertEqual(opt1, opt2)
        XCTAssertNotEqual(opt1, opt3, "different isLoading should be unequal")
        XCTAssertNotEqual(opt1, opt4, "different filter should be unequal")
    }

    // MARK: - AssistantAnswerState

    func testAssistantAnswerStateEquality() {
        XCTAssertEqual(AssistantAnswerState.running, .running)
        XCTAssertEqual(AssistantAnswerState.answered("hello"), .answered("hello"))
        XCTAssertNotEqual(AssistantAnswerState.answered("hello"), .answered("world"))
        XCTAssertEqual(AssistantAnswerState.failed("error"), .failed("error"))
        XCTAssertNotEqual(AssistantAnswerState.failed("error"), .failed("other"))
        XCTAssertNotEqual(AssistantAnswerState.running, .answered(""))
        XCTAssertNotEqual(AssistantAnswerState.running, .failed(""))
        XCTAssertNotEqual(AssistantAnswerState.answered(""), .failed(""))
    }

    // MARK: - AssistantRun

    func testAssistantRunProperties() {
        let run = AssistantRun(itemID: "test-id", state: .running)
        XCTAssertEqual(run.itemID, "test-id")
        XCTAssertEqual(run.state, .running)
    }

    func testAssistantRunEquality() {
        let run1 = AssistantRun(itemID: "a", state: .running)
        let run2 = AssistantRun(itemID: "a", state: .running)
        let run3 = AssistantRun(itemID: "b", state: .running)
        let run4 = AssistantRun(itemID: "a", state: .answered("hi"))
        XCTAssertEqual(run1, run2)
        XCTAssertNotEqual(run1, run3, "different itemID should be unequal")
        XCTAssertNotEqual(run1, run4, "different state should be unequal")
    }

    // MARK: - SearchResultFilter

    func testFilterTitles() {
        XCTAssertEqual(SearchResultFilter.all.title, "All")
        XCTAssertEqual(SearchResultFilter.applications.title, "Apps")
        XCTAssertEqual(SearchResultFilter.files.title, "Files")
        XCTAssertEqual(SearchResultFilter.folders.title, "Folders")
        XCTAssertEqual(SearchResultFilter.settings.title, "Settings")
        XCTAssertEqual(SearchResultFilter.pdfs.title, "PDFs")
        XCTAssertEqual(SearchResultFilter.images.title, "Images")
        XCTAssertEqual(SearchResultFilter.documents.title, "Documents")
    }

    func testFilterIsDynamic() {
        XCTAssertFalse(SearchResultFilter.all.isDynamic)
        XCTAssertFalse(SearchResultFilter.applications.isDynamic)
        XCTAssertFalse(SearchResultFilter.files.isDynamic)
        XCTAssertFalse(SearchResultFilter.folders.isDynamic)
        XCTAssertTrue(SearchResultFilter.settings.isDynamic)
        XCTAssertTrue(SearchResultFilter.pdfs.isDynamic)
        XCTAssertTrue(SearchResultFilter.images.isDynamic)
        XCTAssertTrue(SearchResultFilter.documents.isDynamic)
    }

    func testFilterPrimaryAndDynamicPartition() {
        let primary = Set(SearchResultFilter.primary)
        let dynamic = Set(SearchResultFilter.dynamic)
        XCTAssertTrue(primary.isDisjoint(with: dynamic))
        XCTAssertEqual(primary.union(dynamic).count, 8)
    }

    func testFilterIDMatchesRawValue() {
        for filter in SearchResultFilter.allCases {
            XCTAssertEqual(filter.id, filter.rawValue)
        }
    }

    func testFilterAllIncludesEverything() {
        for kind in [SearchItemKind.application, .assistant, .calculator, .file, .folder, .systemSetting, .web] {
            let item = SearchItem(title: "t", subtitle: "s", kind: kind, action: .copy(""), score: 0)
            XCTAssertTrue(SearchResultFilter.all.includes(item), "all should include \(kind)")
        }
    }

    func testFilterImageExtensions() {
        let imageExts = ["avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "svg", "tif", "tiff", "webp"]
        for ext in imageExts {
            let item = SearchItem(
                title: "image", subtitle: "", kind: .file,
                action: .open(URL(fileURLWithPath: "/tmp/image.\(ext)")),
                score: 0,
                fileURL: URL(fileURLWithPath: "/tmp/image.\(ext)")
            )
            XCTAssertTrue(SearchResultFilter.images.includes(item), "images should include .\(ext)")
            XCTAssertFalse(SearchResultFilter.documents.includes(item), "documents should not include .\(ext)")
            XCTAssertFalse(SearchResultFilter.pdfs.includes(item), "pdfs should not include .\(ext)")
        }
    }

    func testFilterDocumentExtensions() {
        let docExts = ["csv", "doc", "docx", "key", "md", "numbers", "pages", "ppt", "pptx", "rtf", "txt", "xls", "xlsx"]
        for ext in docExts {
            let item = SearchItem(
                title: "doc", subtitle: "", kind: .file,
                action: .open(URL(fileURLWithPath: "/tmp/doc.\(ext)")),
                score: 0,
                fileURL: URL(fileURLWithPath: "/tmp/doc.\(ext)")
            )
            XCTAssertTrue(SearchResultFilter.documents.includes(item), "documents should include .\(ext)")
            XCTAssertFalse(SearchResultFilter.images.includes(item), "images should not include .\(ext)")
        }
    }

    func testFilterCaseInsensitivityOfFileExtensions() {
        let item = SearchItem(
            title: "photo", subtitle: "", kind: .file,
            action: .open(URL(fileURLWithPath: "/tmp/Photo.PNG")),
            score: 0,
            fileURL: URL(fileURLWithPath: "/tmp/Photo.PNG")
        )
        XCTAssertTrue(SearchResultFilter.images.includes(item))
    }

    // MARK: - SearchFilterCounts

    func testEmptyCounts() {
        let counts = SearchFilterCounts()
        for filter in SearchResultFilter.allCases {
            XCTAssertEqual(counts[filter], 0, "empty counts should be 0 for \(filter)")
        }
    }

    func testCountsForMixedItems() {
        let items: [SearchItem] = [
            makeFile(path: "/tmp/a.pdf"),
            makeFile(path: "/tmp/b.png"),
            makeFile(path: "/tmp/c.txt"),
            makeFile(path: "/tmp/d.unknown"),
            makeItem(kind: .application),
            makeItem(kind: .folder),
            makeItem(kind: .systemSetting),
            makeItem(kind: .web),
            makeItem(kind: .assistant),
            makeItem(kind: .calculator),
        ]
        let counts = SearchFilterCounts(items: items)

        XCTAssertEqual(counts[.all], 10)
        XCTAssertEqual(counts[.applications], 1)
        XCTAssertEqual(counts[.files], 4)
        XCTAssertEqual(counts[.folders], 1)
        XCTAssertEqual(counts[.settings], 1)
        XCTAssertEqual(counts[.pdfs], 1)
        XCTAssertEqual(counts[.images], 1)
        XCTAssertEqual(counts[.documents], 1)
    }

    func testCountsSubscriptMatchesFilterPredicate() {
        let items: [SearchItem] = (0..<20).map { i in
            let kind: SearchItemKind
            switch i % 5 {
            case 0: kind = .application
            case 1: kind = .file
            case 2: kind = .folder
            case 3: kind = .systemSetting
            default: kind = .web
            }
            return makeItem(kind: kind)
        }
        let counts = SearchFilterCounts(items: items)

        for filter in SearchResultFilter.allCases {
            XCTAssertEqual(counts[filter], items.lazy.filter(filter.includes).count,
                "count mismatch for \(filter)")
        }
    }

    // MARK: - Helpers

    private func makeItem(kind: SearchItemKind) -> SearchItem {
        SearchItem(title: "item", subtitle: "sub", kind: kind, action: .copy(""), score: 0)
    }

    private func makeFile(path: String) -> SearchItem {
        let url = URL(fileURLWithPath: path)
        return SearchItem(
            title: url.lastPathComponent, subtitle: "", kind: .file,
            action: .open(url), score: 0, fileURL: url
        )
    }
}
