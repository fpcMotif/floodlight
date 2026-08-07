import Foundation
import ServiceManagement

/// Owns Floodlight's login-item registration.
enum LaunchAtLogin {
    private static let configuredKey = "launch-at-login-configured"

    static var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers the login item on the very first launch only.
    ///
    /// A launcher is only useful once it is already running, so Floodlight opts
    /// in for you. The `launch-at-login-configured` flag makes this a one-time
    /// decision: if you later turn it off — here or in System Settings — the
    /// next launch leaves it off instead of switching it back on.
    static func enableOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: configuredKey) else { return }
        defaults.set(true, forKey: configuredKey)

        guard SMAppService.mainApp.status != .enabled else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog(
                "Floodlight could not enable launch at login: %@",
                error.localizedDescription
            )
        }
    }

    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        UserDefaults.standard.set(true, forKey: configuredKey)
    }
}
