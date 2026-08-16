import Carbon
import Foundation
import Testing
@testable import Floodlight

@MainActor
final class GlobalHotKeyRegistrationTests {
    @Test func startPublishesTheSuccessfullyRegisteredPreferredShortcut() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: makeDefaults(),
            onPressed: {}
        )

        let active = registration.start(preferred: .commandSpace)

        #expect(active == .commandSpace)
        #expect(registration.activeShortcut == .commandSpace)
        #expect(system.registeredShortcuts == [.commandSpace])
        #expect(system.handlerInstallations == 1)
    }

    @Test func startFallsBackWhenThePreferredShortcutIsRefused() {
        let system = ScriptedGlobalHotKeySystem()
        let failure = GlobalHotKeyError.registrationFailed(
            shortcut: .commandSpace,
            status: OSStatus(eventHotKeyExistsErr)
        )
        system.failNextRegistration(of: .commandSpace, with: failure)
        let registration = makeRegistration(system: system)

        let active = registration.start(preferred: .commandSpace)

        #expect(active == .optionSpace)
        #expect(registration.activeShortcut == .optionSpace)
        #expect(system.registeredShortcuts == [.commandSpace, .optionSpace])
        #expect(registration.lastFailure == failure)
    }

    @Test func startPublishesNoShortcutWhenPreferredAndFallbackBothFail() {
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

        #expect(registration.start(preferred: .commandSpace) == nil)
        #expect(registration.activeShortcut == nil)
        #expect(registration.lastFailure == fallbackFailure)
    }

    @Test func handlerInstallationFailurePreventsRegistration() {
        let system = ScriptedGlobalHotKeySystem()
        let failure = GlobalHotKeyError.handlerInstallationFailed(status: -50)
        system.handlerFailure = failure
        let registration = makeRegistration(system: system)

        #expect(registration.start(preferred: .commandSpace) == nil)
        #expect(system.registeredShortcuts.isEmpty)
        #expect(registration.lastFailure == failure)
    }

    @Test func missingNativeReferencesRemainTypedFailures() {
        let handlerSystem = ScriptedGlobalHotKeySystem()
        handlerSystem.handlerFailure = .missingHandlerReference
        let handlerRegistration = makeRegistration(system: handlerSystem)
        #expect(handlerRegistration.start(preferred: .commandSpace) == nil)
        #expect(handlerRegistration.lastFailure == .missingHandlerReference)

        let hotKeySystem = ScriptedGlobalHotKeySystem()
        hotKeySystem.failNextRegistration(
            of: .commandSpace,
            with: .missingRegistrationReference(shortcut: .commandSpace)
        )
        let hotKeyRegistration = makeRegistration(system: hotKeySystem)
        #expect(hotKeyRegistration.start(preferred: .commandSpace) == .optionSpace)
        #expect(hotKeyRegistration
            .lastFailure == .missingRegistrationReference(shortcut: .commandSpace))
    }

    @Test func onlyTheCurrentFloodlightPressedEventInvokesTheAction() throws {
        let system = ScriptedGlobalHotKeySystem()
        var invocationCount = 0
        let registration = makeRegistration(system: system) {
            invocationCount += 1
        }
        registration.start(preferred: .commandSpace)
        let current = try #require(system.identifiers.last)

        #expect(system.emit(identifier: current, kind: UInt32(kEventHotKeyPressed)) == noErr)
        #expect(invocationCount == 1)
        #expect(system.emit(
            identifier: GlobalHotKeyIdentifier(signature: 0x4E4F_5045, id: current.id),
            kind: UInt32(kEventHotKeyPressed)
        ) == OSStatus(eventNotHandledErr))
        #expect(system
            .emit(identifier: current, kind: UInt32(kEventHotKeyReleased)) ==
            OSStatus(eventNotHandledErr))
        #expect(system.emit(
            identifier: current,
            eventClass: OSType(kEventClassApplication),
            kind: UInt32(kEventHotKeyPressed)
        ) == OSStatus(eventNotHandledErr))
        #expect(invocationCount == 1)
    }

    @Test func replacementActivatesTheRequestedShortcutBeforeRetiringThePreviousOne() throws {
        let system = ScriptedGlobalHotKeySystem()
        let defaults = makeDefaults()
        var invocationCount = 0
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: defaults,
            onPressed: { invocationCount += 1 }
        )
        registration.start(preferred: .commandSpace)
        let first = try #require(system.identifiers.last)

        let outcome = registration.replace(with: .optionSpace)
        let second = try #require(system.identifiers.last)

        #expect(outcome == .requestedShortcutActive(.optionSpace))
        #expect(registration.activeShortcut == .optionSpace)
        #expect(system.registeredShortcuts == [.commandSpace, .optionSpace])
        #expect(system.invalidations == ["registration:1"])
        #expect(defaults.string(forKey: FloodlightShortcut.preferenceKey) == FloodlightShortcut
            .optionSpace.rawValue)
        #expect(first.id == 1)
        #expect(second.id == 2)
        #expect(system
            .emit(identifier: first, kind: UInt32(kEventHotKeyPressed)) ==
            OSStatus(eventNotHandledErr))
        #expect(system.emit(identifier: second, kind: UInt32(kEventHotKeyPressed)) == noErr)
        #expect(invocationCount == 1)
    }

    @Test func refusedReplacementPreservesThePreviousShortcutAndPreference() {
        let system = ScriptedGlobalHotKeySystem()
        let defaults = makeDefaults()
        FloodlightShortcut.commandSpace.save(in: defaults)
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: defaults,
            onPressed: {}
        )
        registration.start(preferred: .commandSpace)
        let replacementFailure = GlobalHotKeyError.registrationFailed(
            shortcut: .optionSpace,
            status: OSStatus(eventHotKeyExistsErr)
        )
        system.failNextRegistration(of: .optionSpace, with: replacementFailure)

        #expect(registration.replace(with: .optionSpace) == .previousShortcutActive(.commandSpace))

        #expect(registration.activeShortcut == .commandSpace)
        #expect(system.registeredShortcuts == [.commandSpace, .optionSpace])
        #expect(system.identifiers.map(\.id) == [1, 2])
        #expect(system.invalidations.isEmpty)
        #expect(defaults.string(forKey: FloodlightShortcut.preferenceKey) == FloodlightShortcut
            .commandSpace.rawValue)
        #expect(registration.lastFailure == replacementFailure)
    }

    @Test func refusedReplacementRestoresThePreviousShortcutWhenCoexistenceIsUnavailable() {
        let system = ScriptedGlobalHotKeySystem()
        system.supportsConcurrentRegistrations = false
        let registration = makeRegistration(system: system)
        registration.start(preferred: .commandSpace)
        system.failNextRegistration(
            of: .optionSpace,
            with: .registrationFailed(shortcut: .optionSpace, status: -1)
        )

        #expect(registration.replace(with: .optionSpace) == .previousShortcutActive(.commandSpace))

        #expect(registration.activeShortcut == .commandSpace)
        #expect(system.registeredShortcuts == [.commandSpace, .optionSpace, .commandSpace])
        #expect(system.identifiers.map(\.id) == [1, 2, 3])
        #expect(system.invalidations == ["registration:1"])
    }

    @Test func failedReplacementPublishesNoShortcutWhenRestorationAlsoFails() {
        let system = ScriptedGlobalHotKeySystem()
        system.supportsConcurrentRegistrations = false
        let defaults = makeDefaults()
        FloodlightShortcut.commandSpace.save(in: defaults)
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: defaults,
            onPressed: {}
        )
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

        #expect(registration.replace(with: .optionSpace) == .noShortcutActive)

        #expect(registration.activeShortcut == nil)
        #expect(registration.lastFailure == restorationFailure)
        #expect(defaults.string(forKey: FloodlightShortcut.preferenceKey) == FloodlightShortcut
            .commandSpace.rawValue)
    }

    @Test func repeatedReplacementKeepsOnlyTheLatestRegistrationActive() {
        let system = ScriptedGlobalHotKeySystem()
        var invocationCount = 0
        let registration = makeRegistration(system: system) {
            invocationCount += 1
        }
        registration.start(preferred: .commandSpace)

        #expect(registration.replace(with: .optionSpace) == .requestedShortcutActive(.optionSpace))
        #expect(registration
            .replace(with: .commandSpace) == .requestedShortcutActive(.commandSpace))

        let identifiers = system.identifiers
        #expect(identifiers.map(\.id) == [1, 2, 3])
        #expect(system.invalidations == ["registration:1", "registration:2"])
        #expect(system
            .emit(identifier: identifiers[1], kind: UInt32(kEventHotKeyPressed)) ==
            OSStatus(eventNotHandledErr))
        #expect(system.emit(identifier: identifiers[2], kind: UInt32(kEventHotKeyPressed)) == noErr)
        #expect(invocationCount == 1)
    }

    @Test func immediateReplacementThenStopRetiresBothRegistrationsAndRouting() throws {
        let system = ScriptedGlobalHotKeySystem()
        var invocationCount = 0
        let registration = makeRegistration(system: system) {
            invocationCount += 1
        }
        registration.start(preferred: .commandSpace)
        #expect(registration.replace(with: .optionSpace) == .requestedShortcutActive(.optionSpace))
        let activeIdentifier = try #require(system.identifiers.last)

        registration.stop()

        #expect(registration.activeShortcut == nil)
        #expect(system.invalidations == ["registration:1", "registration:2", "handler"])
        #expect(system
            .emit(identifier: activeIdentifier, kind: UInt32(kEventHotKeyPressed)) ==
            OSStatus(eventNotHandledErr))
        #expect(invocationCount == 0)
    }

    @Test func retirementFailureKeepsThePreviousShortcutAndRetriesCleanupOnStop() throws {
        let system = ScriptedGlobalHotKeySystem()
        let defaults = makeDefaults()
        FloodlightShortcut.commandSpace.save(in: defaults)
        var invocationCount = 0
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: defaults,
            onPressed: { invocationCount += 1 }
        )
        registration.start(preferred: .commandSpace)
        let previousIdentifier = try #require(system.identifiers.last)
        system.registrationInvalidationFailure = .unregistrationFailed(status: -1)

        #expect(registration.replace(with: .optionSpace) == .previousShortcutActive(.commandSpace))

        let requestedIdentifier = try #require(system.identifiers.last)
        #expect(registration.activeShortcut == .commandSpace)
        #expect(system.invalidations == ["registration:1", "registration:2"])
        #expect(defaults.string(forKey: FloodlightShortcut.preferenceKey) == FloodlightShortcut
            .commandSpace.rawValue)
        #expect(system
            .emit(identifier: previousIdentifier, kind: UInt32(kEventHotKeyPressed)) == noErr)
        #expect(system
            .emit(identifier: requestedIdentifier, kind: UInt32(kEventHotKeyPressed)) ==
            OSStatus(eventNotHandledErr))
        #expect(invocationCount == 1)

        system.registrationInvalidationFailure = nil
        registration.stop()

        #expect(system.invalidations == [
            "registration:1", "registration:2",
            "registration:2", "registration:1", "handler",
        ])
    }

    @Test func failedStopRetriesCleanupBeforeRestarting() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = makeRegistration(system: system)
        registration.start(preferred: .commandSpace)
        system.registrationInvalidationFailure = .unregistrationFailed(status: -1)

        registration.stop()

        #expect(registration.activeShortcut == nil)
        #expect(system.invalidations == ["registration:1"])
        #expect(system.handlerInstallations == 1)

        system.registrationInvalidationFailure = nil
        #expect(registration.start(preferred: .commandSpace) == .commandSpace)

        #expect(system.registeredShortcuts == [.commandSpace, .commandSpace])
        #expect(system.invalidations == ["registration:1", "registration:1"])
        #expect(system.handlerInstallations == 1)

        registration.stop()
        #expect(system.invalidations == [
            "registration:1",
            "registration:1",
            "registration:2",
            "handler",
        ])
    }

    @Test func identifierExhaustionIsExplicitAndDoesNotReuseTheMaximumID() {
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

        #expect(registration.start(preferred: .commandSpace) == nil)
        #expect(system.identifiers.map(\.id) == [UInt32.max])
        #expect(registration.lastFailure == .identifierExhausted)
    }

    @Test func stopInvalidatesTheRegistrationBeforeTheHandlerAndIsIdempotent() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = makeRegistration(system: system)
        registration.start(preferred: .commandSpace)

        registration.stop()
        registration.stop()

        #expect(registration.activeShortcut == nil)
        #expect(system.invalidations == ["registration:1", "handler"])
    }

    @Test func immediateStartStopAndRestartAreSafe() {
        let system = ScriptedGlobalHotKeySystem()
        let registration = makeRegistration(system: system)

        registration.start(preferred: .commandSpace)
        registration.stop()
        registration.start(preferred: .commandSpace)
        registration.stop()

        #expect(system.handlerInstallations == 2)
        #expect(system.identifiers.map(\.id) == [1, 2])
        #expect(system.invalidations == ["registration:1", "handler", "registration:2", "handler"])
    }

    @Test func cleanupFailuresRemainTypedDiagnostics() {
        let registrationSystem = ScriptedGlobalHotKeySystem()
        registrationSystem.registrationInvalidationFailure = .unregistrationFailed(status: -1)
        let registration = makeRegistration(system: registrationSystem)
        registration.start(preferred: .commandSpace)
        registration.stop()
        #expect(registration.lastFailure == .unregistrationFailed(status: -1))

        let handlerSystem = ScriptedGlobalHotKeySystem()
        handlerSystem.handlerInvalidationFailure = .handlerRemovalFailed(status: -2)
        let handlerRegistration = makeRegistration(system: handlerSystem)
        handlerRegistration.start(preferred: .commandSpace)
        handlerRegistration.stop()
        #expect(handlerRegistration.lastFailure == .handlerRemovalFailed(status: -2))
    }

    @Test func deinitializationInvalidatesTheRegistrationBeforeTheHandler() {
        let system = ScriptedGlobalHotKeySystem()
        var registration: GlobalHotKeyRegistration? = makeRegistration(system: system)
        registration?.start(preferred: .commandSpace)

        registration = nil

        #expect(system.invalidations == ["registration:1", "handler"])
    }

    @Test func selectingTheActiveShortcutPersistsWithoutReregistering() {
        let system = ScriptedGlobalHotKeySystem()
        let defaults = makeDefaults()
        let registration = GlobalHotKeyRegistration(
            system: system,
            defaults: defaults,
            onPressed: {}
        )
        registration.start(preferred: .commandSpace)

        #expect(registration
            .replace(with: .commandSpace) == .requestedShortcutActive(.commandSpace))

        #expect(system.registeredShortcuts == [.commandSpace])
        #expect(defaults.string(forKey: FloodlightShortcut.preferenceKey) == FloodlightShortcut
            .commandSpace.rawValue)
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

    private var retainedDefaults: [RetainedDefaults] = []

    private func makeDefaults() -> UserDefaults {
        let isolated = RetainedDefaults(prefix: "GlobalHotKeyRegistrationTests")
        retainedDefaults.append(isolated)
        return isolated.defaults
    }
}

@MainActor
private final class ScriptedGlobalHotKeySystem: GlobalHotKeySystem {
    var supportsConcurrentRegistrations = true
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
            ScriptedToken { [weak self] in
                self?.invalidations.append("handler")
                if let failure = self?.handlerInvalidationFailure {
                    return failure
                }
                self?.onEvent = nil
                return nil
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
            ScriptedToken { [weak self] in
                self?.invalidations.append("registration:\(identifier.id)")
                return self?.registrationInvalidationFailure
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
    private var onInvalidate: (() -> GlobalHotKeyError?)?

    init(onInvalidate: @escaping () -> GlobalHotKeyError?) {
        self.onInvalidate = onInvalidate
    }

    isolated deinit {
        _ = invalidate()
    }

    func invalidate() -> GlobalHotKeyError? {
        guard let onInvalidate else { return nil }
        if let failure = onInvalidate() {
            return failure
        }
        self.onInvalidate = nil
        return nil
    }
}

private final class RetainedDefaults {
    let defaults: UserDefaults
    let suiteName: String

    init(prefix: String) {
        suiteName = "\(prefix)-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
