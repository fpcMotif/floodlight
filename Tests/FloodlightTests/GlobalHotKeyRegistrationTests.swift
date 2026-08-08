import Carbon
import Foundation
import XCTest
@testable import Floodlight

@MainActor
final class GlobalHotKeyRegistrationTests: XCTestCase {
    func testStartPublishesTheSuccessfullyRegisteredPreferredShortcut() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: makeDefaults(),
            onPressed: {}
        )

        let active = registration.start(preferred: .commandSpace)

        XCTAssertEqual(active, .commandSpace)
        XCTAssertEqual(registration.activeShortcut, .commandSpace)
        XCTAssertEqual(system.registeredShortcuts, [.commandSpace])
        XCTAssertEqual(system.handlerInstallations, 1)
    }

    func testStartFallsBackWhenThePreferredShortcutIsRefused() {
        let system = ScriptedGlobalHotKeySystem()
        let failure = GlobalHotKeyError.registrationFailed(
            shortcut: .commandSpace,
            status: OSStatus(eventHotKeyExistsErr)
        )
        system.failNextRegistration(of: .commandSpace, with: failure)
        let registration = makeRegistration(system: system)

        let active = registration.start(preferred: .commandSpace)

        XCTAssertEqual(active, .optionSpace)
        XCTAssertEqual(registration.activeShortcut, .optionSpace)
        XCTAssertEqual(system.registeredShortcuts, [.commandSpace, .optionSpace])
        XCTAssertEqual(registration.lastFailure, failure)
    }

    func testStartPublishesNoShortcutWhenPreferredAndFallbackBothFail() {
        let system = ScriptedGlobalHotKeySystem()
        system.failNextRegistration(
            of: .commandSpace,
            with: .registrationFailed(shortcut: .commandSpace, status: -1)
        )
        let fallbackFailure = GlobalHotKeyError.registrationFailed(
            shortcut: .optionSpace,
            status: -2
        )
        system.failNextRegistration(of: .optionSpace, with: fallbackFailure)
        let registration = makeRegistration(system: system)

        XCTAssertNil(registration.start(preferred: .commandSpace))
        XCTAssertNil(registration.activeShortcut)
        XCTAssertEqual(registration.lastFailure, fallbackFailure)
    }

    func testHandlerInstallationFailurePreventsRegistration() {
        let system = ScriptedGlobalHotKeySystem()
        let failure = GlobalHotKeyError.handlerInstallationFailed(status: -50)
        system.handlerFailure = failure
        let registration = makeRegistration(system: system)

        XCTAssertNil(registration.start(preferred: .commandSpace))
        XCTAssertTrue(system.registeredShortcuts.isEmpty)
        XCTAssertEqual(registration.lastFailure, failure)
    }

    func testMissingNativeReferencesRemainTypedFailures() {
        let handlerSystem = ScriptedGlobalHotKeySystem()
        handlerSystem.handlerFailure = .missingHandlerReference
        let handlerRegistration = makeRegistration(system: handlerSystem)
        XCTAssertNil(handlerRegistration.start(preferred: .commandSpace))
        XCTAssertEqual(handlerRegistration.lastFailure, .missingHandlerReference)

        let hotKeySystem = ScriptedGlobalHotKeySystem()
        hotKeySystem.failNextRegistration(
            of: .commandSpace,
            with: .missingRegistrationReference(shortcut: .commandSpace)
        )
        let hotKeyRegistration = makeRegistration(system: hotKeySystem)
        XCTAssertEqual(hotKeyRegistration.start(preferred: .commandSpace), .optionSpace)
        XCTAssertEqual(
            hotKeyRegistration.lastFailure,
            .missingRegistrationReference(shortcut: .commandSpace)
        )
    }

    func testOnlyTheCurrentFloodlightPressedEventInvokesTheAction() throws {
        let system = ScriptedGlobalHotKeySystem()
        var invocationCount = 0
        let registration = makeRegistration(system: system) {
            invocationCount += 1
        }
        registration.start(preferred: .commandSpace)
        let current = try XCTUnwrap(system.identifiers.last)

        XCTAssertEqual(
            system.emit(identifier: current, kind: UInt32(kEventHotKeyPressed)),
            noErr
        )
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(
            system.emit(
                identifier: GlobalHotKeyIdentifier(signature: 0x4E4F_5045, id: current.id),
                kind: UInt32(kEventHotKeyPressed)
            ),
            OSStatus(eventNotHandledErr)
        )
        XCTAssertEqual(
            system.emit(identifier: current, kind: UInt32(kEventHotKeyReleased)),
            OSStatus(eventNotHandledErr)
        )
        XCTAssertEqual(
            system.emit(
                identifier: current,
                eventClass: OSType(kEventClassApplication),
                kind: UInt32(kEventHotKeyPressed)
            ),
            OSStatus(eventNotHandledErr)
        )
        XCTAssertEqual(invocationCount, 1)
    }

    func testReplacementUsesANewIDAndRejectsTheStaleEvent() throws {
        let system = ScriptedGlobalHotKeySystem()
        var invocationCount = 0
        let registration = makeRegistration(system: system) {
            invocationCount += 1
        }
        registration.start(preferred: .commandSpace)
        let first = try XCTUnwrap(system.identifiers.last)

        XCTAssertTrue(registration.replace(with: .optionSpace))
        let second = try XCTUnwrap(system.identifiers.last)

        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(second.id, 2)
        XCTAssertEqual(
            system.emit(identifier: first, kind: UInt32(kEventHotKeyPressed)),
            OSStatus(eventNotHandledErr)
        )
        XCTAssertEqual(
            system.emit(identifier: second, kind: UInt32(kEventHotKeyPressed)),
            noErr
        )
        XCTAssertEqual(invocationCount, 1)
    }

    func testFailedReplacementRestoresThePreviousShortcut() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = makeRegistration(system: system)
        registration.start(preferred: .commandSpace)
        let replacementFailure = GlobalHotKeyError.registrationFailed(
            shortcut: .optionSpace,
            status: OSStatus(eventHotKeyExistsErr)
        )
        system.failNextRegistration(of: .optionSpace, with: replacementFailure)

        XCTAssertFalse(registration.replace(with: .optionSpace))

        XCTAssertEqual(registration.activeShortcut, .commandSpace)
        XCTAssertEqual(system.registeredShortcuts, [.commandSpace, .optionSpace, .commandSpace])
        XCTAssertEqual(system.identifiers.map(\.id), [1, 2, 3])
        XCTAssertEqual(registration.lastFailure, replacementFailure)
    }

    func testFailedReplacementPublishesNoShortcutWhenRestorationAlsoFails() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = makeRegistration(system: system)
        registration.start(preferred: .commandSpace)
        system.failNextRegistration(
            of: .optionSpace,
            with: .registrationFailed(shortcut: .optionSpace, status: -1)
        )
        let restorationFailure = GlobalHotKeyError.registrationFailed(
            shortcut: .commandSpace,
            status: -2
        )
        system.failNextRegistration(of: .commandSpace, with: restorationFailure)

        XCTAssertFalse(registration.replace(with: .optionSpace))

        XCTAssertNil(registration.activeShortcut)
        XCTAssertEqual(registration.lastFailure, restorationFailure)
    }

    func testIdentifierExhaustionIsExplicitAndDoesNotReuseTheMaximumID() {
        let system = ScriptedGlobalHotKeySystem()
        system.failNextRegistration(
            of: .commandSpace,
            with: .registrationFailed(shortcut: .commandSpace, status: -1)
        )
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: makeDefaults(),
            firstIdentifier: UInt32.max,
            onPressed: {}
        )

        XCTAssertNil(registration.start(preferred: .commandSpace))
        XCTAssertEqual(system.identifiers.map(\.id), [UInt32.max])
        XCTAssertEqual(registration.lastFailure, .identifierExhausted)
    }

    func testStopInvalidatesTheRegistrationBeforeTheHandlerAndIsIdempotent() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = makeRegistration(system: system)
        registration.start(preferred: .commandSpace)

        registration.stop()
        registration.stop()

        XCTAssertNil(registration.activeShortcut)
        XCTAssertEqual(system.invalidations, ["registration:1", "handler"])
    }

    func testImmediateStartStopAndRestartAreSafe() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = makeRegistration(system: system)

        registration.start(preferred: .commandSpace)
        registration.stop()
        registration.start(preferred: .commandSpace)
        registration.stop()

        XCTAssertEqual(system.handlerInstallations, 2)
        XCTAssertEqual(system.identifiers.map(\.id), [1, 2])
        XCTAssertEqual(
            system.invalidations,
            ["registration:1", "handler", "registration:2", "handler"]
        )
    }

    func testCleanupFailuresRemainTypedDiagnostics() {
        let registrationSystem = ScriptedGlobalHotKeySystem()
        registrationSystem.registrationInvalidationFailure = .unregistrationFailed(status: -1)
        let registration = makeRegistration(system: registrationSystem)
        registration.start(preferred: .commandSpace)
        registration.stop()
        XCTAssertEqual(registration.lastFailure, .unregistrationFailed(status: -1))

        let handlerSystem = ScriptedGlobalHotKeySystem()
        handlerSystem.handlerInvalidationFailure = .handlerRemovalFailed(status: -2)
        let handlerRegistration = makeRegistration(system: handlerSystem)
        handlerRegistration.start(preferred: .commandSpace)
        handlerRegistration.stop()
        XCTAssertEqual(handlerRegistration.lastFailure, .handlerRemovalFailed(status: -2))
    }

    func testDeinitializationInvalidatesTheRegistrationBeforeTheHandler() {
        let system = ScriptedGlobalHotKeySystem()
        var registration: GlobalHotKeyRegistration? = makeRegistration(system: system)
        registration?.start(preferred: .commandSpace)

        registration = nil

        XCTAssertEqual(system.invalidations, ["registration:1", "handler"])
    }

    func testSelectingTheActiveShortcutPersistsWithoutReregistering() {
        let system = ScriptedGlobalHotKeySystem()
        let defaults = makeDefaults()
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: defaults,
            onPressed: {}
        )
        registration.start(preferred: .commandSpace)

        XCTAssertTrue(registration.replace(with: .commandSpace))

        XCTAssertEqual(system.registeredShortcuts, [.commandSpace])
        XCTAssertEqual(
            defaults.string(forKey: FloodlightShortcut.preferenceKey),
            FloodlightShortcut.commandSpace.rawValue
        )
    }

    private func makeRegistration(
        system: ScriptedGlobalHotKeySystem,
        onPressed: @escaping @MainActor () -> Void = {}
    ) -> GlobalHotKeyRegistration {
        GlobalHotKeyRegistration(
            system: system,
            defaults: makeDefaults(),
            onPressed: onPressed
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "GlobalHotKeyRegistrationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

@MainActor
private final class ScriptedGlobalHotKeySystem: GlobalHotKeySystem {
    private(set) var handlerInstallations = 0
    private(set) var registeredShortcuts: [FloodlightShortcut] = []
    private(set) var identifiers: [GlobalHotKeyIdentifier] = []
    private(set) var invalidations: [String] = []
    var handlerFailure: GlobalHotKeyError?
    var handlerInvalidationFailure: GlobalHotKeyError?
    var registrationInvalidationFailure: GlobalHotKeyError?
    private var registrationFailures: [FloodlightShortcut: [GlobalHotKeyError]] = [:]
    private var onEvent: (@MainActor (GlobalHotKeyEvent) -> OSStatus)?

    func failNextRegistration(
        of shortcut: FloodlightShortcut,
        with error: GlobalHotKeyError
    ) {
        registrationFailures[shortcut, default: []].append(error)
    }

    func installHandler(
        _ onEvent: @escaping @MainActor (GlobalHotKeyEvent) -> OSStatus
    ) -> Result<any GlobalHotKeyHandlerToken, GlobalHotKeyError> {
        handlerInstallations += 1
        if let handlerFailure { return .failure(handlerFailure) }
        self.onEvent = onEvent
        return .success(
            ScriptedToken(failure: handlerInvalidationFailure) { [weak self] in
                self?.invalidations.append("handler")
                self?.onEvent = nil
            }
        )
    }

    func register(
        _ shortcut: FloodlightShortcut,
        identifier: GlobalHotKeyIdentifier
    ) -> Result<any GlobalHotKeyRegistrationToken, GlobalHotKeyError> {
        registeredShortcuts.append(shortcut)
        identifiers.append(identifier)
        if var failures = registrationFailures[shortcut], !failures.isEmpty {
            let failure = failures.removeFirst()
            registrationFailures[shortcut] = failures
            return .failure(failure)
        }
        return .success(
            ScriptedToken(failure: registrationInvalidationFailure) { [weak self] in
                self?.invalidations.append("registration:\(identifier.id)")
            }
        )
    }

    func emit(
        identifier: GlobalHotKeyIdentifier,
        eventClass: UInt32 = OSType(kEventClassKeyboard),
        kind: UInt32
    ) -> OSStatus {
        onEvent?(.init(identifier: identifier, eventClass: eventClass, kind: kind))
            ?? OSStatus(eventNotHandledErr)
    }
}

@MainActor
private final class ScriptedToken: GlobalHotKeyHandlerToken, GlobalHotKeyRegistrationToken {
    private var onInvalidate: (() -> Void)?
    private let failure: GlobalHotKeyError?

    init(failure: GlobalHotKeyError?, onInvalidate: @escaping () -> Void) {
        self.failure = failure
        self.onInvalidate = onInvalidate
    }

    isolated deinit {
        _ = invalidate()
    }

    func invalidate() -> GlobalHotKeyError? {
        guard let onInvalidate else { return nil }
        self.onInvalidate = nil
        onInvalidate()
        return failure
    }
}
