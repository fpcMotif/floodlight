import AppKit
import Testing
@testable import Floodlight

@MainActor
@Suite(.serialized)
struct ApplicationPresentationCoordinatorTests {
    @Test func launchWithoutInitialSetupStartsSearchBeforePresentingIt() {
        var events: [Event] = []
        let effects = ScriptedEffects(events: { events.append($0) })
        let coordinator = ApplicationPresentationCoordinator(
            effects: effects,
            ensureSearchStarted: { events.append(.startSearch) }
        )

        coordinator.launch(initialSetupRequired: false)

        #expect(events == [.startSearch, .showSearch])
    }

    @Test func launchWithInitialSetupPresentsConfigurationInsteadOfSearch() {
        let harness = Harness()

        harness.coordinator.launch(initialSetupRequired: true)

        #expect(harness.events == [
            .hideSearch,
            .makeConfiguration(.initialSetup),
            .showConfiguration,
        ])
    }

    @Test func launchRechecksConfigurationPriorityAfterStartingSearch() {
        let harness = Harness()
        harness.onStart = { [weak harness] in
            harness?.coordinator.showConfiguration(from: .statusMenu)
        }

        harness.coordinator.launch(initialSetupRequired: false)

        #expect(harness.events == [
            .startSearch,
            .hideSearch,
            .makeConfiguration(.statusMenu),
            .showConfiguration,
            .showConfiguration,
        ])
    }

    @Test func searchRequestsRouteToSearchWhenConfigurationIsInactive() {
        let harness = Harness()

        #expect(harness.coordinator.showSearch() == .searchPresented)
        #expect(harness.coordinator.toggleSearch() == .searchPresented)
        harness.coordinator.hideSearch()

        #expect(harness.events == [.showSearch, .toggleSearch, .hideSearch])
    }

    @Test func searchPresentationFocusesActiveConfiguration() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .statusMenu)
        harness.events.removeAll()

        #expect(harness.coordinator.showSearch() == .configurationFocused)
        #expect(harness.coordinator.toggleSearch() == .configurationFocused)

        #expect(harness.events == [.showConfiguration, .showConfiguration])
    }

    @Test func repeatedConfigurationRequestFocusesExistingSession() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .statusMenu)
        harness.coordinator.showConfiguration(from: .search)

        #expect(harness.events == [
            .hideSearch,
            .makeConfiguration(.statusMenu),
            .showConfiguration,
            .showConfiguration,
        ])
        #expect(harness.effects.presentations.count == 1)
    }

    @Test func configurationIsReservedBeforeTheEffectsFactoryCanReenter() {
        let harness = Harness()
        harness.effects.makeHook = { [weak harness] _, _ in
            harness?.coordinator.showConfiguration(from: .search)
        }

        harness.coordinator.showConfiguration(from: .statusMenu)

        #expect(harness.events == [
            .hideSearch,
            .makeConfiguration(.statusMenu),
            .showConfiguration,
        ])
        #expect(harness.effects.presentations.count == 1)
    }

    @Test func synchronousFactoryCloseDoesNotLeaveAStaleActiveSession() {
        let harness = Harness()
        harness.effects.makeHook = { onFinished, _ in onFinished() }

        harness.coordinator.showConfiguration(from: .statusMenu)
        #expect(harness.coordinator.showSearch() == .searchPresented)

        #expect(harness.events == [
            .hideSearch,
            .makeConfiguration(.statusMenu),
            .startSearch,
            .showSearch,
        ])
    }

    @Test func firstStatusMenuOriginPreventsLaterSearchOriginFromRestoringSearch() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .statusMenu)
        harness.coordinator.showConfiguration(from: .search)
        harness.events.removeAll()

        harness.effects.presentations[0].close(.finished)

        #expect(harness.events == [.startSearch])
    }

    @Test func firstSearchOriginRestoresSearchDespiteLaterStatusMenuRequest() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .search)
        harness.coordinator.showConfiguration(from: .statusMenu)
        harness.events.removeAll()

        harness.effects.presentations[0].close(.finished)

        #expect(harness.events == [.startSearch, .showSearch])
    }

    @Test func configurationRestorationFollowsItsOriginAndCloseOutcome() {
        let cases: [(ConfigurationOrigin, CloseOutcome, Bool)] = [
            (.initialSetup, .finished, true),
            (.initialSetup, .dismissed, false),
            (.statusMenu, .finished, false),
            (.statusMenu, .dismissed, false),
            (.search, .finished, true),
            (.search, .dismissed, true),
        ]

        for (origin, outcome, restoresSearch) in cases {
            let harness = Harness()
            harness.coordinator.showConfiguration(from: origin)
            harness.events.removeAll()

            harness.effects.presentations[0].close(outcome)

            #expect(
                harness.events
                    == (restoresSearch ? [.startSearch, .showSearch] : [.startSearch]),
                "Unexpected restoration for \(origin) after \(outcome)"
            )
        }
    }

    @Test func repeatedCloseCallbackIsIgnored() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .search)
        let presentation = harness.effects.presentations[0]
        harness.events.removeAll()

        presentation.close(.finished)
        presentation.close(.dismissed)

        #expect(harness.events == [.startSearch, .showSearch])
    }

    @Test func staleCallbackCannotCloseNewerConfigurationSession() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .statusMenu)
        let stalePresentation = harness.effects.presentations[0]
        stalePresentation.close(.finished)
        harness.coordinator.showConfiguration(from: .search)
        harness.events.removeAll()

        stalePresentation.close(.dismissed)
        #expect(harness.coordinator.showSearch() == .configurationFocused)

        #expect(harness.events == [.showConfiguration])
        #expect(harness.effects.presentations.count == 2)
    }

    @Test func closeRetiresSessionBeforeStartingAndRestoringSearch() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .search)
        let closingPresentation = harness.effects.presentations[0]
        harness.onStart = { [weak harness] in
            harness?.coordinator.showConfiguration(from: .statusMenu)
        }
        harness.events.removeAll()

        closingPresentation.close(.finished)

        #expect(harness.events == [
            .startSearch,
            .hideSearch,
            .makeConfiguration(.statusMenu),
            .showConfiguration,
            .showConfiguration,
        ])
    }

    @Test func coordinatorRetainsOnlyTheActiveConfigurationPresentation() {
        let effects = WeakPresentationEffects()
        let coordinator = ApplicationPresentationCoordinator(
            effects: effects,
            ensureSearchStarted: {}
        )

        coordinator.showConfiguration(from: .statusMenu)
        let firstPresentation = WeakBox(effects.latestPresentation)
        #expect(firstPresentation.value != nil)

        effects.callbacks[0].finished()
        #expect(firstPresentation.value == nil)

        coordinator.showConfiguration(from: .search)
        let replacementPresentation = WeakBox(effects.latestPresentation)
        #expect(replacementPresentation.value != nil)

        effects.callbacks[0].dismissed()
        #expect(replacementPresentation.value != nil)

        effects.callbacks[1].dismissed()
        #expect(replacementPresentation.value == nil)
    }

    @Test func configurationControllerFinishEmitsOnlyFinished() {
        var finishedCount = 0
        var dismissedCount = 0
        let controller = makeConfigurationController(
            onFinished: { finishedCount += 1 },
            onDismissed: { dismissedCount += 1 }
        )

        controller.finish()

        #expect(finishedCount == 1)
        #expect(dismissedCount == 0)
    }

    @Test func configurationControllerWindowCloseEmitsOnlyDismissed() {
        var finishedCount = 0
        var dismissedCount = 0
        let controller = makeConfigurationController(
            onFinished: { finishedCount += 1 },
            onDismissed: { dismissedCount += 1 }
        )

        controller.show()
        controller.close()

        #expect(finishedCount == 0)
        #expect(dismissedCount == 1)
    }

    @Test func appDelegateFactoryBuildsTheSharedConfigurationController() {
        let delegate = AppDelegate()

        let presentation = delegate.makeConfiguration(
            origin: .statusMenu,
            onFinished: {},
            onDismissed: {}
        )

        #expect(presentation is FloodlightConfigurationWindowController)
    }

    @Test func appDelegateStatusMenuDockAndHotKeyKeepConfigurationExclusive() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let settingsItem = try #require(menu.items.first { $0.title == "Settings…" })
        let settingsAction = try #require(settingsItem.action)

        #expect(NSApp.sendAction(settingsAction, to: settingsItem.target, from: settingsItem))
        let controller = try #require(activeConfigurationController())
        defer {
            controller.close()
            delegate.hideSearch()
        }

        let showItem = try #require(menu.items.first { $0.title == "Show Floodlight" })
        let showAction = try #require(showItem.action)
        #expect(NSApp.sendAction(showAction, to: showItem.target, from: showItem))
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        delegate.globalHotKeyDidFire()

        #expect(controller.window?.isVisible == true)
        #expect(!hasVisibleSearchPanel())
        #expect(activeConfigurationControllers().count == 1)
    }

    @Test func appDelegateSearchConfigurationRestoresSearchAfterClosing() throws {
        let delegate = AppDelegate()
        delegate.showSettingsFromSearch()
        let controller = try #require(activeConfigurationController())
        defer { delegate.hideSearch() }

        controller.close()

        #expect(hasVisibleSearchPanel())
    }
}

@MainActor
private func makeConfigurationController(
    onFinished: @escaping () -> Void,
    onDismissed: @escaping () -> Void
) -> FloodlightConfigurationWindowController {
    FloodlightConfigurationWindowController(
        presentation: .settings,
        activeShortcut: .optionSpace,
        launchesAtLogin: false,
        rootURL: FileManager.default.temporaryDirectory,
        selectShortcut: { .requestedShortcutActive($0) },
        setLaunchAtLogin: { _ in nil },
        chooseScope: { nil },
        onFinished: onFinished,
        onDismissed: onDismissed
    )
}

@MainActor
private func activeConfigurationController() -> FloodlightConfigurationWindowController? {
    activeConfigurationControllers().first
}

@MainActor
private func activeConfigurationControllers() -> [FloodlightConfigurationWindowController] {
    NSApp.windows.compactMap { window in
        guard window.isVisible else { return nil }
        return window.windowController as? FloodlightConfigurationWindowController
    }
}

@MainActor
private func hasVisibleSearchPanel() -> Bool {
    NSApp.windows.contains { $0 is FloodlightPanel && $0.isVisible }
}

@MainActor
private final class ScriptedEffects: ApplicationPresentationEffects {
    private let record: (Event) -> Void
    private(set) var presentations: [ScriptedConfigurationPresentation] = []
    var makeHook: ((@MainActor () -> Void, @MainActor () -> Void) -> Void)?

    init(events record: @escaping (Event) -> Void) {
        self.record = record
    }

    func showSearch() {
        record(.showSearch)
    }

    func hideSearch() {
        record(.hideSearch)
    }

    func toggleSearch() {
        record(.toggleSearch)
    }

    func makeConfiguration(
        origin: ConfigurationOrigin,
        onFinished: @escaping @MainActor () -> Void,
        onDismissed: @escaping @MainActor () -> Void
    ) -> any ConfigurationPresenting {
        record(.makeConfiguration(origin))
        let hook = makeHook
        makeHook = nil
        hook?(onFinished, onDismissed)
        let presentation = ScriptedConfigurationPresentation(
            record: record,
            onFinished: onFinished,
            onDismissed: onDismissed
        )
        presentations.append(presentation)
        return presentation
    }
}

@MainActor
private final class ScriptedConfigurationPresentation: ConfigurationPresenting {
    private let record: (Event) -> Void
    private let onFinished: @MainActor () -> Void
    private let onDismissed: @MainActor () -> Void

    init(
        record: @escaping (Event) -> Void,
        onFinished: @escaping @MainActor () -> Void,
        onDismissed: @escaping @MainActor () -> Void
    ) {
        self.record = record
        self.onFinished = onFinished
        self.onDismissed = onDismissed
    }

    func show() {
        record(.showConfiguration)
    }

    func close(_ outcome: CloseOutcome) {
        switch outcome {
        case .finished:
            onFinished()
        case .dismissed:
            onDismissed()
        }
    }
}

@MainActor
private final class WeakPresentationEffects: ApplicationPresentationEffects {
    struct Callbacks {
        let finished: @MainActor () -> Void
        let dismissed: @MainActor () -> Void
    }

    weak var latestPresentation: LifecyclePresentation?
    private(set) var callbacks: [Callbacks] = []

    func showSearch() {}
    func hideSearch() {}
    func toggleSearch() {}

    func makeConfiguration(
        origin: ConfigurationOrigin,
        onFinished: @escaping @MainActor () -> Void,
        onDismissed: @escaping @MainActor () -> Void
    ) -> any ConfigurationPresenting {
        let presentation = LifecyclePresentation()
        latestPresentation = presentation
        callbacks.append(Callbacks(finished: onFinished, dismissed: onDismissed))
        return presentation
    }
}

@MainActor
private final class LifecyclePresentation: ConfigurationPresenting {
    func show() {}
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

@MainActor
private final class Harness {
    var events: [Event] = []
    var onStart: (() -> Void)?
    let effects: ScriptedEffects
    let coordinator: ApplicationPresentationCoordinator

    init() {
        var eventSink: ((Event) -> Void)?
        var startAction: (() -> Void)?
        effects = ScriptedEffects { eventSink?($0) }
        coordinator = ApplicationPresentationCoordinator(
            effects: effects,
            ensureSearchStarted: {
                eventSink?(.startSearch)
                startAction?()
            }
        )
        eventSink = { [weak self] in self?.events.append($0) }
        startAction = { [weak self] in self?.onStart?() }
    }
}

private enum CloseOutcome {
    case finished
    case dismissed
}

private enum Event: Equatable {
    case startSearch
    case showSearch
    case hideSearch
    case toggleSearch
    case makeConfiguration(ConfigurationOrigin)
    case showConfiguration
}
