import Foundation

@MainActor
final class OnboardingFlowState {
    private let session: OnboardingSession
    private let selectShortcut: (FloodlightShortcut) -> GlobalHotKeyReplacementOutcome
    private let openSpotlightSettings: () -> Void
    private(set) var pendingShortcut: FloodlightShortcut?
    private(set) var didFinish = false

    init(
        session: OnboardingSession,
        selectShortcut: @escaping (FloodlightShortcut) -> GlobalHotKeyReplacementOutcome,
        openSpotlightSettings: @escaping () -> Void
    ) {
        self.session = session
        self.selectShortcut = selectShortcut
        self.openSpotlightSettings = openSpotlightSettings
    }

    func handleShortcutSelection(_ shortcut: FloodlightShortcut) {
        pendingShortcut = nil

        switch selectShortcut(shortcut) {
        case let .requestedShortcutActive(activeShortcut):
            session.activeShortcut = activeShortcut
            session.shortcutMessage = nil
        case let .previousShortcutActive(activeShortcut):
            session.activeShortcut = activeShortcut
            session.shortcutMessage = refusalMessage(
                for: shortcut,
                activeShortcut: activeShortcut
            )
        case .noShortcutActive:
            session.activeShortcut = nil
            session.shortcutMessage = inactiveMessage(for: shortcut)
        }
    }

    func beginSpotlightReplacement() {
        pendingShortcut = .commandSpace
        session.shortcutMessage =
            "Turn off “Show Spotlight search” in the pane that opens, then return here."
        openSpotlightSettings()
    }

    func retryPendingShortcut() {
        guard let pendingShortcut else { return }
        guard pendingShortcut != session.activeShortcut else {
            self.pendingShortcut = nil
            return
        }

        switch selectShortcut(pendingShortcut) {
        case let .requestedShortcutActive(activeShortcut):
            session.activeShortcut = activeShortcut
            session.shortcutMessage = "⌘ Space is ready."
            self.pendingShortcut = nil
        case let .previousShortcutActive(activeShortcut):
            session.activeShortcut = activeShortcut
            session.shortcutMessage =
                "Spotlight still owns ⌘ Space. Turn off “Show Spotlight search” and return here."
        case .noShortcutActive:
            session.activeShortcut = nil
            session.shortcutMessage =
                "Spotlight still owns ⌘ Space. Floodlight has no active shortcut; choose ⌥ Space or update Spotlight and try again."
        }
    }

    func markFinished() {
        didFinish = true
    }

    private func refusalMessage(
        for shortcut: FloodlightShortcut,
        activeShortcut: FloodlightShortcut
    ) -> String {
        if shortcut == .commandSpace {
            return "Spotlight or another app still owns ⌘ Space. Floodlight kept \(activeShortcut.displayName) active."
        }
        return "macOS could not register ⌥ Space. Floodlight kept \(activeShortcut.displayName) active."
    }

    private func inactiveMessage(for shortcut: FloodlightShortcut) -> String {
        if shortcut == .commandSpace {
            return "Spotlight or another app still owns ⌘ Space. Floodlight has no active shortcut; choose ⌥ Space to restore it."
        }
        return "macOS could not register ⌥ Space. Floodlight has no active shortcut; try again."
    }
}
