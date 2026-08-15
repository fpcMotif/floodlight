import AppKit
import XCTest
@testable import Floodlight

/// The search field's command-selector routing as a pure map — the same
/// extracted-keymap style as `FloodlightPanelTests`' chord tests. What the
/// delegate consumes is exactly what maps to a command; anything unmapped
/// falls through to the field editor untouched.
@MainActor
final class SearchFieldKeymapTests: XCTestCase {
    private func command(
        _ selector: Selector,
        commandKeyIsDown: Bool = false,
        textIsEmpty: Bool = false
    ) -> FloodlightTextField.FieldCommand? {
        FloodlightTextField.fieldCommand(
            for: selector,
            commandKeyIsDown: commandKeyIsDown,
            textIsEmpty: textIsEmpty
        )
    }

    func testReturnMapsToSubmitAndCommandReturnToCommandSubmit() {
        XCTAssertEqual(command(#selector(NSResponder.insertNewline(_:))), .submit)
        XCTAssertEqual(
            command(#selector(NSResponder.insertNewline(_:)), commandKeyIsDown: true),
            .commandSubmit
        )
        XCTAssertEqual(
            command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))),
            .submit
        )
    }

    func testEscapeMapsToCancel() {
        XCTAssertEqual(command(#selector(NSResponder.cancelOperation(_:))), .cancel)
    }

    func testTabAlwaysMapsToTabSoFocusNeverTraverses() {
        // Consumed with or without text — insert-tab must never reach the
        // field editor's default focus traversal.
        XCTAssertEqual(command(#selector(NSResponder.insertTab(_:))), .tab)
        XCTAssertEqual(
            command(#selector(NSResponder.insertTab(_:)), textIsEmpty: true),
            .tab
        )
    }

    func testShiftTabMapsToShiftTab() {
        XCTAssertEqual(command(#selector(NSResponder.insertBacktab(_:))), .shiftTab)
        XCTAssertEqual(
            command(#selector(NSResponder.insertBacktab(_:)), textIsEmpty: true),
            .shiftTab
        )
    }

    func testBackspaceIsOnlyClaimedWhenTheFieldIsEmpty() {
        XCTAssertEqual(
            command(#selector(NSResponder.deleteBackward(_:)), textIsEmpty: true),
            .backspaceOnEmptyText
        )
        XCTAssertNil(
            command(#selector(NSResponder.deleteBackward(_:)), textIsEmpty: false),
            "backspace with text present is ordinary editing, never a mode event"
        )
    }

    func testUnrelatedSelectorsFallThroughToTheFieldEditor() {
        for selector in [
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.deleteForward(_:)),
            #selector(NSResponder.insertText(_:)),
        ] {
            XCTAssertNil(command(selector), String(describing: selector))
            XCTAssertNil(command(selector, textIsEmpty: true), String(describing: selector))
        }
    }
}
