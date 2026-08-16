import AppKit
import Testing
@testable import Floodlight

@MainActor
struct MenuBarTests {
    @Test func statusMenuExposesSettingsAndLauncherControls() throws {
        let menu = AppDelegate().makeStatusMenu()

        #expect(menu.items.map(\.title) == [
            "Show Floodlight",
            "",
            "Settings…",
            "Choose Search Scope…",
            "Rebuild Index",
            "Launch at Login",
            "",
            "Quit Floodlight",
        ])
        let settings = try #require(menu.items.first { $0.title == "Settings…" })
        #expect(settings.action.map(NSStringFromSelector) == "showSettings")
    }

    @Test func mainMenuExposesStandardTextEditingCommands() throws {
        let mainMenu = AppDelegate().makeMainMenu()
        let editMenu = try #require(mainMenu.items.compactMap(\.submenu)
            .first { $0.title == "Edit" })

        #expect(editMenu.items.map(\.title) == [
            "Undo",
            "Redo",
            "",
            "Cut",
            "Copy",
            "Paste",
            "Select All",
        ])
        #expect(editMenu.items.compactMap { item in
            item.action.map(NSStringFromSelector)
        } == ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        #expect(editMenu.items.allSatisfy { $0.target == nil })
    }
}
