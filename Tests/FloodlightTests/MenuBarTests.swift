import AppKit
import Testing
@testable import Floodlight

@MainActor
struct MenuBarTests {
    @Test func statusMenuExposesSettingsAndLauncherControls() throws {
        let menu = AppDelegate().makeStatusMenu()

        #expect(menu.items.map(\.title) == [
            "Show Floodlight",
            "Clipboard History",
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
        let clipboard = try #require(menu.items.first { $0.title == "Clipboard History" })
        #expect(clipboard.action.map(NSStringFromSelector) == "showClipboardHistoryFromMenu")
    }

    @Test func clipboardHistoryItemHasNoKeyEquivalentUntilAShortcutIsActive() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()

        delegate.menuWillOpen(menu)

        let clipboard = try #require(menu.items.first { $0.title == "Clipboard History" })
        #expect(clipboard.keyEquivalent.isEmpty)
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
