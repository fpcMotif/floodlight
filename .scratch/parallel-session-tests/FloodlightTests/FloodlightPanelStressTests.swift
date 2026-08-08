import AppKit
import Foundation
import XCTest
@testable import Floodlight

/// Harsh, critical stress tests for `FloodlightPanelController` — adversarial
/// inputs and boundary conditions for panel command routing and key handling.
@MainActor
final class FloodlightPanelStressTests: XCTestCase {

    // MARK: - shouldHideOnToggle all combinations

    func testShouldHideOnToggleAllCombinations() {
        // (visible, key, active) -> should hide
        let cases: [(Bool, Bool, Bool, Bool)] = [
            (true, true, true, true),   // all true -> hide
            (true, true, false, false),  // not active -> show
            (true, false, true, false),  // not key -> show
            (true, false, false, false), // not key, not active -> show
            (false, true, true, false),  // not visible -> show
            (false, false, false, false), // all false -> show
            (false, true, false, false),
            (false, false, true, false),
        ]
        for (visible, key, active, expected) in cases {
            XCTAssertEqual(
                FloodlightPanelController.shouldHideOnToggle(
                    panelIsVisible: visible,
                    panelIsKeyWindow: key,
                    applicationIsActive: active
                ),
                expected,
                "visible=\(visible) key=\(key) active=\(active) should be \(expected)"
            )
        }
    }

    // MARK: - panelCommand exhaustive

    func testPanelCommandForAllSingleCharacters() {
        let knownCommands: Set<String> = ["c", "l", "r", "y"]
        for c in "abcdefghijklmnopqrstuvwxyz" {
            let command = FloodlightPanelController.panelCommand(for: String(c), shiftHeld: false)
            if knownCommands.contains(String(c)) {
                XCTAssertNotEqual(command, .unmatched, "'\(c)' should map to a command")
            } else {
                XCTAssertEqual(command, .unmatched, "'\(c)' should be unmatched")
            }
        }
    }

    func testPanelCommandForNil() {
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: nil, shiftHeld: false), .unmatched)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: nil, shiftHeld: true), .unmatched)
    }

    func testPanelCommandForMultiCharString() {
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "cl", shiftHeld: false), .unmatched)
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "abc", shiftHeld: false), .unmatched)
    }

    func testPanelCommandForEmptyString() {
        XCTAssertEqual(FloodlightPanelController.panelCommand(for: "", shiftHeld: false), .unmatched)
    }

    func testPanelCommandShiftOnlyAffectsR() {
        for c in ["c", "l", "y"] {
            let noShift = FloodlightPanelController.panelCommand(for: c, shiftHeld: false)
            let withShift = FloodlightPanelController.panelCommand(for: c, shiftHeld: true)
            XCTAssertEqual(noShift, withShift, "shift should not affect '\(c)'")
        }
        // r is affected by shift
        let rNoShift = FloodlightPanelController.panelCommand(for: "r", shiftHeld: false)
        let rWithShift = FloodlightPanelController.panelCommand(for: "r", shiftHeld: true)
        XCTAssertNotEqual(rNoShift, rWithShift)
    }

    // MARK: - commandDigit exhaustive

    func testCommandDigitForAllDigits() {
        for d in 0...9 {
            XCTAssertEqual(FloodlightPanelController.commandDigit(for: String(d)), d)
        }
    }

    func testCommandDigitForNonDigits() {
        for c in "abcdefghijklmnopqrstuvwxyz" {
            XCTAssertNil(FloodlightPanelController.commandDigit(for: String(c)))
        }
        XCTAssertNil(FloodlightPanelController.commandDigit(for: nil))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: ""))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: "10"))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: "ab"))
    }

    // MARK: - filterShortcutIndex

    func testFilterShortcutIndexForAllDigits() {
        for d in 1...5 {
            XCTAssertEqual(FloodlightPanelController.filterShortcutIndex(for: String(d)), d - 1)
        }
        for d in [0, 6, 7, 8, 9] {
            XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: String(d)))
        }
    }

    func testFilterShortcutIndexForNonDigits() {
        XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: "a"))
        XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: nil))
        XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: ""))
        XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: "10"))
    }

    // MARK: - performSearchTextEditingCommand edge cases

    func testPerformSearchTextEditingCommandWithNilEditor() {
        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand("a", in: nil)
        )
        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand("c", in: nil)
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
        let editor = NSTextView()
        editor.isFieldEditor = true
        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand("z", in: editor)
        )
        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand(nil, in: editor)
        )
    }

    func testPerformSearchTextEditingCommandPasteWithEmptyPasteboard() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "hello"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("Test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        XCTAssertTrue(
            FloodlightPanelController.performSearchTextEditingCommand(
                "v", in: editor, pasteboard: pasteboard
            )
        )
        // Pasting nothing should not change the string
        XCTAssertEqual(editor.string, "hello")
    }

    func testPerformSearchTextEditingCommandCutWithNoSelection() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "hello"
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(
            FloodlightPanelController.performSearchTextEditingCommand("x", in: editor)
        )
        // Cut with no selection should not change the string
        XCTAssertEqual(editor.string, "hello")
    }

    func testPerformSearchTextEditingCommandCopyWithNoSelection() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "hello"
        editor.setSelectedRange(NSRange(location: 5, length: 0))

        XCTAssertFalse(
            FloodlightPanelController.performSearchTextEditingCommand("c", in: editor)
        )
    }

    func testPerformSearchTextEditingCommandSelectAll() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "hello world"
        editor.setSelectedRange(NSRange(location: 0, length: 0))

        XCTAssertTrue(
            FloodlightPanelController.performSearchTextEditingCommand("a", in: editor)
        )
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 11))
    }

    // MARK: - PanelCommand equality

    func testPanelCommandEquality() {
        XCTAssertEqual(FloodlightPanelController.PanelCommand.copySelection, .copySelection)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.chooseRoot, .chooseRoot)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.rebuildIndex, .rebuildIndex)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.revealSelection, .revealSelection)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.togglePreview, .togglePreview)
        XCTAssertEqual(FloodlightPanelController.PanelCommand.unmatched, .unmatched)
        XCTAssertNotEqual(FloodlightPanelController.PanelCommand.copySelection, .unmatched)
    }

    func testPanelCommandIsHashable() {
        let commands: Set<FloodlightPanelController.PanelCommand> = [
            .copySelection, .chooseRoot, .rebuildIndex,
            .revealSelection, .togglePreview, .unmatched,
            .copySelection, // duplicate
        ]
        XCTAssertEqual(commands.count, 6)
    }
}
