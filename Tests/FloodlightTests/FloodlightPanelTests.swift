import AppKit
import Testing
@testable import Floodlight

@MainActor
@Suite(.serialized)
struct FloodlightPanelTests {
    @Test func toggleShowsPanelAfterAutomaticDeactivationHide() {
        #expect(!(FloodlightPanelController.shouldHideOnToggle(
            panelIsVisible: true,
            panelIsKeyWindow: false,
            applicationIsActive: false
        )))
    }

    @Test func toggleHidesActivelyPresentedPanel() {
        #expect(FloodlightPanelController.shouldHideOnToggle(
            panelIsVisible: true,
            panelIsKeyWindow: true,
            applicationIsActive: true
        ))
    }

    @Test func immediateReopenStartsWithAResetSearchSession() {
        let model = makeSearchCoordinatorWithInertPresentation()
        let controller = FloodlightPanelController(model: model)
        model.query = "stale query"
        controller.panel.orderFront(nil)
        defer { controller.panel.orderOut(nil) }

        controller.hide()
        controller.show()

        #expect(model.query.isEmpty)
        #expect(controller.panel.isVisible)
    }

    @Test func commandDigitsOneThroughFiveMapToVisibleFilterSlots() {
        for digit in 1...5 {
            #expect(FloodlightPanelController.filterShortcutIndex(for: String(digit)) == digit - 1)
        }

        for digit in [0, 6, 7, 8, 9] {
            #expect(FloodlightPanelController.filterShortcutIndex(for: String(digit)) == nil)
        }
        #expect(FloodlightPanelController.filterShortcutIndex(for: nil) == nil)
        #expect(FloodlightPanelController.filterShortcutIndex(for: "x") == nil)
        #expect(FloodlightPanelController.filterShortcutIndex(for: "10") == nil)
    }

    @Test func allCommandDigitsAreRecognizedForConsumption() {
        for digit in 0...9 {
            #expect(FloodlightPanelController.commandDigit(for: String(digit)) == digit)
        }
        #expect(FloodlightPanelController.commandDigit(for: nil) == nil)
        #expect(FloodlightPanelController.commandDigit(for: "x") == nil)
        #expect(FloodlightPanelController.commandDigit(for: "10") == nil)
    }

    @Test func commandChordsMapToPanelCommands() {
        #expect(FloodlightPanelController
            .panelCommand(for: "c", shiftHeld: false) == .copySelection)
        #expect(FloodlightPanelController.panelCommand(for: "l", shiftHeld: false) == .chooseRoot)
        #expect(FloodlightPanelController
            .panelCommand(for: "y", shiftHeld: false) == .togglePreview)
        #expect(FloodlightPanelController
            .panelCommand(for: "\r", shiftHeld: false) == .revealSelection)
        #expect(FloodlightPanelController
            .panelCommand(for: "\n", shiftHeld: false) == .revealSelection)
    }

    @Test func shiftDistinguishesRebuildIndexFromRevealSelection() {
        #expect(FloodlightPanelController.panelCommand(for: "r", shiftHeld: true) == .rebuildIndex)
        #expect(FloodlightPanelController
            .panelCommand(for: "r", shiftHeld: false) == .revealSelection)
    }

    @Test func shiftIsIgnoredByChordsOtherThanRebuildIndex() {
        #expect(FloodlightPanelController.panelCommand(for: "c", shiftHeld: true) == .copySelection)
        #expect(FloodlightPanelController.panelCommand(for: "l", shiftHeld: true) == .chooseRoot)
        #expect(FloodlightPanelController.panelCommand(for: "y", shiftHeld: true) == .togglePreview)
    }

    @Test func unmatchedCharactersProduceNoPanelCommand() {
        #expect(FloodlightPanelController.panelCommand(for: "q", shiftHeld: false) == .unmatched)
        #expect(FloodlightPanelController.panelCommand(for: "cl", shiftHeld: false) == .unmatched)
        #expect(FloodlightPanelController.panelCommand(for: nil, shiftHeld: false) == .unmatched)
    }

    @Test func searchFieldHandlesStandardEditingShortcutsDirectly() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "Floodlight"
        editor.setSelectedRange(NSRange(location: 0, length: 4))
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("FloodlightPanelTests-\(UUID().uuidString)")
        )
        defer { pasteboard.releaseGlobally() }

        #expect(FloodlightPanelController.performSearchTextEditingCommand(
            "c",
            in: editor,
            pasteboard: pasteboard
        ))
        #expect(pasteboard.string(forType: .string) == "Floo")

        #expect(FloodlightPanelController.performSearchTextEditingCommand(
            "x",
            in: editor,
            pasteboard: pasteboard
        ))
        #expect(editor.string == "dlight")
        #expect(pasteboard.string(forType: .string) == "Floo")

        pasteboard.clearContents()
        pasteboard.setString(" search", forType: .string)
        editor.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(FloodlightPanelController.performSearchTextEditingCommand(
            "v",
            in: editor,
            pasteboard: pasteboard
        ))
        #expect(editor.string == "dlight search")

        #expect(FloodlightPanelController.performSearchTextEditingCommand(
            "a",
            in: editor,
            pasteboard: pasteboard
        ))
        #expect(editor.selectedRange() == NSRange(location: 0, length: 13))
    }

    @Test func copyWithoutSelectedSearchTextRemainsAResultShortcut() {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.string = "Floodlight"
        editor.setSelectedRange(NSRange(location: 10, length: 0))

        #expect(!(FloodlightPanelController.performSearchTextEditingCommand(
            "c",
            in: editor
        )))
    }

    @Test func panelConsumesHandledKeyEquivalent() throws {
        let panel = FloodlightPanel(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        var receivedEvent = false
        panel.keyEquivalentHandler = { _ in
            receivedEvent = true
            return true
        }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "1",
            charactersIgnoringModifiers: "1",
            isARepeat: false,
            keyCode: 18
        ))

        #expect(panel.performKeyEquivalent(with: event))
        #expect(receivedEvent)
    }
}
