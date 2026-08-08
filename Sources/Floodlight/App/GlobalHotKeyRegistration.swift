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
        let identifier: GlobalHotKeyIdentifier
        let token: any GlobalHotKeyRegistrationToken
    }

    private let system: any GlobalHotKeySystem
    private let defaults: UserDefaults
    private let onPressed: @MainActor () -> Void
    private var handlerToken: (any GlobalHotKeyHandlerToken)?
    private var activeRegistration: ActiveRegistration?
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
        if let error = handlerToken?.invalidate() {
            Self.log(error)
        }
    }

    @discardableResult
    func start(preferred: FloodlightShortcut) -> FloodlightShortcut? {
        if let activeShortcut { return activeShortcut }
        lastFailure = nil
        guard installHandlerIfNeeded() else { return nil }

        if register(preferred) {
            return activeShortcut
        }
        _ = register(preferred.fallback)
        return activeShortcut
    }

    /// Preserves the existing replacement behavior. Transactional outcomes
    /// and truthful restoration failure UI are introduced by issue #36.
    func replace(with shortcut: FloodlightShortcut) -> Bool {
        lastFailure = nil
        guard shortcut != activeShortcut else {
            shortcut.save(in: defaults)
            return true
        }
        guard installHandlerIfNeeded() else { return false }

        let previous = activeShortcut
        invalidateActiveRegistration()
        if register(shortcut) {
            shortcut.save(in: defaults)
            return true
        }
        if let previous {
            _ = register(previous)
        }
        return false
    }

    func stop() {
        invalidateActiveRegistration()
        if let error = handlerToken?.invalidate() {
            record(error)
        }
        handlerToken = nil
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

    private func register(_ shortcut: FloodlightShortcut) -> Bool {
        guard let identifier = allocateIdentifier() else {
            record(.identifierExhausted)
            return false
        }
        switch system.register(shortcut, identifier: identifier) {
        case let .success(token):
            activeRegistration = ActiveRegistration(
                identifier: identifier,
                token: token
            )
            activeShortcut = shortcut
            return true
        case let .failure(error):
            record(error)
            return false
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

    private func invalidateActiveRegistration() {
        if let error = activeRegistration?.token.invalidate() {
            record(error)
        }
        activeRegistration = nil
        activeShortcut = nil
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
        self.reference = nil
        guard status == noErr else {
            return .handlerRemovalFailed(status: status)
        }
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
        self.reference = nil
        return status == noErr ? nil : .unregistrationFailed(status: status)
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
    return MainActor.assumeIsolated {
        callbackBox.onEvent(hotKeyEvent)
    }
}
