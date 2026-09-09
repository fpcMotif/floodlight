import Foundation

@MainActor
final class OnboardingFlowState {
    let fullDiskAccessCoordinator: FullDiskAccessGrantCoordinator
    private let session: OnboardingSession
    private let selectShortcut: (GlobalHotKeyAction, FloodlightShortcut)
        -> GlobalHotKeyReplacementOutcome
    private let openSpotlightSettings: () -> Void
    private(set) var pendingShortcut: FloodlightShortcut?
    private(set) var didFinish = false

    init(
        session: OnboardingSession,
        selectShortcut: @escaping (GlobalHotKeyAction, FloodlightShortcut)
            -> GlobalHotKeyReplacementOutcome,
        openSpotlightSettings: @escaping () -> Void,
        fullDiskAccessCoordinator: FullDiskAccessGrantCoordinator? = nil
    ) {
        self.session = session
        self.selectShortcut = selectShortcut
        self.openSpotlightSettings = openSpotlightSettings
        self
            .fullDiskAccessCoordinator = fullDiskAccessCoordinator ??
            FullDiskAccessGrantCoordinator(
                fullDiskAccessProvider: { [weak session] in
                    session?.refreshFullDiskAccess()
                    return session?.hasFullDiskAccess ?? FloodlightFullDiskAccess.isGranted()
                },
                onGranted: { [weak session] in
                    session?.refreshFullDiskAccess()
                }
            )
    }

    func handleShortcutSelection(_ shortcut: FloodlightShortcut) {
        pendingShortcut = nil

        switch selectShortcut(.summonSearch, shortcut) {
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
            session.shortcutMessage = inactiveMessage(for: shortcut, ownerName: "Floodlight")
        }
    }

    func handleClipboardShortcutSelection(_ shortcut: FloodlightShortcut) {
        switch selectShortcut(.showClipboard, shortcut) {
        case let .requestedShortcutActive(activeShortcut):
            session.activeClipboardShortcut = activeShortcut
            session.clipboardShortcutMessage = nil
        case let .previousShortcutActive(activeShortcut):
            session.activeClipboardShortcut = activeShortcut
            session.clipboardShortcutMessage = refusalMessage(
                for: shortcut,
                activeShortcut: activeShortcut
            )
        case .noShortcutActive:
            session.activeClipboardShortcut = nil
            session.clipboardShortcutMessage = inactiveMessage(
                for: shortcut,
                ownerName: "Clipboard History"
            )
        }
    }

    func beginSpotlightReplacement() {
        pendingShortcut = .commandSpace
        session.shortcutMessage =
            "Turn off “Show Spotlight search” in the pane that opens, then return here."
        openSpotlightSettings()
    }

    func beginFullDiskAccessGrant() {
        fullDiskAccessCoordinator.beginGrantFlow()
    }

    func retryPendingShortcut() {
        guard let pendingShortcut else { return }
        guard pendingShortcut != session.activeShortcut else {
            self.pendingShortcut = nil
            return
        }

        switch selectShortcut(.summonSearch, pendingShortcut) {
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
        fullDiskAccessCoordinator.dismiss()
    }

    private func refusalMessage(
        for shortcut: FloodlightShortcut,
        activeShortcut: FloodlightShortcut
    ) -> String {
        if shortcut == .commandSpace {
            return "Spotlight or another app still owns ⌘ Space. Floodlight kept \(activeShortcut.displayName) active."
        }
        return "macOS could not register \(shortcut.displayName). Floodlight kept \(activeShortcut.displayName) active."
    }

    private func inactiveMessage(for shortcut: FloodlightShortcut, ownerName: String) -> String {
        if shortcut == .commandSpace {
            return "Spotlight or another app still owns ⌘ Space. Floodlight has no active shortcut; choose \(shortcut.fallback.displayName) to restore it."
        }
        return "macOS could not register \(shortcut.displayName). \(ownerName) has no active shortcut; try again."
    }
}
