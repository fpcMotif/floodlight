import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// The application the user will paste into once Floodlight dismisses, and
/// the ⌘V that gets a Clipboard History entry there (#66).
///
/// The panel captures the target when it is summoned — whoever was frontmost
/// at that instant — and the action effects ask for delivery once the panel
/// has ordered out. Delivery is a synthesized ⌘V, which macOS only lets a
/// process post after the user has trusted it under Accessibility; without
/// that trust Return degrades to copy-and-dismiss and the footer says so.
@MainActor
final class PasteTargetDelivery {
    struct Target: Equatable, Sendable {
        let name: String
        let processIdentifier: pid_t
    }

    /// Set once the macOS Accessibility prompt has been shown, so a user who
    /// declined is never asked again — the footer's "Copy" keeps telling
    /// them what Return does instead.
    static let accessibilityPromptedDefaultsKey = "paste-delivery-accessibility-prompted"

    /// How long the target gets to become frontmost after activation, in
    /// 15 ms polls. Ordinary apps take one or two; a wedged app never does.
    private static let frontmostPollLimit = 40
    private static let frontmostPollMilliseconds = 15
    /// After the app is frontmost, its key window still has to take focus;
    /// Electron shells lag AppKit ones by a frame or two here.
    private static let keyWindowSettleMilliseconds = 80

    private(set) var target: Target?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether macOS lets Floodlight post the keystroke at all.
    var isAvailable: Bool {
        AXIsProcessTrusted()
    }

    /// Remembers who was frontmost when the panel was summoned.
    func capture(frontmost: NSRunningApplication?) {
        let candidate = frontmost.flatMap { application -> Target? in
            let name = application.localizedName
                ?? application.bundleURL?.deletingPathExtension().lastPathComponent
            guard let name, !name.isEmpty else { return nil }
            return Target(name: name, processIdentifier: application.processIdentifier)
        }
        let previousIsRunning = target.flatMap {
            NSRunningApplication(processIdentifier: $0.processIdentifier)
        }.map { !$0.isTerminated } ?? false
        target = Self.resolveTarget(
            frontmost: candidate,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            previous: target,
            previousIsRunning: previousIsRunning
        )
    }

    /// Floodlight never pastes into itself: when it was frontmost — the panel
    /// was re-summoned before anyone else took focus — the previous target
    /// stands as long as that app still runs.
    nonisolated static func resolveTarget(
        frontmost: Target?,
        ownProcessIdentifier: pid_t,
        previous: Target?,
        previousIsRunning: Bool
    ) -> Target? {
        if let frontmost, frontmost.processIdentifier != ownProcessIdentifier {
            return frontmost
        }
        return previousIsRunning ? previous : nil
    }

    /// Hands the target a ⌘V once it is frontmost again. Nothing reports
    /// whether the target honoured the keystroke, so this only logs the
    /// reasons it never posted one.
    func deliver() async {
        guard let target else { return }
        guard isAvailable else {
            promptForAccessibilityOnce()
            return
        }
        guard let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              !application.isTerminated
        else {
            NSLog("Floodlight could not paste: %@ is no longer running.", target.name)
            return
        }

        if !isFrontmost(target) {
            NSApp.yieldActivation(to: application)
            application.activate()
        }
        guard await waitUntilFrontmost(target) else {
            NSLog("Floodlight could not paste: %@ did not come to the front.", target.name)
            return
        }
        guard !IsSecureEventInputEnabled() else {
            NSLog("Floodlight did not paste into %@: secure input is on.", target.name)
            return
        }
        try? await Task.sleep(for: .milliseconds(Self.keyWindowSettleMilliseconds))
        if !Self.postCommandV() {
            NSLog("Floodlight could not synthesize ⌘V for %@.", target.name)
        }
    }

    private func isFrontmost(_ target: Target) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func waitUntilFrontmost(_ target: Target) async -> Bool {
        for _ in 0..<Self.frontmostPollLimit {
            if isFrontmost(target) { return true }
            try? await Task.sleep(for: .milliseconds(Self.frontmostPollMilliseconds))
        }
        return isFrontmost(target)
    }

    /// The system's own dialog, which adds Floodlight to the Accessibility
    /// list with a button straight into System Settings.
    private func promptForAccessibilityOnce() {
        guard !defaults.bool(forKey: Self.accessibilityPromptedDefaultsKey) else { return }
        defaults.set(true, forKey: Self.accessibilityPromptedDefaultsKey)
        // `kAXTrustedCheckOptionPrompt` is a C global Swift 6 will not touch
        // from an actor; its value is this string.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private static func postCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: keyCode,
            keyDown: true
        ),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
