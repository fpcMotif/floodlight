import Carbon
import Foundation
import Testing
@testable import Floodlight

struct FloodlightShortcutStressTests {
    // MARK: - action choice sets

    @Test func summonActionOffersCommandThenOptionSpaceWithCommandSpaceDefault() {
        #expect(GlobalHotKeyAction.summonSearch.choices == [.commandSpace, .optionSpace])
        #expect(GlobalHotKeyAction.summonSearch.defaultShortcut == .commandSpace)
    }

    @Test func clipboardActionOffersShiftCommandCThenShiftCommandSpaceWithShiftCommandCDefault() {
        #expect(GlobalHotKeyAction.showClipboard.choices == [.shiftCommandC, .shiftCommandSpace])
        #expect(GlobalHotKeyAction.showClipboard.defaultShortcut == .shiftCommandC)
    }

    // MARK: - fallbacks stay within their action

    @Test func fallbacksStayWithinTheirAction() {
        for action in GlobalHotKeyAction.allCases {
            for choice in action.choices {
                #expect(action.choices.contains(choice.fallback))
                #expect(choice.fallback != choice)
            }
        }
    }

    // MARK: - raw values

    @Test func rawValues() {
        #expect(FloodlightShortcut.commandSpace.rawValue == "commandSpace")
        #expect(FloodlightShortcut.optionSpace.rawValue == "optionSpace")
        #expect(FloodlightShortcut.shiftCommandC.rawValue == "shiftCommandC")
        #expect(FloodlightShortcut.shiftCommandSpace.rawValue == "shiftCommandSpace")
    }

    // MARK: - display names

    @Test func displayNamesComposeModifierSymbolsAndAKeyLabel() {
        #expect(FloodlightShortcut.commandSpace.displayName == "⌘ Space")
        #expect(FloodlightShortcut.optionSpace.displayName == "⌥ Space")
        #expect(FloodlightShortcut.shiftCommandC.displayName == "⇧⌘ C")
        #expect(FloodlightShortcut.shiftCommandSpace.displayName == "⇧⌘ Space")
    }

    // MARK: - key codes and carbon modifiers

    @Test func keyCodesAndCarbonModifiersNameTheKey() {
        #expect(FloodlightShortcut.commandSpace.keyCode == UInt32(kVK_Space))
        #expect(FloodlightShortcut.optionSpace.keyCode == UInt32(kVK_Space))
        #expect(FloodlightShortcut.shiftCommandSpace.keyCode == UInt32(kVK_Space))
        #expect(FloodlightShortcut.shiftCommandC.keyCode == UInt32(kVK_ANSI_C))

        #expect(FloodlightShortcut.commandSpace.carbonModifiers == UInt32(cmdKey))
        #expect(FloodlightShortcut.optionSpace.carbonModifiers == UInt32(optionKey))
        #expect(FloodlightShortcut.shiftCommandC.carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(FloodlightShortcut.shiftCommandSpace.carbonModifiers == UInt32(cmdKey | shiftKey))
    }

    // MARK: - preference keys

    @Test func summonActionKeepsTheGlobalShortcutPreferenceKey() {
        #expect(GlobalHotKeyAction.summonSearch.preferenceKey == "global-shortcut")
        #expect(GlobalHotKeyAction.showClipboard.preferenceKey == "clipboard-shortcut")
    }

    // MARK: - preferred shortcut resolution

    @Test func aStoredSummonPreferenceStillResolvesAfterPreferencesBecomeActionScoped() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("optionSpace", forKey: GlobalHotKeyAction.summonSearch.preferenceKey)
        #expect(GlobalHotKeyAction.summonSearch.preferredShortcut(in: defaults) == .optionSpace)
    }

    @Test func anAbsentClipboardPreferenceResolvesToShiftCommandC() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(GlobalHotKeyAction.showClipboard.preferredShortcut(in: defaults) == .shiftCommandC)
    }

    @Test func aPreferenceNamingTheOtherActionsShortcutResolvesToTheDefault() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("commandSpace", forKey: GlobalHotKeyAction.showClipboard.preferenceKey)
        #expect(GlobalHotKeyAction.showClipboard.preferredShortcut(in: defaults) == .shiftCommandC)
    }

    @Test func preferredFallsBackForInvalidValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-shortcut", forKey: GlobalHotKeyAction.summonSearch.preferenceKey)
        #expect(GlobalHotKeyAction.summonSearch.preferredShortcut(in: defaults) == .commandSpace)
    }

    // MARK: - save persists

    @Test func savePersistsTheRawValueUnderTheActionsKey() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        GlobalHotKeyAction.summonSearch.save(.optionSpace, in: defaults)
        #expect(defaults.string(forKey: "global-shortcut") == "optionSpace")

        GlobalHotKeyAction.showClipboard.save(.shiftCommandSpace, in: defaults)
        #expect(defaults.string(forKey: "clipboard-shortcut") == "shiftCommandSpace")
    }

    // MARK: - id matches rawValue

    @Test func IDMatchesRawValue() {
        for shortcut in FloodlightShortcut.allCases {
            #expect(shortcut.id == shortcut.rawValue)
        }
    }

    // MARK: - Sendable conformance

    @Test func sendableConformance() async {
        // Sendable conformance is a compile-time guarantee. Constructing and
        // passing the value across an async boundary exercises it.
        let shortcut: FloodlightShortcut = .commandSpace
        await useSendable(shortcut)
    }

    // MARK: - Hashable

    @Test func hashableEquality() {
        #expect(FloodlightShortcut.commandSpace == FloodlightShortcut.commandSpace)
        #expect(FloodlightShortcut.commandSpace != FloodlightShortcut.optionSpace)
        let set = Set(FloodlightShortcut.allCases)
        #expect(set.count == FloodlightShortcut.allCases.count)
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "FloodlightShortcutStressTests-\(UUID().uuidString)"
        return try (#require(UserDefaults(suiteName: suiteName)), suiteName)
    }
}

private func useSendable(_ shortcut: FloodlightShortcut) async {
    // Touch the value to ensure it crosses the actor boundary.
    _ = shortcut.displayName
}
