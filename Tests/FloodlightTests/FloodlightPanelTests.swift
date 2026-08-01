import XCTest
@testable import Floodlight

@MainActor
final class FloodlightPanelTests: XCTestCase {
    func testToggleShowsPanelAfterAutomaticDeactivationHide() {
        XCTAssertFalse(
            FloodlightPanelController.shouldHideOnToggle(
                panelIsVisible: true,
                panelIsKeyWindow: false,
                applicationIsActive: false
            )
        )
    }

    func testToggleHidesActivelyPresentedPanel() {
        XCTAssertTrue(
            FloodlightPanelController.shouldHideOnToggle(
                panelIsVisible: true,
                panelIsKeyWindow: true,
                applicationIsActive: true
            )
        )
    }

    func testCommandDigitsOneThroughFiveMapToVisibleFilterSlots() {
        for digit in 1...5 {
            XCTAssertEqual(
                FloodlightPanelController.filterShortcutIndex(for: String(digit)),
                digit - 1
            )
        }

        for digit in [0, 6, 7, 8, 9] {
            XCTAssertNil(
                FloodlightPanelController.filterShortcutIndex(for: String(digit))
            )
        }
        XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: nil))
        XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: "x"))
        XCTAssertNil(FloodlightPanelController.filterShortcutIndex(for: "10"))
    }

    func testAllCommandDigitsAreRecognizedForConsumption() {
        for digit in 0...9 {
            XCTAssertEqual(
                FloodlightPanelController.commandDigit(for: String(digit)),
                digit
            )
        }
        XCTAssertNil(FloodlightPanelController.commandDigit(for: nil))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: "x"))
        XCTAssertNil(FloodlightPanelController.commandDigit(for: "10"))
    }

    func testPanelConsumesHandledKeyEquivalent() throws {
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
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
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
            )
        )

        XCTAssertTrue(panel.performKeyEquivalent(with: event))
        XCTAssertTrue(receivedEvent)
    }
}
