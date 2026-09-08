import Carbon
import Foundation

enum FloodlightShortcut: String, CaseIterable, Identifiable, Sendable {
    case commandSpace
    case optionSpace
    case shiftCommandC
    case shiftCommandSpace

    var id: String {
        rawValue
    }

    var modifierSymbol: String {
        switch self {
        case .commandSpace: "⌘"
        case .optionSpace: "⌥"
        case .shiftCommandC, .shiftCommandSpace: "⇧⌘"
        }
    }

    private var keyLabel: String {
        switch self {
        case .commandSpace, .optionSpace, .shiftCommandSpace: "Space"
        case .shiftCommandC: "C"
        }
    }

    var displayName: String {
        "\(modifierSymbol) \(keyLabel)"
    }

    var keyCode: UInt32 {
        switch self {
        case .commandSpace, .optionSpace, .shiftCommandSpace: UInt32(kVK_Space)
        case .shiftCommandC: UInt32(kVK_ANSI_C)
        }
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .commandSpace: UInt32(cmdKey)
        case .optionSpace: UInt32(optionKey)
        case .shiftCommandC, .shiftCommandSpace: UInt32(cmdKey | shiftKey)
        }
    }

    var fallback: FloodlightShortcut {
        switch self {
        case .commandSpace: .optionSpace
        case .optionSpace: .commandSpace
        case .shiftCommandC: .shiftCommandSpace
        case .shiftCommandSpace: .shiftCommandC
        }
    }
}

/// One system-wide hot key can summon the Search Session, and a second can
/// open the clipboard board. Choice sets and preferences live per action so a
/// picker for one never offers, or falls back to, the other's shortcuts.
enum GlobalHotKeyAction: CaseIterable, Hashable, Sendable {
    case summonSearch
    case showClipboard

    var preferenceKey: String {
        switch self {
        case .summonSearch: "global-shortcut"
        case .showClipboard: "clipboard-shortcut"
        }
    }

    var choices: [FloodlightShortcut] {
        switch self {
        case .summonSearch: [.commandSpace, .optionSpace]
        case .showClipboard: [.shiftCommandC, .shiftCommandSpace]
        }
    }

    var defaultShortcut: FloodlightShortcut {
        switch self {
        case .summonSearch: .commandSpace
        case .showClipboard: .shiftCommandC
        }
    }

    func preferredShortcut(in defaults: UserDefaults = .standard) -> FloodlightShortcut {
        guard let stored = defaults.string(forKey: preferenceKey)
            .flatMap(FloodlightShortcut.init(rawValue:)),
            choices.contains(stored)
        else {
            return defaultShortcut
        }
        return stored
    }

    func save(_ shortcut: FloodlightShortcut, in defaults: UserDefaults = .standard) {
        defaults.set(shortcut.rawValue, forKey: preferenceKey)
    }
}
