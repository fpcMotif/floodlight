import AppKit

/// Seam over `NSWorkspace`'s running-application lookup, so
/// `SearchCoordinator`'s fast path for already-open applications is
/// testable without touching AppKit or launching anything for real.
@MainActor
protocol RunningApplicationActivating {
    /// Brings the already-running app at `bundleURL` to the front, without
    /// going through Launch Services. Returns whether a running instance
    /// was found and activated.
    func activateIfRunning(bundleURL: URL) -> Bool
}

/// Production seam: matches against `NSWorkspace.shared.runningApplications`,
/// an array AppKit already keeps warm in-process — asking "is this app
/// already open?" costs nothing beyond a local scan, no Launch Services
/// round trip required just to answer that question.
struct WorkspaceRunningApplicationActivator: RunningApplicationActivating {
    func activateIfRunning(bundleURL: URL) -> Bool {
        let target = bundleURL.standardizedFileURL.path
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.path == target
        }) else {
            return false
        }
        return running.activate()
    }
}
