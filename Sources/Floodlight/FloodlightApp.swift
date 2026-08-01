import SwiftUI

@main
struct FloodlightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            // AppDelegate owns the real settings window and its Command-, shortcut.
            // Suppress SwiftUI's default Settings command so repeated shortcuts
            // cannot open this otherwise-empty scene over that window.
            CommandGroup(replacing: .appSettings) {}
        }
    }
}
