import Foundation

@MainActor
final class OnboardingFlowState {
    private let session: OnboardingSession
    private let selectShortcut: (FloodlightShortcut) -> Bool
    private let openSpotlightSettings: () -> Void
    private(set) var pendingShortcut: FloodlightShortcut?
    private(set) var didFinish = false

    init(
        session: OnboardingSession,
        selectShortcut: @escaping (FloodlightShortcut) -> Bool,
        openSpotlightSettings: @escaping () -> Void
    ) {
        self.session = session
        self.selectShortcut = selectShortcut
        self.openSpotlightSettings = openSpotlightSettings
    }

    func handleShortcutSelection(_ shortcut: FloodlightShortcut) {
        pendingShortcut = nil

        guard shortcut != session.activeShortcut else {
            session.shortcutMessage = nil
            return
        }

        if selectShortcut(shortcut) {
            session.activeShortcut = shortcut
            session.shortcutMessage = nil
        } else if shortcut == .commandSpace {
            session.shortcutMessage =
                "Spotlight or another app still owns ⌘ Space. Floodlight kept \(session.activeShortcut.displayName) active."
        } else {
            session.shortcutMessage =
                "macOS could not register ⌥ Space. Floodlight kept \(session.activeShortcut.displayName) active."
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

        if selectShortcut(pendingShortcut) {
            session.activeShortcut = pendingShortcut
            session.shortcutMessage = "⌘ Space is ready."
            self.pendingShortcut = nil
        } else {
            session.shortcutMessage =
                "Spotlight still owns ⌘ Space. Turn off “Show Spotlight search” and return here."
        }
    }

    func markFinished() {
        didFinish = true
    }
}
