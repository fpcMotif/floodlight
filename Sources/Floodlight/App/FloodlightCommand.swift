import AppKit

/// Every keyboard command Floodlight publishes, with the chord that invokes it
/// and the title menus show for it.
///
/// A command is declared once, here. Both menus render from this table and the
/// panel's key handler matches against it, so a shortcut cannot drift between
/// the menu bar and the panel — there is one row to change.
enum FloodlightCommand: CaseIterable, Hashable, Sendable {
    case showSearch
    case showSettings
    case chooseScope
    case rebuildIndex
    case revealSelection
    case copySelection
    case togglePreview
    case quit

    var title: String {
        switch self {
        case .showSearch: "Show Floodlight"
        case .showSettings: "Settings…"
        case .chooseScope: "Choose Search Scope…"
        case .rebuildIndex: "Rebuild Index"
        case .revealSelection: "Reveal in Finder"
        case .copySelection: "Copy"
        case .togglePreview: "Quick Look"
        case .quit: "Quit Floodlight"
        }
    }

    /// The character AppKit matches, lowercased. Empty means the command has no
    /// chord and is reachable only by clicking it in a menu.
    var keyEquivalent: String {
        switch self {
        case .showSearch: " "
        case .showSettings: ","
        case .chooseScope: "l"
        case .rebuildIndex: "r"
        case .revealSelection: "r"
        case .copySelection: "c"
        case .togglePreview: "y"
        case .quit: "q"
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .rebuildIndex: [.command, .shift]
        default: [.command]
        }
    }

    /// Commands the panel answers itself while it is the key window.
    ///
    /// These reach the panel through `performKeyEquivalent`, which AppKit
    /// consults before the main menu — so for these rows the panel wins while
    /// it is open and the menu serves the same command otherwise.
    static let panelCommands: [FloodlightCommand] = [
        .copySelection,
        .chooseScope,
        .rebuildIndex,
        .revealSelection,
        .togglePreview,
    ]

    /// The command `characters` invokes inside the panel, or nil.
    ///
    /// An exact modifier match wins, so ⌘⇧R rebuilds rather than revealing.
    /// Anything left over falls back to the plain ⌘ row, which keeps ⌘⇧C
    /// copying instead of dropping through to the field editor.
    static func panelCommand(for characters: String?, shiftHeld: Bool) -> FloodlightCommand? {
        guard let characters, !characters.isEmpty else { return nil }
        let pressed: NSEvent.ModifierFlags = shiftHeld ? [.command, .shift] : [.command]

        if let exact = panelCommands.first(where: {
            $0.keyEquivalent == characters && $0.modifiers == pressed
        }) {
            return exact
        }
        return panelCommands.first {
            $0.keyEquivalent == characters && $0.modifiers == [.command]
        }
    }
}

extension NSMenuItem {
    /// Builds a menu item for `command`, taking its title and chord from the
    /// table rather than restating them at the call site.
    convenience init(command: FloodlightCommand, action: Selector, target: AnyObject?) {
        self.init(
            title: command.title,
            action: action,
            keyEquivalent: command.keyEquivalent
        )
        keyEquivalentModifierMask = command.modifiers
        self.target = target
    }
}
