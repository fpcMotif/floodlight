import AppKit
import Foundation
import XCTest
@testable import Floodlight

@MainActor
final class FloodlightPanelStressTests: XCTestCase {
    // MARK: - shouldHideOnToggle

    func testShouldHideOnToggleAllCombinations() {
        // Visible + key + active -> hide
        XCTAssertTrue(
            FloodlightPanelController.shouldHideOnToggle(
                panelIsVisible: true,
                panelIsKeyWindow: true,
                applicationIsActive: true
            )
        )
        // Any one false -> show
        XCTAssertFalse(
            FloodlightPanelController.shouldHideOnToggle(
                panelIsVisible: true,
                panelIsKeyWindow: true,
                applicationIsActive: false
            )
        )
        XCTAssertFalse(
            FloodlightPanelController.shouldHideOnToggle(
                panelIsVisible: true,
                panelIsKeyWindow: false,
                applicationIsActive: true
            )
        )
        XCTAssertFalse(
            FloodlightPanelController.shouldHideOnToggle(
                panelIsVisible: false,
                panelIsKeyWindow: true,
                applicationIsActive: true
            )
        )
        // All false -> show
        XCTAssertFalse(
            FloodlightPanelController.shouldHideOnToggle(
                panelIsVisible: false,
                panelIsKeyWindow: false,
                applicationIsActive: false
            )
        )
    }

    // MARK: - panelCommand

    func testPanelCommandForEverySingleCharacter() {
        // Every lowercase letter: c, l, r (no shift), y map to known commands;
        // everything else is unmatched.
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "c", shiftHeld: false), .copySelection)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "l", shiftHeld: false), .chooseRoot)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "r", shiftHeld: false), .revealSelection)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "y", shiftHeld: false), .togglePreview)

        let knownCommands: Set<String> = ["c", "l", "r", "y"]
        for character in "abcdefghijklmnopqrstuvwxyz" {
            let ch = String(character)
            if knownCommands.contains(ch) {
                continue
            }
            XCTAssertEqual(
                FloodlightPanelController.panelCommand(for: ch, shiftHeld: false),
                .unmatched,
                "expected unmatched for \(ch)"
            )
        }
    }

    func testPanelCommandForNil() {
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: nil, shiftHeld: false), .unmatched)
    }

    func testPanelCommandForMultiCharString() {
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "cl", shiftHeld: false), .unmatched)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "cc", shiftHeld: false), .unmatched)
    }

    func testPanelCommandForEmptyString() {
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "", shiftHeld: false), .unmatched)
    }

    func testPanelCommandShiftOnlyAffectsR() {
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "r", shiftHeld: true), .rebuildIndex)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "r", shiftHeld: false), .revealSelection)
        // Shift is ignored for other commands.
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "c", shiftHeld: true), .copySelection)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "l", shiftHeld: true), .chooseRoot)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "y", shiftHeld: true), .togglePreview)
    }

    // MARK: - commandDigit

    func testCommandDigitForAllDigits() {
        for digit in 0...9 {
            XCTAssertEqual(FloodlightPanelController.commandDigit(for: String(digit)), digit)
        }
    }

    func testCommandDigitForNonDigits() {
        XCTAssertNil(FloodlightPanelController.commandDigit(for: nil))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: "x"))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: "10"))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: ""))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: " "))
    }

    // MARK: - filterShortcutIndex

    func testFilterShortcutIndexForAllDigits() {
        for digit in 1...5 {
            XCTAssertEqual(FloodlightPanelController.filterShortcutIndex(for: String(digit)), digit - 1)
        }
        for digit in [0, 6, 7, 8, 9] {
            XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: String(digit)))
        }
    }

    // MARK: - performSearchTextEditingCommand

    func testPerformSearchTextEditingCommandWithNilEditor() {
        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand("a", in: nil)
        )
    }

    func testPerformSearchTextEditingCommandWithNonFieldEditor() {
        let editor = NSTextView()
        editor.isFieldEditor = false
        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand("a", in: editor)
        )
    }

    func testPerformSearchTextEditingCommandWithUnknownCommand() {
        let editor = makeFieldEditor()
        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand("q", in: editor)
        )
    }

    func testPerformSearchTextEditingCommandPasteWithEmptyPasteboard() {
        let editor = makeFieldEditor()
        editor.string = "hello"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PanelStressPaste-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        XCTAssertTrue(
            FloodlightPanelController.performSearchTextEditingCommand(
                "v",
                in: editor,
                pasteboard: pasteboard
            )
        )
        // Empty pasteboard -> nothing inserted.
        XCTAssertEqual(editor.string, "hello")
    }

    func testPerformSearchTextEditingCommandCutWithNoSelection() {
        let editor = makeFieldEditor()
        editor.string = "unchanged"
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PanelStressCut-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        // Cut with no selection returns true (it's a recognized command) but
        // leaves the string intact.
        XCTAssertTrue(
            FloodlightPanelController.performSearchTextEditingCommand(
                "x",
                in: editor,
                pasteboard: pasteboard
            )
        )
        XCTAssertEqual(editor.string, "unchanged")
    }

    func testPerformSearchTextEditingCommandCopyWithNoSelection() {
        let editor = makeFieldEditor()
        editor.string = "nothing"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        // Copy with no selection falls through to the default case and
        // returns false (it's a result-row shortcut, not a field-editor one).
        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand("c", in: editor)
        )
    }

    func testPerformSearchTextEditingCommandSelectAll() {
        let editor = makeFieldEditor()
        editor.string = "select me"
        XCTAssertTrue(
            FloodlightPanelController.performSearchTextEditingCommand("a", in: editor)
        )
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 9))
    }

    // MARK: - PanelCommand equality & hashability

    func testPanelCommandEquality() {
        XCTAssertEqual(FloodlightPanelController.PanelCommand.copySelection, .copySelection)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.chooseRoot, .chooseRoot)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.rebuildIndex, .rebuildIndex)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.revealSelection, .revealSelection)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.togglePreview, .togglePreview)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.unmatched, .unmatched)
        XCTAssertNotEqual(FloodlightPanelController.PanelCommand.copySelection, .unmatched)
    }

    func testPanelCommandHashability() {
        let set: Set<FloodlightPanelController.PanelCommand> = [
            .copySelection,
            .chooseRoot,
            .rebuildIndex,
            .revealSelection,
            .togglePreview,
            .unmatched,
        ]
        XCTAssertEqual(set.count, 6)
        XCTAssertTrue(set.contains(.copySelection))
        XCTAssertTrue(set.contains(.unmatched))
    }

    // MARK: - Helpers

    private func makeFieldEditor() -> NSTextView {
        let editor = NSTextView()
        editor.isFieldEditor = true
        return editor
    }
}
