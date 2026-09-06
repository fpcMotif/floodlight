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

    /// Floodlight never pastes into itself, so its own bundle yields `nil`.
    static func pasteTargetName(
        frontmostName: String?,
        frontmostBundleID: String?,
        ownBundleID: String?
    ) -> String? {
        guard let frontmostName, !frontmostName.isEmpty else { return nil }
        if let frontmostBundleID, let ownBundleID, frontmostBundleID == ownBundleID {
            return nil
        }
        return frontmostName
    }
}
