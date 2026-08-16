import AppKit
import Testing
@testable import Floodlight

/// The search field's command-selector routing as a pure map — the same
/// extracted-keymap style as `FloodlightPanelTests`' chord tests. What the
/// delegate consumes is exactly what maps to a command; anything unmapped
/// falls through to the field editor untouched.
@MainActor
struct SearchFieldKeymapTests {
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

    @Test func returnMapsToSubmitAndCommandReturnToCommandSubmit() {
        #expect(command(#selector(NSResponder.insertNewline(_:))) == .submit)
        #expect(command(#selector(NSResponder.insertNewline(_:)), commandKeyIsDown: true) ==
            .commandSubmit)
        #expect(command(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))) == .submit)
    }

    @Test func escapeMapsToCancel() {
        #expect(command(#selector(NSResponder.cancelOperation(_:))) == .cancel)
    }

    @Test func tabAlwaysMapsToTabSoFocusNeverTraverses() {
        // Consumed with or without text — insert-tab must never reach the
        // field editor's default focus traversal.
        #expect(command(#selector(NSResponder.insertTab(_:))) == .tab)
        #expect(command(#selector(NSResponder.insertTab(_:)), textIsEmpty: true) == .tab)
    }

    @Test func shiftTabMapsToShiftTab() {
        #expect(command(#selector(NSResponder.insertBacktab(_:))) == .shiftTab)
        #expect(command(#selector(NSResponder.insertBacktab(_:)), textIsEmpty: true) == .shiftTab)
    }

    @Test func backspaceIsOnlyClaimedWhenTheFieldIsEmpty() {
        #expect(command(#selector(NSResponder.deleteBackward(_:)), textIsEmpty: true) ==
            .backspaceOnEmptyText)
        #expect(
            command(#selector(NSResponder.deleteBackward(_:)), textIsEmpty: false) == nil,
            "backspace with text present is ordinary editing, never a mode event"
        )
    }

    @Test func unrelatedSelectorsFallThroughToTheFieldEditor() {
        for selector in [
            #selector(NSResponder.moveDown(_:)),
            #selector(NSResponder.moveUp(_:)),
            #selector(NSResponder.deleteForward(_:)),
            #selector(NSResponder.insertText(_:)),
        ] {
            #expect(command(selector) == nil, "\(String(describing: selector))")
            #expect(command(selector, textIsEmpty: true) == nil, "\(String(describing: selector))")
        }
    }
}
