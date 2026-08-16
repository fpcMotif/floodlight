import Carbon
import Foundation

struct GlobalHotKeyIdentifier: Equatable, Sendable {
    static let floodlightSignature: OSType = 0x464C_4954 // FLIT

    let signature: OSType
    let id: UInt32
}

struct GlobalHotKeyEvent: Equatable, Sendable {
    let identifier: GlobalHotKeyIdentifier
    let eventClass: UInt32
    let kind: UInt32
}

enum GlobalHotKeyError: Error, Equatable, Sendable {
    case handlerInstallationFailed(status: OSStatus)
    case missingHandlerReference
    case registrationFailed(shortcut: FloodlightShortcut, status: OSStatus)
    case missingRegistrationReference(shortcut: FloodlightShortcut)
    case handlerRemovalFailed(status: OSStatus)
    case unregistrationFailed(status: OSStatus)
    case identifierExhausted
}

enum GlobalHotKeyReplacementOutcome: Equatable, Sendable {
    case requestedShortcutActive(FloodlightShortcut)
    case previousShortcutActive(FloodlightShortcut)
    case noShortcutActive
}

@MainActor
protocol GlobalHotKeyHandlerToken: AnyObject {
    @discardableResult
    func invalidate() -> GlobalHotKeyError?
}

@MainActor
protocol GlobalHotKeyRegistrationToken: AnyObject {
    @discardableResult
    func invalidate() -> GlobalHotKeyError?
}

@MainActor
protocol GlobalHotKeySystem: AnyObject {
    var supportsConcurrentRegistrations: Bool { get }

    func installHandler(
        _ onEvent: @escaping @MainActor (GlobalHotKeyEvent) -> OSStatus
    ) -> Result<any GlobalHotKeyHandlerToken, GlobalHotKeyError>

    func register(
        _ shortcut: FloodlightShortcut,
        identifier: GlobalHotKeyIdentifier
    ) -> Result<any GlobalHotKeyRegistrationToken, GlobalHotKeyError>
}

@MainActor
final class GlobalHotKeyRegistration {
    private struct ActiveRegistration {
        let shortcut: FloodlightShortcut
        let identifier: GlobalHotKeyIdentifier
        let token: any GlobalHotKeyRegistrationToken
    }

    private let system: any GlobalHotKeySystem
    private let defaults: UserDefaults
    private let onPressed: @MainActor () -> Void
    private var handlerToken: (any GlobalHotKeyHandlerToken)?
    private var activeRegistration: ActiveRegistration?
    private var pendingCleanupTokens: [any GlobalHotKeyRegistrationToken] = []
    private var nextIdentifier: UInt32?

    private(set) var activeShortcut: FloodlightShortcut?
    // periphery:ignore - Retained as typed internal diagnostics and asserted
    // through the module's production interface by scripted-adapter tests.
    private(set) var lastFailure: GlobalHotKeyError?

    convenience init(
        defaults: UserDefaults = .standard,
        onPressed: @escaping @MainActor () -> Void
    ) {
        self.init(
            system: CarbonGlobalHotKeySystem(),
            defaults: defaults,
            onPressed: onPressed
        )
    }

    init(
        system: any GlobalHotKeySystem,
        defaults: UserDefaults,
        firstIdentifier: UInt32 = 1,
        onPressed: @escaping @MainActor () -> Void
    ) {
        self.system = system
        self.defaults = defaults
        nextIdentifier = firstIdentifier
        self.onPressed = onPressed
    }

    isolated deinit {
        if let error = activeRegistration?.token.invalidate() {
            Self.log(error)
        }
        for token in pendingCleanupTokens {
            if let error = token.invalidate() {
                Self.log(error)
            }
        }
        if let error = handlerToken?.invalidate() {
            Self.log(error)
        }
    }

    @discardableResult
    func start(preferred: FloodlightShortcut) -> FloodlightShortcut? {
        retryPendingCleanup()
        if let activeShortcut { return activeShortcut }
        guard pendingCleanupTokens.isEmpty else { return nil }
        lastFailure = nil
        guard installHandlerIfNeeded() else { return nil }

        if registerAndActivate(preferred) {
            return activeShortcut
        }
        _ = registerAndActivate(preferred.fallback)
        return activeShortcut
    }

    func replace(with shortcut: FloodlightShortcut) -> GlobalHotKeyReplacementOutcome {
        lastFailure = nil
        retryPendingCleanup()
        guard shortcut != activeShortcut else {
            shortcut.save(in: defaults)
            return .requestedShortcutActive(shortcut)
        }
        guard pendingCleanupTokens.isEmpty else {
            if let activeShortcut {
                return .previousShortcutActive(activeShortcut)
            }
            return .noShortcutActive
        }
        guard installHandlerIfNeeded() else { return .noShortcutActive }

        if system.supportsConcurrentRegistrations || activeRegistration == nil {
            return replaceWhilePreservingCurrent(with: shortcut)
        }
        return replaceWithRestoration(with: shortcut)
    }

    func stop() {
        retryPendingCleanup()
        if let activeRegistration {
            if let error = activeRegistration.token.invalidate() {
                record(error)
                pendingCleanupTokens.append(activeRegistration.token)
            }
            self.activeRegistration = nil
            activeShortcut = nil
        }
        guard pendingCleanupTokens.isEmpty else { return }
        if let handlerToken {
            if let error = handlerToken.invalidate() {
                record(error)
                return
            }
            self.handlerToken = nil
        }
    }

    private func replaceWhilePreservingCurrent(
        with shortcut: FloodlightShortcut
    ) -> GlobalHotKeyReplacementOutcome {
        let previous = activeRegistration
        guard let requested = makeRegistration(shortcut) else {
            if let previous {
                return .previousShortcutActive(previous.shortcut)
            }
            return .noShortcutActive
        }

        if let previous, let error = previous.token.invalidate() {
            record(error)
            if let rollbackError = requested.token.invalidate() {
                record(rollbackError)
                pendingCleanupTokens.append(requested.token)
            }
            return .previousShortcutActive(previous.shortcut)
        }
        activate(requested)
        shortcut.save(in: defaults)
        return .requestedShortcutActive(shortcut)
    }

    private func replaceWithRestoration(
        with shortcut: FloodlightShortcut
    ) -> GlobalHotKeyReplacementOutcome {
        let previous = activeRegistration
        if let previous, let error = previous.token.invalidate() {
            record(error)
            return .previousShortcutActive(previous.shortcut)
        }
        activeRegistration = nil
        activeShortcut = nil
        if let requested = makeRegistration(shortcut) {
            activate(requested)
            shortcut.save(in: defaults)
            return .requestedShortcutActive(shortcut)
        }
        guard let previousShortcut = previous?.shortcut,
              let restored = makeRegistration(previousShortcut)
        else {
            return .noShortcutActive
        }
        activate(restored)
        return .previousShortcutActive(previousShortcut)
    }

    private func installHandlerIfNeeded() -> Bool {
        guard handlerToken == nil else { return true }
        switch system.installHandler({ [weak self] event in
            self?.handle(event) ?? OSStatus(eventNotHandledErr)
        }) {
        case let .success(token):
            handlerToken = token
            return true
        case let .failure(error):
            record(error)
            return false
        }
    }

    private func registerAndActivate(_ shortcut: FloodlightShortcut) -> Bool {
        guard let registration = makeRegistration(shortcut) else { return false }
        activate(registration)
        return true
    }

    private func activate(_ registration: ActiveRegistration) {
        activeRegistration = registration
        activeShortcut = registration.shortcut
    }

    private func makeRegistration(_ shortcut: FloodlightShortcut) -> ActiveRegistration? {
        guard let identifier = allocateIdentifier() else {
            record(.identifierExhausted)
            return nil
        }
        switch system.register(shortcut, identifier: identifier) {
        case let .success(token):
            return ActiveRegistration(
                shortcut: shortcut,
                identifier: identifier,
                token: token
            )
        case let .failure(error):
            record(error)
            return nil
        }
    }

    private func allocateIdentifier() -> GlobalHotKeyIdentifier? {
        guard let id = nextIdentifier else { return nil }
        nextIdentifier = id == UInt32.max ? nil : id + 1
        return GlobalHotKeyIdentifier(
            signature: GlobalHotKeyIdentifier.floodlightSignature,
            id: id
        )
    }

    private func handle(_ event: GlobalHotKeyEvent) -> OSStatus {
        guard event.eventClass == OSType(kEventClassKeyboard),
              event.kind == UInt32(kEventHotKeyPressed),
              event.identifier.signature == GlobalHotKeyIdentifier.floodlightSignature,
              event.identifier == activeRegistration?.identifier
        else {
            return OSStatus(eventNotHandledErr)
        }
        onPressed()
        return noErr
    }

    private func retryPendingCleanup() {
        pendingCleanupTokens = pendingCleanupTokens.filter { token in
            guard let error = token.invalidate() else { return false }
            record(error)
            return true
        }
    }

    private func record(_ error: GlobalHotKeyError) {
        lastFailure = error
        Self.log(error)
    }

    fileprivate static func log(_ error: GlobalHotKeyError) {
        NSLog("Floodlight global hot-key failure: %@", String(describing: error))
    }
}

@MainActor
private final class CarbonGlobalHotKeySystem: GlobalHotKeySystem {
    /// Distinct key combinations and EventHotKeyID values coexist in Carbon.
    let supportsConcurrentRegistrations = true

    func installHandler(
        _ onEvent: @escaping @MainActor (GlobalHotKeyEvent) -> OSStatus
    ) -> Result<any GlobalHotKeyHandlerToken, GlobalHotKeyError> {
        let callbackBox = CarbonHotKeyCallbackBox(onEvent: onEvent)
        let callbackContext = Unmanaged.passRetained(callbackBox).toOpaque()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var reference: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventType,
            callbackContext,
            &reference
        )
        guard status == noErr else {
            if let reference {
                let cleanupStatus = RemoveEventHandler(reference)
                if cleanupStatus == noErr {
                    Unmanaged<CarbonHotKeyCallbackBox>.fromOpaque(callbackContext).release()
                } else {
                    GlobalHotKeyRegistration.log(
                        .handlerRemovalFailed(status: cleanupStatus)
                    )
                }
            } else {
                Unmanaged<CarbonHotKeyCallbackBox>.fromOpaque(callbackContext).release()
            }
            return .failure(.handlerInstallationFailed(status: status))
        }
        guard let reference else {
            // Carbon reported installation without providing the only handle
            // that could safely remove the callback, so its context must live.
            return .failure(.missingHandlerReference)
        }
        return .success(
            CarbonHandlerToken(reference: reference, callbackContext: callbackContext)
        )
    }

    func register(
        _ shortcut: FloodlightShortcut,
        identifier: GlobalHotKeyIdentifier
    ) -> Result<any GlobalHotKeyRegistrationToken, GlobalHotKeyError> {
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            shortcut.carbonModifiers,
            EventHotKeyID(signature: identifier.signature, id: identifier.id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else {
            if let reference {
                let cleanupStatus = UnregisterEventHotKey(reference)
                if cleanupStatus != noErr {
                    GlobalHotKeyRegistration.log(
                        .unregistrationFailed(status: cleanupStatus)
                    )
                }
            }
            return .failure(.registrationFailed(shortcut: shortcut, status: status))
        }
        guard let reference else {
            return .failure(.missingRegistrationReference(shortcut: shortcut))
        }
        return .success(CarbonRegistrationToken(reference: reference))
    }
}

@MainActor
private final class CarbonHotKeyCallbackBox {
    let onEvent: @MainActor (GlobalHotKeyEvent) -> OSStatus

    init(onEvent: @escaping @MainActor (GlobalHotKeyEvent) -> OSStatus) {
        self.onEvent = onEvent
    }
}

@MainActor
private final class CarbonHandlerToken: GlobalHotKeyHandlerToken {
    private var reference: EventHandlerRef?
    private var callbackContext: UnsafeMutableRawPointer?

    init(reference: EventHandlerRef, callbackContext: UnsafeMutableRawPointer) {
        self.reference = reference
        self.callbackContext = callbackContext
    }

    isolated deinit {
        if let error = invalidate() {
            GlobalHotKeyRegistration.log(error)
        }
    }

    func invalidate() -> GlobalHotKeyError? {
        guard let reference else { return nil }
        let status = RemoveEventHandler(reference)
        guard status == noErr else {
            return .handlerRemovalFailed(status: status)
        }
        self.reference = nil
        if let callbackContext {
            Unmanaged<CarbonHotKeyCallbackBox>.fromOpaque(callbackContext).release()
            self.callbackContext = nil
        }
        return nil
    }
}

@MainActor
private final class CarbonRegistrationToken: GlobalHotKeyRegistrationToken {
    private var reference: EventHotKeyRef?

    init(reference: EventHotKeyRef) {
        self.reference = reference
    }

    isolated deinit {
        if let error = invalidate() {
            GlobalHotKeyRegistration.log(error)
        }
    }

    func invalidate() -> GlobalHotKeyError? {
        guard let reference else { return nil }
        let status = UnregisterEventHotKey(reference)
        guard status == noErr else {
            return .unregistrationFailed(status: status)
        }
        self.reference = nil
        return nil
    }
}

private func carbonHotKeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard Thread.isMainThread,
          let event,
          let userData
    else {
        return OSStatus(eventNotHandledErr)
    }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return OSStatus(eventNotHandledErr) }

    let callbackBox = Unmanaged<CarbonHotKeyCallbackBox>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let hotKeyEvent = GlobalHotKeyEvent(
        identifier: GlobalHotKeyIdentifier(
            signature: identifier.signature,
            id: identifier.id
        ),
        eventClass: GetEventClass(event),
        kind: GetEventKind(event)
    )
    // Carbon's EventHandlerUPP cannot be typed @MainActor; the application
    // event target delivers hot-key presses on the main thread.
    return MainActor.assumeIsolated {
        callbackBox.onEvent(hotKeyEvent)
    }
}
