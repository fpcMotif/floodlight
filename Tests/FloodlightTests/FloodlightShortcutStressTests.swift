import Carbon
import Foundation
import XCTest
@testable import Floodlight

final class FloodlightShortcutStressTests: XCTestCase {
    // MARK: - allCases completeness

    func testAllCasesContainsBothShortcuts() {
        XCTAssertEqual(FloodlightShortcut.allCases.count, 2)
        XCTAssertTrue(FloodlightShortcut.allCases.contains(.commandSpace))
        XCTAssertTrue(FloodlightShortcut.allCases.contains(.optionSpace))
    }

    func testCaseIterableOrderIsCommandThenOption() {
        XCTAssertEqual(
            FloodlightShortcut.allCases,
            [.commandSpace, .optionSpace]
        )
    }

    // MARK: - raw values

    func testRawValues() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.rawValue, "commandSpace")
        XCTAssertEqual(FloodlightShortcut.optionSpace.rawValue, "optionSpace")
    }

    // MARK: - modifier symbols

    func testModifierSymbols() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.modifierSymbol, "⌘")
        XCTAssertEqual(FloodlightShortcut.optionSpace.modifierSymbol, "⌥")
    }

    // MARK: - modifier names

    func testModifierNames() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.modifierName, "Command")
        XCTAssertEqual(FloodlightShortcut.optionSpace.modifierName, "Option")
    }

    // MARK: - display names

    func testDisplayNames() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.displayName, "⌘ Space")
        XCTAssertEqual(FloodlightShortcut.optionSpace.displayName, "⌥ Space")
    }

    // MARK: - carbon modifiers

    func testCarbonModifiers() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.carbonModifiers, UInt32(cmdKey))
        XCTAssertEqual(FloodlightShortcut.optionSpace.carbonModifiers, UInt32(optionKey))
    }

    // MARK: - fallbacks mutual

    func testFallbacksAreMutual() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.fallback, .optionSpace)
        XCTAssertEqual(FloodlightShortcut.optionSpace.fallback, .commandSpace)
    }

    // MARK: - preference key

    func testPreferenceKey() {
        XCTAssertEqual(FloodlightShortcut.preferenceKey, "global-shortcut")
    }

    // MARK: - preferred

    func testPreferredDefaultsToCommandSpace() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(FloodlightShortcut.preferred(in: defaults), .commandSpace)
    }

    func testPreferredReturnsSavedValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FloodlightShortcut.optionSpace.save(in: defaults)
        XCTAssertEqual(FloodlightShortcut.preferred(in: defaults), .optionSpace)
    }

    func testPreferredFallsBackForInvalidValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-shortcut", forKey: FloodlightShortcut.preferenceKey)
        XCTAssertEqual(FloodlightShortcut.preferred(in: defaults), .commandSpace)
    }

    // MARK: - save persists

    func testSavePersistsRawValue() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        FloodlightShortcut.optionSpace.save(in: defaults)
        XCTAssertEqual(
            defaults.string(forKey: FloodlightShortcut.preferenceKey),
            "optionSpace"
        )

        FloodlightShortcut.commandSpace.save(in: defaults)
        XCTAssertEqual(
            defaults.string(forKey: FloodlightShortcut.preferenceKey),
            "commandSpace"
        )
    }

    // MARK: - id matches rawValue

    func testIDMatchesRawValue() {
        XCTAssertEqual(FloodlightShortcut.commandSpace.id, FloodlightShortcut.commandSpace.rawValue)
        XCTAssertEqual(FloodlightShortcut.optionSpace.id, FloodlightShortcut.optionSpace.rawValue)
    }

    // MARK: - Sendable conformance

    func testSendableConformance() {
        // Sendable conformance is a compile-time guarantee. Constructing and
        // passing the value across an async boundary exercises it.
        let shortcut: FloodlightShortcut = .commandSpace
        let expectation = expectation(description: "sendable-cross-actor")
        Task {
            await useSendable(shortcut)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    // MARK: - Hashable

    func testHashableEquality() {
        XCTAssertEqual(FloodlightShortcut.commandSpace, FloodlightShortcut.commandSpace)
        XCTAssertNotEqual(FloodlightShortcut.commandSpace, FloodlightShortcut.optionSpace)
        let set: Set<FloodlightShortcut> = [.commandSpace, .optionSpace, .commandSpace]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: - Helpers

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "FloodlightShortcutStressTests-\(UUID().uuidString)"
        return try (XCTUnwrap(UserDefaults(suiteName: suiteName)), suiteName)
    }
}

private func useSendable(_ shortcut: FloodlightShortcut) async {
    // Touch the value to ensure it crosses the actor boundary.
    _ = shortcut.displayName
}
