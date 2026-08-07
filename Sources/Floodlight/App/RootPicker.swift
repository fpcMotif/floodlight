import AppKit

/// Presents the folder chooser used to pick Floodlight's search scope.
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
}
