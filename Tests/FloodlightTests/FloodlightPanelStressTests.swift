import AppKit
import Foundation
import Testing
@testable import Floodlight

@MainActor
@Suite(.serialized)
struct FloodlightPanelStressTests {
    // MARK: - shouldHideOnToggle

    @Test func shouldHideOnToggleAllCombinations() {
        // Visible + key + active -> hide
        #expect(FloodlightPanelController.shouldHideOnToggle(
            panelIsVisible: true,
            panelIsKeyWindow: true,
            applicationIsActive: true
        ))
        // Any one false -> show
        #expect(!(FloodlightPanelController.shouldHideOnToggle(
            panelIsVisible: true,
            panelIsKeyWindow: true,
            applicationIsActive: false
        )))
        #expect(!(FloodlightPanelController.shouldHideOnToggle(
            panelIsVisible: true,
            panelIsKeyWindow: false,
            applicationIsActive: true
        )))
        #expect(!(FloodlightPanelController.shouldHideOnToggle(
            panelIsVisible: false,
            panelIsKeyWindow: true,
            applicationIsActive: true
        )))
        // All false -> show
        #expect(!(FloodlightPanelController.shouldHideOnToggle(
            panelIsVisible: false,
            panelIsKeyWindow: false,
            applicationIsActive: false
        )))
    }

    // MARK: - panelCommand

    @Test func panelCommandForEverySingleCharacter() {
        // Every lowercase letter: c, l, r (no shift), y map to known commands;
        // everything else is unmatched.
        #expect(FloodlightPanelController
            .panelCommand(for: "c", shiftHeld: false) == .copySelection)
        #expect(FloodlightPanelController.panelCommand(for: "l", shiftHeld: false) == .chooseRoot)
        #expect(FloodlightPanelController
            .panelCommand(for: "r", shiftHeld: false) == .revealSelection)
        #expect(FloodlightPanelController
            .panelCommand(for: "y", shiftHeld: false) == .togglePreview)

        let knownCommands: Set = ["c", "l", "r", "y"]
        for character in "abcdefghijklmnopqrstuvwxyz" {
            let ch = String(character)
            if knownCommands.contains(ch) {
                continue
            }
            #expect(
                FloodlightPanelController.panelCommand(for: ch, shiftHeld: false) == .unmatched,
                "expected unmatched for \(ch)"
            )
        }
    }

    @Test func panelCommandForNil() {
        #expect(FloodlightPanelController.panelCommand(for: nil, shiftHeld: false) == .unmatched)
    }

    @Test func panelCommandForMultiCharString() {
        #expect(FloodlightPanelController.panelCommand(for: "cl", shiftHeld: false) == .unmatched)
        #expect(FloodlightPanelController.panelCommand(for: "cc", shiftHeld: false) == .unmatched)
    }

    @Test func panelCommandForEmptyString() {
        #expect(FloodlightPanelController.panelCommand(for: "", shiftHeld: false) == .unmatched)
    }

    @Test func panelCommandShiftOnlyAffectsR() {
        #expect(FloodlightPanelController.panelCommand(for: "r", shiftHeld: true) == .rebuildIndex)
        #expect(FloodlightPanelController
            .panelCommand(for: "r", shiftHeld: false) == .revealSelection)
        // Shift is ignored for other commands.
        #expect(FloodlightPanelController.panelCommand(for: "c", shiftHeld: true) == .copySelection)
        #expect(FloodlightPanelController.panelCommand(for: "l", shiftHeld: true) == .chooseRoot)
        #expect(FloodlightPanelController.panelCommand(for: "y", shiftHeld: true) == .togglePreview)
    }

    // MARK: - commandDigit

    @Test func commandDigitForAllDigits() {
        for digit in 0...9 {
            #expect(FloodlightPanelController.commandDigit(for: String(digit)) == digit)
        }
    }

    @Test func commandDigitForNonDigits() {
        #expect(FloodlightPanelController.commandDigit(for: nil) == nil)
        #expect(FloodlightPanelController.commandDigit(for: "x") == nil)
        #expect(FloodlightPanelController.commandDigit(for: "10") == nil)
        #expect(FloodlightPanelController.commandDigit(for: "") == nil)
        #expect(FloodlightPanelController.commandDigit(for: " ") == nil)
    }

    // MARK: - filterShortcutIndex

    @Test func filterShortcutIndexForAllDigits() {
        for digit in 1...5 {
            #expect(FloodlightPanelController.filterShortcutIndex(for: String(digit)) == digit - 1)
        }
        for digit in [0, 6, 7, 8, 9] {
            #expect(FloodlightPanelController.filterShortcutIndex(for: String(digit)) == nil)
        }
    }

    // MARK: - performSearchTextEditingCommand

    @Test func performSearchTextEditingCommandWithNilEditor() {
        #expect(!(FloodlightPanelController.performSearchTextEditingCommand("a", in: nil)))
    }

    @Test func performSearchTextEditingCommandWithNonFieldEditor() {
        let editor = NSTextView()
        editor.isFieldEditor = false
        #expect(!(FloodlightPanelController.performSearchTextEditingCommand("a", in: editor)))
    }

    @Test func performSearchTextEditingCommandWithUnknownCommand() {
        let editor = makeFieldEditor()
        #expect(!(FloodlightPanelController.performSearchTextEditingCommand("q", in: editor)))
    }

    @Test func performSearchTextEditingCommandPasteWithEmptyPasteboard() {
        let editor = makeFieldEditor()
        editor.string = "hello"
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PanelStressPaste-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        #expect(FloodlightPanelController.performSearchTextEditingCommand(
            "v",
            in: editor,
            pasteboard: pasteboard
        ))
        // Empty pasteboard -> nothing inserted.
        #expect(editor.string == "hello")
    }

    @Test func performSearchTextEditingCommandCutWithNoSelection() {
        let editor = makeFieldEditor()
        editor.string = "unchanged"
        editor.setSelectedRange(NSRange(location: 4, length: 0))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("PanelStressCut-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        // Cut with no selection returns true (it's a recognized command) but
        // leaves the string intact.
        #expect(FloodlightPanelController.performSearchTextEditingCommand(
            "x",
            in: editor,
            pasteboard: pasteboard
        ))
        #expect(editor.string == "unchanged")
    }

    @Test func performSearchTextEditingCommandCopyWithNoSelection() {
        let editor = makeFieldEditor()
        editor.string = "nothing"
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        // Copy with no selection falls through to the default case and
        // returns false (it's a result-row shortcut, not a field-editor one).
        #expect(!(FloodlightPanelController.performSearchTextEditingCommand("c", in: editor)))
    }

    @Test func performSearchTextEditingCommandSelectAll() {
        let editor = makeFieldEditor()
        editor.string = "select me"
        #expect(FloodlightPanelController.performSearchTextEditingCommand("a", in: editor))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 9))
    }

    // MARK: - PanelCommand equality & hashability

    @Test func panelCommandEquality() {
        #expect(FloodlightPanelController.PanelCommand.copySelection == .copySelection)
        #expect(FloodlightPanelController.PanelCommand.chooseRoot == .chooseRoot)
        #expect(FloodlightPanelController.PanelCommand.rebuildIndex == .rebuildIndex)
        #expect(FloodlightPanelController.PanelCommand.revealSelection == .revealSelection)
        #expect(FloodlightPanelController.PanelCommand.togglePreview == .togglePreview)
        #expect(FloodlightPanelController.PanelCommand.unmatched == .unmatched)
        #expect(FloodlightPanelController.PanelCommand.copySelection != .unmatched)
    }

    @Test func panelCommandHashability() {
        let set: Set<FloodlightPanelController.PanelCommand> = [
            .copySelection,
            .chooseRoot,
            .rebuildIndex,
            .revealSelection,
            .togglePreview,
            .unmatched,
        ]
        #expect(set.count == 6)
        #expect(set.contains(.copySelection))
        #expect(set.contains(.unmatched))
    }

    // MARK: - Helpers

    private func makeFieldEditor() -> NSTextView {
        let editor = NSTextView()
        editor.isFieldEditor = true
        return editor
    }
}
