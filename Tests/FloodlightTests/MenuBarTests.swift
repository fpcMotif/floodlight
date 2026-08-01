import AppKit
import XCTest
@testable import Floodlight

@MainActor
final class MenuBarTests: XCTestCase {
    func testStatusMenuExposesSettingsAndLauncherControls() throws {
        let menu = AppDelegate().makeStatusMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "Show Floodlight",
                "",
                "Settings…",
                "Choose Search Scope…",
                "Rebuild Index",
                "Launch at Login",
                "",
                "Quit Floodlight",
            ]
        )
        let settings = try XCTUnwrap(menu.items.first { $0.title == "Settings…" })
        XCTAssertEqual(settings.action.map(NSStringFromSelector), "showSettings")
    }
}
