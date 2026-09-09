import Foundation
import Observation

/// What the panel knows and the board cannot derive from the Search Session:
/// the application the user will paste into once Floodlight dismisses, and
/// the Quick Look toggle the panel controller owns. Kept outside
/// `SearchCoordinator` so presentation facts never enter the session model.
@MainActor
@Observable
final class ClipboardBoardContext {
    /// Display name of the application that was frontmost when the panel was
    /// summoned — `nil` when that was Floodlight itself or unknown.
    var pasteTargetAppName: String?
    /// Whether macOS lets Floodlight post the ⌘V that Paste Delivery needs
    /// (#66) — Accessibility trust, read when the panel is summoned.
    var isPasteDeliveryAvailable = false
    @ObservationIgnored
    var previewHandler: (@MainActor () -> Void)?
    /// Installed by the footer's Actions chip; ⌘K and a click both call it.
    @ObservationIgnored
    var actionsHandler: (@MainActor () -> Void)?

    init(pasteTargetAppName: String? = nil) {
        self.pasteTargetAppName = pasteTargetAppName
    }

    func requestPreview() {
        previewHandler?()
    }

    func requestActions() {
        actionsHandler?()
    }

    /// What Return will do, told truthfully: it pastes only when there is an
    /// application to paste into and macOS lets Floodlight post the
    /// keystroke; otherwise it copies and closes, and the chip says so.
    static func pasteLabel(targetAppName: String?, isDeliveryAvailable: Bool) -> String {
        guard isDeliveryAvailable, let targetAppName else { return "Copy" }
        return "Paste to \(targetAppName)"
    }
}
