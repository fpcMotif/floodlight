import AppKit

/// Presents the folder chooser that picks Floodlight's search scope.
///
/// Running a modal window is the shell's business. The search coordinator only
/// needs the folder that comes back, so the panel is built and run here and the
/// re-rooting stays behind `SearchCoordinator.changeRoot(to:)`.
@MainActor
enum RootFolderPicker {
    static func makePanel(startingAt currentRoot: URL) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Choose a folder to search"
        panel.message = "Floodlight will search this folder and keep results up to date."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = currentRoot
        return panel
    }

    /// Runs the chooser and re-roots the search on selection, returning the
    /// chosen folder so onboarding can advance with it.
    @discardableResult
    static func choose(for model: SearchCoordinator) -> URL? {
        let panel = makePanel(startingAt: model.rootURL)
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }
        model.changeRoot(to: selectedURL)
        return selectedURL
    }
}
