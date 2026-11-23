import AppKit

/// Presents the standard folder chooser used to pick a new search root.
/// Kept out of `SearchCoordinator` since modal window presentation is shell
/// concern, not search behavior.
@MainActor
enum RootPicker {
    static func choose(currentRoot: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to search"
        panel.message = "Floodlight will search this folder and keep results up to date."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentRoot

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// Requests a scope change; only `model.rootURL` represents a committed
    /// scope, so callers cannot publish the picker's unconfirmed candidate.
    static func chooseAndApply(to model: SearchCoordinator) {
        guard let selectedURL = choose(currentRoot: model.rootURL) else { return }
        model.changeRoot(to: selectedURL)
    }
}
