import AppKit
import SwiftUI

enum FloodlightConfigurationPresentation {
    case onboarding
    case settings

    var title: String {
        switch self {
        case .onboarding: "Set up Floodlight"
        case .settings: "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .onboarding: "Choose a shortcut and give Floodlight search access."
        case .settings: "Manage your shortcut, startup behavior, and search access."
        }
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let presentation: FloodlightConfigurationPresentation
    private let session: OnboardingSession
    private let flow: OnboardingFlowState
    private let setLaunchAtLogin: (Bool) -> String?
    private let chooseScope: () -> URL?
    private let onFinished: () -> Void
    private let onDismissed: () -> Void

    init(
        presentation: FloodlightConfigurationPresentation = .onboarding,
        activeShortcut: FloodlightShortcut,
        launchesAtLogin: Bool,
        rootURL: URL,
        selectShortcut: @escaping (FloodlightShortcut) -> Bool,
        setLaunchAtLogin: @escaping (Bool) -> String?,
        chooseScope: @escaping () -> URL?,
        onFinished: @escaping () -> Void,
        onDismissed: @escaping () -> Void
    ) {
        self.presentation = presentation
        let session = OnboardingSession(
            activeShortcut: activeShortcut,
            launchesAtLogin: launchesAtLogin,
            rootURL: rootURL
        )
        self.session = session
        flow = OnboardingFlowState(
            session: session,
            selectShortcut: selectShortcut,
            openSpotlightSettings: OnboardingWindowController.openSpotlightSettings
        )
        self.setLaunchAtLogin = setLaunchAtLogin
        self.chooseScope = chooseScope
        self.onFinished = onFinished
        self.onDismissed = onDismissed

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 530),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = presentation.title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .documentWindow
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.center()

        let view = OnboardingView(
            presentation: presentation,
            session: session,
            onSelectShortcut: { [weak self] in self?.flow.handleShortcutSelection($0) },
            onSetLaunchAtLogin: { [weak self] in self?.handleLaunchAtLogin($0) },
            onChooseScope: { [weak self] in self?.handleChooseScope() },
            onOpenSpotlightSettings: { [weak self] in
                self?.flow.beginSpotlightReplacement()
            },
            onOpenFullDiskAccess: Self.openFullDiskAccess,
            onFinish: { [weak self] in self?.finish() }
        )
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(NSSize(width: 760, height: 530))
        window.minSize = NSSize(width: 680, height: 500)
        window.maxSize = NSSize(width: 900, height: 650)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        session.refreshFullDiskAccess()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !flow.didFinish else { return }
        onDismissed()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        session.refreshFullDiskAccess()
        flow.retryPendingShortcut()
    }

    private func handleLaunchAtLogin(_ enabled: Bool) {
        if let error = setLaunchAtLogin(enabled) {
            session.launchAtLoginMessage = error
        } else {
            session.launchesAtLogin = enabled
            session.launchAtLoginMessage = nil
        }
    }

    private func handleChooseScope() {
        guard let selectedURL = chooseScope() else { return }
        session.rootURL = selectedURL.standardizedFileURL
    }

    private func finish() {
        if presentation == .onboarding {
            session.complete()
        }
        flow.markFinished()
        close()
        onFinished()
    }

    private static func openSpotlightSettings() {
        openSystemSettings(
            primary: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts",
            fallback: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"
        )
    }

    private static func openFullDiskAccess() {
        openSystemSettings(
            primary:
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            fallback: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        )
    }

    private static func openSystemSettings(primary: String, fallback: String) {
        guard let primaryURL = URL(string: primary),
              !NSWorkspace.shared.open(primaryURL),
              let fallbackURL = URL(string: fallback) else {
            return
        }
        NSWorkspace.shared.open(fallbackURL)
    }
}
