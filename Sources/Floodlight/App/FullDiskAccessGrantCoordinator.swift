import AppKit
import Foundation

package enum FullDiskAccessGrantPhase: Equatable, Sendable {
    case idle
    case presentingGuidance(appURL: URL, isPolling: Bool)
    case granted
    case dismissed
}

@MainActor
package final class FullDiskAccessGrantCoordinator {
    package private(set) var phase: FullDiskAccessGrantPhase = .idle
    // periphery:ignore - test seam: the anchor-tracking test reads the live
    // panel's frame after a poll; production drives the panel only from here.
    package var activeGuidancePanel: FullDiskAccessGuidancePanel? {
        panel
    }

    private let openSettings: () -> Void
    private let fullDiskAccessProvider: () -> Bool
    private let bundleURL: () -> URL
    private let targetWindowLocator: () -> NSRect?
    package var parentWindowProvider: (() -> NSRect?)?
    private let onGranted: () -> Void
    private let onDismissed: () -> Void
    private let autoPresentPanel: Bool
    private let appNotificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter

    private var pollTimer: Timer?
    private var dismissTask: Task<Void, Never>?
    private var panel: FullDiskAccessGuidancePanel?
    private var notificationObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    package init(
        openSettings: @escaping () -> Void = {
            FullDiskAccessGrantCoordinator.openSystemSettingsFullDiskAccess()
        },
        fullDiskAccessProvider: @escaping () -> Bool = {
            FloodlightFullDiskAccess.isGranted()
        },
        bundleURL: @escaping () -> URL = {
            Bundle.main.bundleURL
        },
        targetWindowLocator: @escaping () -> NSRect? = {
            SystemSettingsWindowLocator.locateWindow()
        },
        parentWindowProvider: (() -> NSRect?)? = nil,
        onGranted: @escaping () -> Void = {},
        onDismissed: @escaping () -> Void = {},
        autoPresentPanel: Bool = true,
        appNotificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.openSettings = openSettings
        self.fullDiskAccessProvider = fullDiskAccessProvider
        self.bundleURL = bundleURL
        self.targetWindowLocator = targetWindowLocator
        self.parentWindowProvider = parentWindowProvider
        self.onGranted = onGranted
        self.onDismissed = onDismissed
        self.autoPresentPanel = autoPresentPanel
        self.appNotificationCenter = appNotificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
    }

    isolated deinit {
        stopPolling()
    }

    package func beginGrantFlow() {
        if fullDiskAccessProvider() {
            phase = .granted
            onGranted()
            return
        }

        if case .presentingGuidance = phase {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        let appURL = bundleURL()
        phase = .presentingGuidance(appURL: appURL, isPolling: true)
        openSettings()

        if autoPresentPanel {
            showGuidancePanel(appURL: appURL)
        }

        startPolling()
    }

    package func poll() {
        guard case .presentingGuidance = phase else { return }

        if fullDiskAccessProvider() {
            handleGrantDetected()
            return
        }

        if autoPresentPanel, let panel {
            let targetRect = targetWindowLocator()
            let parentRect = parentWindowProvider?()
            panel.updateAnchorFrame(targetRect: targetRect, parentRect: parentRect)
        }
    }

    package func dismiss() {
        stopPolling()
        panel?.close()
        panel = nil
        phase = .dismissed
        onDismissed()
    }

    private func handleGrantDetected() {
        stopPolling()
        phase = .granted
        onGranted()

        if autoPresentPanel {
            panel?.updatePhase(.granted)
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                self?.dismiss()
            }
        }
    }

    private func startPolling() {
        stopPolling()

        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        pollTimer = timer

        let appActiveObserver = appNotificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }

        let workspaceObserver = workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }

        notificationObservers = [
            (appNotificationCenter, appActiveObserver),
            (workspaceNotificationCenter, workspaceObserver),
        ]
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        for (center, observer) in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers.removeAll()
        dismissTask?.cancel()
        dismissTask = nil
    }

    private func showGuidancePanel(appURL: URL) {
        if panel == nil {
            let guidancePanel = FullDiskAccessGuidancePanel(
                coordinator: self,
                appURL: appURL
            )
            panel = guidancePanel
        }
        let targetRect = targetWindowLocator()
        let parentRect = parentWindowProvider?()
        panel?.show(targetRect: targetRect, parentRect: parentRect)
    }

    private static func openSystemSettingsFullDiskAccess() {
        let primary = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        let fallback = "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        guard let primaryURL = URL(string: primary),
              !NSWorkspace.shared.open(primaryURL),
              let fallbackURL = URL(string: fallback)
        else {
            return
        }
        NSWorkspace.shared.open(fallbackURL)
    }
}
