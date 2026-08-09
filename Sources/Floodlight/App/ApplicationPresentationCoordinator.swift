import Foundation

@MainActor
protocol ApplicationPresentationEffects: AnyObject {
    func showSearch()
    func hideSearch()
    func toggleSearch()

    func makeConfiguration(
        origin: ConfigurationOrigin,
        onFinished: @escaping @MainActor () -> Void,
        onDismissed: @escaping @MainActor () -> Void
    ) -> any ConfigurationPresenting
}

@MainActor
protocol ConfigurationPresenting: AnyObject {
    func show()
}

enum ConfigurationOrigin: Equatable, Sendable {
    case initialSetup
    case statusMenu
    case search
}

enum SearchPresentationOutcome: Equatable, Sendable {
    case searchPresented
    case configurationFocused
}

@MainActor
final class ApplicationPresentationCoordinator {
    // The application delegate owns both this coordinator and the effects
    // adapter, and therefore must outlive the coordinator.
    private unowned let effects: any ApplicationPresentationEffects
    private let ensureSearchStarted: @MainActor () -> Void
    private var configurationState: ConfigurationState?

    init(
        effects: any ApplicationPresentationEffects,
        ensureSearchStarted: @escaping @MainActor () -> Void
    ) {
        self.effects = effects
        self.ensureSearchStarted = ensureSearchStarted
    }

    func launch(initialSetupRequired: Bool) {
        guard !initialSetupRequired else {
            showConfiguration(from: .initialSetup)
            return
        }
        ensureSearchStarted()
        showSearch()
    }

    @discardableResult
    func showSearch() -> SearchPresentationOutcome {
        guard let configurationState else {
            effects.showSearch()
            return .searchPresented
        }
        configurationState.presentation?.show()
        return .configurationFocused
    }

    func hideSearch() {
        effects.hideSearch()
    }

    @discardableResult
    func toggleSearch() -> SearchPresentationOutcome {
        guard let configurationState else {
            effects.toggleSearch()
            return .searchPresented
        }
        configurationState.presentation?.show()
        return .configurationFocused
    }

    func showConfiguration(from origin: ConfigurationOrigin) {
        guard configurationState == nil else {
            configurationState?.presentation?.show()
            return
        }

        let id = UUID()
        configurationState = .creating(id: id, origin: origin)
        effects.hideSearch()
        let presentation = effects.makeConfiguration(
            origin: origin,
            onFinished: { [weak self] in
                self?.closeConfiguration(id: id, outcome: .finished)
            },
            onDismissed: { [weak self] in
                self?.closeConfiguration(id: id, outcome: .dismissed)
            }
        )
        guard configurationState?.id == id else { return }
        configurationState = .presented(ConfigurationSession(
            id: id,
            origin: origin,
            presentation: presentation
        ))
        presentation.show()
    }

    private func closeConfiguration(id: UUID, outcome: ConfigurationCloseOutcome) {
        guard let configurationState, configurationState.id == id else { return }
        let shouldRestoreSearch = configurationState.origin.restoresSearch(after: outcome)
        self.configurationState = nil

        ensureSearchStarted()
        if shouldRestoreSearch {
            showSearch()
        }
    }
}

private enum ConfigurationState {
    case creating(id: UUID, origin: ConfigurationOrigin)
    case presented(ConfigurationSession)

    var id: UUID {
        switch self {
        case let .creating(id, _): id
        case let .presented(session): session.id
        }
    }

    var origin: ConfigurationOrigin {
        switch self {
        case let .creating(_, origin): origin
        case let .presented(session): session.origin
        }
    }

    var presentation: (any ConfigurationPresenting)? {
        guard case let .presented(session) = self else { return nil }
        return session.presentation
    }
}

private struct ConfigurationSession {
    let id: UUID
    let origin: ConfigurationOrigin
    let presentation: any ConfigurationPresenting
}

private enum ConfigurationCloseOutcome {
    case finished
    case dismissed
}

private extension ConfigurationOrigin {
    func restoresSearch(after outcome: ConfigurationCloseOutcome) -> Bool {
        switch (self, outcome) {
        case (.initialSetup, .finished), (.search, _):
            true
        case (.initialSetup, .dismissed), (.statusMenu, _):
            false
        }
    }
}
