import XCTest
@testable import Floodlight

@MainActor
final class ApplicationPresentationCoordinatorTests: XCTestCase {
    func testLaunchWithoutInitialSetupStartsSearchBeforePresentingIt() {
        var events: [Event] = []
        let effects = ScriptedEffects(events: { events.append($0) })
        let coordinator = ApplicationPresentationCoordinator(
            effects: effects,
            ensureSearchStarted: { events.append(.startSearch) }
        )

        coordinator.launch(initialSetupRequired: false)

        XCTAssertEqual(events, [.startSearch, .showSearch])
    }

    func testLaunchWithInitialSetupPresentsConfigurationInsteadOfSearch() {
        let harness = Harness()

        harness.coordinator.launch(initialSetupRequired: true)

        XCTAssertEqual(
            harness.events,
            [.hideSearch, .makeConfiguration(.initialSetup), .showConfiguration]
        )
    }

    func testLaunchRechecksConfigurationPriorityAfterStartingSearch() {
        let harness = Harness()
        harness.onStart = { [weak harness] in
            harness?.coordinator.showConfiguration(from: .statusMenu)
        }

        harness.coordinator.launch(initialSetupRequired: false)

        XCTAssertEqual(
            harness.events,
            [
                .startSearch,
                .hideSearch,
                .makeConfiguration(.statusMenu),
                .showConfiguration,
                .showConfiguration,
            ]
        )
    }

    func testSearchRequestsRouteToSearchWhenConfigurationIsInactive() {
        let harness = Harness()

        XCTAssertEqual(harness.coordinator.showSearch(), .searchPresented)
        XCTAssertEqual(harness.coordinator.toggleSearch(), .searchPresented)
        harness.coordinator.hideSearch()

        XCTAssertEqual(harness.events, [.showSearch, .toggleSearch, .hideSearch])
    }

    func testSearchPresentationFocusesActiveConfiguration() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .statusMenu)
        harness.events.removeAll()

        XCTAssertEqual(harness.coordinator.showSearch(), .configurationFocused)
        XCTAssertEqual(harness.coordinator.toggleSearch(), .configurationFocused)

        XCTAssertEqual(harness.events, [.showConfiguration, .showConfiguration])
    }

    func testRepeatedConfigurationRequestFocusesExistingSession() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .statusMenu)
        harness.coordinator.showConfiguration(from: .search)

        XCTAssertEqual(
            harness.events,
            [
                .hideSearch,
                .makeConfiguration(.statusMenu),
                .showConfiguration,
                .showConfiguration,
            ]
        )
        XCTAssertEqual(harness.effects.presentations.count, 1)
    }

    func testConfigurationIsReservedBeforeTheEffectsFactoryCanReenter() {
        let harness = Harness()
        harness.effects.makeHook = { [weak harness] _, _ in
            harness?.coordinator.showConfiguration(from: .search)
        }

        harness.coordinator.showConfiguration(from: .statusMenu)

        XCTAssertEqual(
            harness.events,
            [.hideSearch, .makeConfiguration(.statusMenu), .showConfiguration]
        )
        XCTAssertEqual(harness.effects.presentations.count, 1)
    }

    func testSynchronousFactoryCloseDoesNotLeaveAStaleActiveSession() {
        let harness = Harness()
        harness.effects.makeHook = { onFinished, _ in onFinished() }

        harness.coordinator.showConfiguration(from: .statusMenu)
        XCTAssertEqual(harness.coordinator.showSearch(), .searchPresented)

        XCTAssertEqual(
            harness.events,
            [
                .hideSearch,
                .makeConfiguration(.statusMenu),
                .startSearch,
                .showSearch,
            ]
        )
    }

    func testFirstStatusMenuOriginPreventsLaterSearchOriginFromRestoringSearch() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .statusMenu)
        harness.coordinator.showConfiguration(from: .search)
        harness.events.removeAll()

        harness.effects.presentations[0].close(.finished)

        XCTAssertEqual(harness.events, [.startSearch])
    }

    func testFirstSearchOriginRestoresSearchDespiteLaterStatusMenuRequest() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .search)
        harness.coordinator.showConfiguration(from: .statusMenu)
        harness.events.removeAll()

        harness.effects.presentations[0].close(.finished)

        XCTAssertEqual(harness.events, [.startSearch, .showSearch])
    }

    func testConfigurationRestorationFollowsItsOriginAndCloseOutcome() {
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

            XCTAssertEqual(
                harness.events,
                restoresSearch ? [.startSearch, .showSearch] : [.startSearch],
                "Unexpected restoration for \(origin) after \(outcome)"
            )
        }
    }

    func testRepeatedCloseCallbackIsIgnored() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .search)
        let presentation = harness.effects.presentations[0]
        harness.events.removeAll()

        presentation.close(.finished)
        presentation.close(.dismissed)

        XCTAssertEqual(harness.events, [.startSearch, .showSearch])
    }

    func testStaleCallbackCannotCloseNewerConfigurationSession() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .statusMenu)
        let stalePresentation = harness.effects.presentations[0]
        stalePresentation.close(.finished)
        harness.coordinator.showConfiguration(from: .search)
        harness.events.removeAll()

        stalePresentation.close(.dismissed)
        XCTAssertEqual(harness.coordinator.showSearch(), .configurationFocused)

        XCTAssertEqual(harness.events, [.showConfiguration])
        XCTAssertEqual(harness.effects.presentations.count, 2)
    }

    func testCloseRetiresSessionBeforeStartingAndRestoringSearch() {
        let harness = Harness()
        harness.coordinator.showConfiguration(from: .search)
        let closingPresentation = harness.effects.presentations[0]
        harness.onStart = { [weak harness] in
            harness?.coordinator.showConfiguration(from: .statusMenu)
        }
        harness.events.removeAll()

        closingPresentation.close(.finished)

        XCTAssertEqual(
            harness.events,
            [
                .startSearch,
                .hideSearch,
                .makeConfiguration(.statusMenu),
                .showConfiguration,
                .showConfiguration,
            ]
        )
    }

    func testCoordinatorRetainsOnlyTheActiveConfigurationPresentation() {
        let effects = WeakPresentationEffects()
        let coordinator = ApplicationPresentationCoordinator(
            effects: effects,
            ensureSearchStarted: {}
        )

        coordinator.showConfiguration(from: .statusMenu)
        let firstPresentation = WeakBox(effects.latestPresentation)
        XCTAssertNotNil(firstPresentation.value)

        effects.callbacks[0].finished()
        XCTAssertNil(firstPresentation.value)

        coordinator.showConfiguration(from: .search)
        let replacementPresentation = WeakBox(effects.latestPresentation)
        XCTAssertNotNil(replacementPresentation.value)

        effects.callbacks[0].dismissed()
        XCTAssertNotNil(replacementPresentation.value)

        effects.callbacks[1].dismissed()
        XCTAssertNil(replacementPresentation.value)
    }

    func testConfigurationControllerFinishEmitsOnlyFinished() {
        var finishedCount = 0
        var dismissedCount = 0
        let controller = makeConfigurationController(
            onFinished: { finishedCount += 1 },
            onDismissed: { dismissedCount += 1 }
        )

        controller.finish()

        XCTAssertEqual(finishedCount, 1)
        XCTAssertEqual(dismissedCount, 0)
    }

    func testConfigurationControllerWindowCloseEmitsOnlyDismissed() {
        var finishedCount = 0
        var dismissedCount = 0
        let controller = makeConfigurationController(
            onFinished: { finishedCount += 1 },
            onDismissed: { dismissedCount += 1 }
        )

        controller.show()
        controller.close()

        XCTAssertEqual(finishedCount, 0)
        XCTAssertEqual(dismissedCount, 1)
    }

    func testAppDelegateFactoryBuildsTheSharedConfigurationController() {
        let delegate = AppDelegate()

        let presentation = delegate.makeConfiguration(
            origin: .statusMenu,
            onFinished: {},
            onDismissed: {}
        )

        XCTAssertTrue(presentation is FloodlightConfigurationWindowController)
    }

    func testAppDelegateStatusMenuDockAndHotKeyKeepConfigurationExclusive() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let settingsItem = try XCTUnwrap(menu.items.first { $0.title == "Settings…" })
        let settingsAction = try XCTUnwrap(settingsItem.action)

        XCTAssertTrue(NSApp.sendAction(settingsAction, to: settingsItem.target, from: settingsItem))
        let controller = try XCTUnwrap(activeConfigurationController())
        defer {
            controller.close()
            delegate.hideSearch()
        }

        let showItem = try XCTUnwrap(menu.items.first { $0.title == "Show Floodlight" })
        let showAction = try XCTUnwrap(showItem.action)
        XCTAssertTrue(NSApp.sendAction(showAction, to: showItem.target, from: showItem))
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        delegate.globalHotKeyDidFire()

        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertFalse(hasVisibleSearchPanel())
        XCTAssertEqual(activeConfigurationControllers().count, 1)
    }

    func testAppDelegateSearchConfigurationRestoresSearchAfterClosing() throws {
        let delegate = AppDelegate()
        delegate.showSettingsFromSearch()
        let controller = try XCTUnwrap(activeConfigurationController())
        defer { delegate.hideSearch() }

        controller.close()

        XCTAssertTrue(hasVisibleSearchPanel())
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
