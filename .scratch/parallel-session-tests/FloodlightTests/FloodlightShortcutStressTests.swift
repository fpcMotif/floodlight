import Carbon
import Foundation
import XCTest
@testable import Floodlight

/// Comprehensive stress tests for `FloodlightShortcut` — all cases,
/// preference persistence, fallback relationships, and display properties.
final class FloodlightShortcutStressTests: XCTestCase {

    // MARK: - All cases

    func testAllCasesAreComplete() {
        XCTAssertEqual(FloodlightShortcut.allCases.count, 2)
        XCTAssertTrue(FloodlightShortcut.allCases.contains(.commandSpace))
        XCTAssertTrue(FloodlightShortcut.allCases.contains(.optionSpace))
    }

    // MARK: - Raw values

    func testRawValues() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.rawValue, "commandSpace")
        XCTAssertEqual(FloodlightShortcut.optionSpace.rawValue, "optionSpace")
    }

    // MARK: - Display properties

    func testModifierSymbols() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.modifierSymbol, "⌘")
        XCTAssertEqual(FloodlightShortcut.optionSpace.modifierSymbol, "⌥")
    }

    func testModifierNames() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.modifierName, "Command")
        XCTAssertEqual(FloodlightShortcut.optionSpace.modifierName, "Option")
    }

    func testDisplayNames() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.displayName, "⌘ Space")
        XCTAssertEqual(FloodlightShortcut.optionSpace.displayName, "⌥ Space")
    }

    // MARK: - Carbon modifiers

    func testCarbonModifiers() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.carbonModifiers, UInt32(cmdKey))
        XCTAssertEqual(FloodlightShortcut.optionSpace.carbonModifiers, UInt32(optionKey))
    }

    // MARK: - Fallback

    func testFallbacksAreMutual() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.fallback, .optionSpace)
        XCTAssertEqual(FloodlightShortcut.optionSpace.fallback, .commandSpace)
    }

    // MARK: - Preference key

    func testPreferenceKey() {
        XCTAssertEqual(FloodlightShortcut.preferenceKey, "global-shortcut")
    }

    // MARK: - Preferred

    func testPreferredDefaultsToCommandSpace() throws {
        let suiteName = "FloodlightShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(FloodlightShortcut.preferred(in: defaults), .commandSpace)
    }

    func testPreferredReturnsSavedValue() throws {
        let suiteName = "FloodlightShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FloodlightShortcut.optionSpace.save(in: defaults)
        XCTAssertEqual(FloodlightShortcut.preferred(in: defaults), .optionSpace)
    }

    func testPreferredFallsBackToCommandSpaceForInvalidValue() throws {
        let suiteName = "FloodlightShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("invalid-shortcut", forKey: FloodlightShortcut.preferenceKey)
        XCTAssertEqual(FloodlightShortcut.preferred(in: defaults), .commandSpace)
    }

    func testSavePersistsValue() throws {
        let suiteName = "FloodlightShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FloodlightShortcut.commandSpace.save(in: defaults)
        XCTAssertEqual(defaults.string(forKey: FloodlightShortcut.preferenceKey), "commandSpace")

        FloodlightShortcut.optionSpace.save(in: defaults)
        XCTAssertEqual(defaults.string(forKey: FloodlightShortcut.preferenceKey), "optionSpace")
    }

    // MARK: - Identifiable

    func testIDMatchesRawValue() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.id, "commandSpace")
        XCTAssertEqual(FloodlightShortcut.optionSpace.id, "optionSpace")
    }

    // MARK: - Sendable conformance

    func testShortcutIsSendable() {
        let shortcut: FloodlightShortcut = .commandSpace
        let sendable: @Sendable () -> FloodlightShortcut = { shortcut }
        XCTAssertEqual(sendable(), .commandSpace)
    }

    // MARK: - Hashable

    func testShortcutIsHashable() {
        let set: Set<FloodlightShortcut> = [.commandSpace, .optionSpace, .commandSpace]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - CaseIterable

    func testCaseIterableOrder() {
        XCTAssertEqual(FloodlightShortcut.allCases, [.commandSpace, .optionSpace])
    }
}
