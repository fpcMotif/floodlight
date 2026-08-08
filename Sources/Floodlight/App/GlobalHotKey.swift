import Carbon
import Foundation

enum FloodlightShortcut: String, CaseIterable, Identifiable, Sendable {
    case commandSpace
    case optionSpace

    static let preferenceKey = "global-shortcut"

    var id: String {
        rawValue
    }

    var modifierSymbol: String {
        switch self {
        case .commandSpace: "⌘"
        case .optionSpace: "⌥"
        }
    }

    var displayName: String {
        "\(modifierSymbol) Space"
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .commandSpace: UInt32(cmdKey)
        case .optionSpace: UInt32(optionKey)
        }
    }

    var fallback: FloodlightShortcut {
        switch self {
        case .commandSpace: .optionSpace
        case .optionSpace: .commandSpace
        }
    }

    static func preferred(in defaults: UserDefaults = .standard) -> FloodlightShortcut {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .commandSpace
    }

    func save(in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.preferenceKey)
    }
}
