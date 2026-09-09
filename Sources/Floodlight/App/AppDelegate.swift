import AppKit
import FloodlightEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Clipboard History is created once here and handed to both of its
    /// owners: Clipboard Capture writes it, Clipboard Search reads it for
    /// the Search Session (ADR 0008).
    private lazy var clipboardStore = (try? ClipboardHistoryStore())
        ?? ClipboardHistoryStore.inMemory()
    /// Paste Delivery's one instance (#66): the panel tells it who was
    /// frontmost, the action effects paste into that application.
    private let pasteDelivery = PasteTargetDelivery()
    private lazy var model = SearchCoordinator(
        clipboardSearch: ClipboardSearch(store: clipboardStore),
        actionEffects: AppKitSelectedResultActionEffects(pasteDelivery: pasteDelivery),
        onDismiss: { [weak self] in
            self?.searchDidDismiss()
        }
    )
    private lazy var panelController = FloodlightPanelController(
        model: model,
        pasteDelivery: pasteDelivery
    )
    private lazy var presentation = ApplicationPresentationCoordinator(
        effects: self,
        ensureSearchStarted: { [weak self] in self?.ensureSearchStarted() }
    )
    private lazy var globalHotKeyRegistration = GlobalHotKeyRegistration { [weak self] action in
        self?.globalHotKeyDidFire(action)
    }

    private lazy var clipboardCapture = ClipboardCaptureService(store: clipboardStore)

    // periphery:ignore - Assigned and never read on purpose: NSStatusBar hands
    // back an unowned item, so dropping this reference removes the menu bar
    // icon. The assignment *is* the use.
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var launchAtLoginItem: NSMenuItem?
    private var clipboardHistoryItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        installStatusItem()
        installGlobalHotKey()
        LaunchAtLogin.enableOnFirstRun()
        clipboardCapture.start()
        presentation.launch(initialSetupRequired: OnboardingSession.shouldPresent())
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardCapture.stop()
        globalHotKeyRegistration.stop()
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentation.showSearch()
        return true
    }

    @objc private func showPanel() {
        presentation.showSearch()
    }

    @objc private func showClipboardHistoryFromMenu() {
        presentation.showClipboardHistory()
    }

    @objc private func showSettings() {
        presentation.showConfiguration(from: .statusMenu)
    }

    @objc func showSettingsFromSearch() {
        presentation.showConfiguration(from: .search)
    }

    @objc private func chooseRoot() {
        guard presentation.showSearch() == .searchPresented else { return }
        RootPicker.chooseAndApply(to: model)
    }

    @objc private func rebuildIndex() {
        model.rebuildIndex()
    }

    private func searchDidDismiss() {
        presentation.hideSearch()
    }

    private func ensureSearchStarted() {
        model.start()
    }

    func globalHotKeyDidFire(_ action: GlobalHotKeyAction) {
        switch action {
        case .summonSearch: presentation.toggleSearch()
        case .showClipboard: presentation.showClipboardHistory()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let wanted = !LaunchAtLogin.launchesAtLogin
        do {
            try LaunchAtLogin.setLaunchAtLogin(wanted)
        } catch {
            let alert = NSAlert()
            alert.messageText = wanted
                ? "Floodlight could not be added to Login Items."
                : "Floodlight could not be removed from Login Items."
            alert.informativeText = """
            \(error.localizedDescription)

            You can change this yourself in System Settings → General → \
            Login Items & Extensions.
            """
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func installGlobalHotKey() {
        let preferred = GlobalHotKeyAction.summonSearch.preferredShortcut()
        if globalHotKeyRegistration.start(.summonSearch, preferred: preferred) == nil {
            NSLog("Floodlight could not register its global keyboard shortcut.")
        }
        let preferredClipboard = GlobalHotKeyAction.showClipboard.preferredShortcut()
        if globalHotKeyRegistration.start(.showClipboard, preferred: preferredClipboard) == nil {
            NSLog("Floodlight could not register its clipboard keyboard shortcut.")
        }
        refreshActiveShortcutDisplayNames()
    }

    private func refreshActiveShortcutDisplayNames() {
        model.activeShortcutDisplayName = globalHotKeyRegistration
            .activeShortcut(for: .summonSearch)?.displayName
        model.activeClipboardShortcutDisplayName = globalHotKeyRegistration
            .activeShortcut(for: .showClipboard)?.displayName
    }

    private func selectShortcut(
        _ action: GlobalHotKeyAction,
        _ shortcut: FloodlightShortcut
    ) -> GlobalHotKeyReplacementOutcome {
        let outcome = globalHotKeyRegistration.replace(action, with: shortcut)
        refreshActiveShortcutDisplayNames()
        return outcome
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = FloodlightMenuBarIcon.image()
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Floodlight"
            button.setAccessibilityLabel("Floodlight")
        }
        statusItem = item
        let menu = makeStatusMenu()
        menu.delegate = self
        statusMenu = menu
        item.menu = menu
    }

    /// Floodlight is an `LSUIElement` agent, so it never shows an application
    /// menu bar. Without this menu, everything in `installMenu()` is reachable
    /// only by key equivalent — and Launch at Login has none.
    func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()

        let show = NSMenuItem(
            title: "Show Floodlight",
            action: #selector(showPanel),
            keyEquivalent: " "
        )
        show.keyEquivalentModifierMask = [.command]
        show.target = self
        menu.addItem(show)

        let clipboard = NSMenuItem(
            title: "Clipboard History",
            action: #selector(showClipboardHistoryFromMenu),
            keyEquivalent: ""
        )
        clipboard.target = self
        menu.addItem(clipboard)
        clipboardHistoryItem = clipboard
        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ""
        )
        settings.target = self
        menu.addItem(settings)

        let scope = NSMenuItem(
            title: "Choose Search Scope…",
            action: #selector(chooseRoot),
            keyEquivalent: "l"
        )
        scope.target = self
        menu.addItem(scope)
        let rebuild = NSMenuItem(
            title: "Rebuild Index",
            action: #selector(rebuildIndex),
            keyEquivalent: "r"
        )
        rebuild.keyEquivalentModifierMask = [.command, .shift]
        rebuild.target = self
        menu.addItem(rebuild)

        let launch = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        menu.addItem(launch)
        launchAtLoginItem = launch

        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Floodlight",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        launchAtLoginItem?.state = LaunchAtLogin.launchesAtLogin ? .on : .off
        let clipboardShortcut = globalHotKeyRegistration.activeShortcut(for: .showClipboard)
        clipboardHistoryItem?.keyEquivalent = clipboardShortcut?.keyEquivalent ?? ""
        clipboardHistoryItem?.keyEquivalentModifierMask = clipboardShortcut?
            .keyEquivalentModifierMask ?? []
    }

    /// This menu is never drawn — Floodlight is an agent app. It exists so the
    /// key equivalents below work while the panel is key. Anything a user has
    /// to click belongs in `makeStatusMenu()` instead.
    private func installMenu() {
        NSApp.mainMenu = makeMainMenu()
    }

    func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Floodlight")

        let show = NSMenuItem(
            title: "Show Floodlight",
            action: #selector(showPanel),
            keyEquivalent: " "
        )
        show.keyEquivalentModifierMask = [.command]
        show.target = self
        appMenu.addItem(show)
        appMenu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsFromSearch),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(settings)

        let scope = NSMenuItem(
            title: "Choose Search Scope…",
            action: #selector(chooseRoot),
            keyEquivalent: "l"
        )
        scope.target = self
        appMenu.addItem(scope)

        let rebuild = NSMenuItem(
            title: "Rebuild Index",
            action: #selector(rebuildIndex),
            keyEquivalent: "r"
        )
        rebuild.keyEquivalentModifierMask = [.command, .shift]
        rebuild.target = self
        appMenu.addItem(rebuild)

        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Floodlight",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Undo",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        let redo = editMenu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        return mainMenu
    }
}

extension AppDelegate: ApplicationPresentationEffects {
    var isClipboardHistoryShowing: Bool {
        model.isClipboardMode
    }

    func showSearch() {
        panelController.show()
    }

    func hideSearch() {
        panelController.hide()
    }

    func toggleSearch() {
        panelController.toggle()
    }

    /// The intent goes after `show()` so nothing presentation does can
    /// undo it.
    func showClipboardHistory() {
        if !panelController.isVisible {
            panelController.show()
        }
        model.showClipboardHistory()
    }

    func makeConfiguration(
        origin: ConfigurationOrigin,
        onFinished: @escaping @MainActor () -> Void,
        onDismissed: @escaping @MainActor () -> Void
    ) -> any ConfigurationPresenting {
        FloodlightConfigurationWindowController(
            presentation: origin == .initialSetup ? .onboarding : .settings,
            activeShortcut: globalHotKeyRegistration.activeShortcut(for: .summonSearch),
            activeClipboardShortcut: globalHotKeyRegistration.activeShortcut(for: .showClipboard),
            launchesAtLogin: LaunchAtLogin.launchesAtLogin,
            rootURL: model.rootURL,
            blocklistStore: model.blocklistStore,
            clipboardExclusionStore: clipboardCapture.exclusions,
            clipboardStore: clipboardStore,
            selectShortcut: { [weak self] action, shortcut in
                self?.selectShortcut(action, shortcut) ?? .noShortcutActive
            },
            setLaunchAtLogin: { enabled in
                do {
                    try LaunchAtLogin.setLaunchAtLogin(enabled)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            },
            chooseScope: { [weak self] in
                guard let self else { return nil }
                return RootPicker.chooseAndApply(to: model)
            },
            onFinished: onFinished,
            onDismissed: onDismissed
        )
    }
}
