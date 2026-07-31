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
}
