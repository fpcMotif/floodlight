import Carbon
import Foundation
import Testing
@testable import Floodlight

struct FloodlightShortcutStressTests {
    // MARK: - allCases completeness

    @Test func allCasesContainsBothShortcuts() {
        #expect(FloodlightShortcut.allCases.count == 2)
        #expect(FloodlightShortcut.allCases.contains(.commandSpace))
        #expect(FloodlightShortcut.allCases.contains(.optionSpace))
    }

    @Test func caseIterableOrderIsCommandThenOption() {
        #expect(FloodlightShortcut.allCases == [.commandSpace, .optionSpace])
    }

    // MARK: - raw values

    @Test func rawValues() {
        #expect(FloodlightShortcut.commandSpace.rawValue == "commandSpace")
        #expect(FloodlightShortcut.optionSpace.rawValue == "optionSpace")
    }

    // MARK: - modifier symbols

    @Test func modifierSymbols() {
        #expect(FloodlightShortcut.commandSpace.modifierSymbol == "⌘")
        #expect(FloodlightShortcut.optionSpace.modifierSymbol == "⌥")
    }

    // MARK: - modifier names

    @Test func modifierNames() {
        #expect(FloodlightShortcut.commandSpace.modifierName == "Command")
        #expect(FloodlightShortcut.optionSpace.modifierName == "Option")
    }

    // MARK: - display names

    @Test func displayNames() {
        #expect(FloodlightShortcut.commandSpace.displayName == "⌘ Space")
        #expect(FloodlightShortcut.optionSpace.displayName == "⌥ Space")
    }

    // MARK: - carbon modifiers

    @Test func carbonModifiers() {
        #expect(FloodlightShortcut.commandSpace.carbonModifiers == UInt32(cmdKey))
        #expect(FloodlightShortcut.optionSpace.carbonModifiers == UInt32(optionKey))
    }

    // MARK: - fallbacks mutual

    @Test func fallbacksAreMutual() {
        #expect(FloodlightShortcut.commandSpace.fallback == .optionSpace)
        #expect(FloodlightShortcut.optionSpace.fallback == .commandSpace)
    }

    // MARK: - preference key

    @Test func preferenceKey() {
        #expect(FloodlightShortcut.preferenceKey == "global-shortcut")
    }

    // MARK: - preferred

    @Test func preferredDefaultsToCommandSpace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(FloodlightShortcut.preferred(in: defaults) == .commandSpace)
    }

    @Test func preferredReturnsSavedValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FloodlightShortcut.optionSpace.save(in: defaults)
        #expect(FloodlightShortcut.preferred(in: defaults) == .optionSpace)
    }

    @Test func preferredFallsBackForInvalidValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-shortcut", forKey: FloodlightShortcut.preferenceKey)
        #expect(FloodlightShortcut.preferred(in: defaults) == .commandSpace)
    }

    // MARK: - save persists

    @Test func savePersistsRawValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FloodlightShortcut.optionSpace.save(in: defaults)
        #expect(defaults.string(forKey: FloodlightShortcut.preferenceKey) == "optionSpace")

        FloodlightShortcut.commandSpace.save(in: defaults)
        #expect(defaults.string(forKey: FloodlightShortcut.preferenceKey) == "commandSpace")
    }

    // MARK: - id matches rawValue

    @Test func IDMatchesRawValue() {
        #expect(FloodlightShortcut.commandSpace.id == FloodlightShortcut.commandSpace.rawValue)
        #expect(FloodlightShortcut.optionSpace.id == FloodlightShortcut.optionSpace.rawValue)
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
        let set: Set<FloodlightShortcut> = [.commandSpace, .optionSpace, .commandSpace]
        #expect(set.count == 2)
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
