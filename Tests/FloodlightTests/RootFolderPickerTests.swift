import AppKit
import XCTest
@testable import Floodlight

@MainActor
final class RootFolderPickerTests: XCTestCase {
    func testChooserIsASingleFolderPickerRootedAtTheCurrentScope() {
        let currentRoot = FileManager.default.temporaryDirectory
        let panel = RootFolderPicker.makePanel(startingAt: currentRoot)

        XCTAssertEqual(panel.title, "Choose a folder to search")
        XCTAssertEqual(
            panel.message,
            "Floodlight will search this folder and keep results up to date."
        )
        XCTAssertEqual(panel.prompt, "Choose Folder")
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertFalse(panel.canChooseFiles)
        XCTAssertFalse(panel.canCreateDirectories)
        XCTAssertFalse(panel.allowsMultipleSelection)
        XCTAssertEqual(
            panel.directoryURL?.standardizedFileURL.path,
            currentRoot.standardizedFileURL.path
        )
    }
}
