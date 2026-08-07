import AppKit

/// Presents the standard folder chooser used to pick a new search root.
/// Kept out of `SearchCoordinator` since modal window presentation is shell
/// concern, not search behavior.
@MainActor
enum RootPicker {
    static func choose(startingAt rootURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to search"
        panel.message = "Floodlight will search this folder and keep results up to date."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
