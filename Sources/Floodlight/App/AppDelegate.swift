import AppKit
import Carbon

private func floodlightHotKeyHandler(
    _: EventHandlerCallRef?,
    _: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.togglePanel()
    }
    return noErr
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = SearchCoordinator()
    private var panelController: FloodlightPanelController?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panelController = FloodlightPanelController(model: model)
        model.onDismiss = { [weak self] in self?.panelController?.hide() }
        installMenu()
        installStatusItem()
        installGlobalHotKey()
        model.start()
        panelController?.show()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    @objc func togglePanel() {
        panelController?.toggle()
    }

    @objc private func showPanel() {
        panelController?.show()
    }

    @objc private func chooseRoot() {
        panelController?.show()
        model.chooseRoot()
    }

    @objc private func rebuildIndex() {
        model.rebuildIndex()
    }

    @objc private func toggleLaunchAtLogin() {
        model.toggleLaunchAtLogin()
    }

    private func installGlobalHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            floodlightHotKeyHandler,
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )

        let identifier = EventHotKeyID(signature: fourCharacterCode("FLIT"), id: 1)
        var status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(cmdKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            status = RegisterEventHotKey(
                UInt32(kVK_Space),
                UInt32(optionKey),
                identifier,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )
            model.setShortcutLabel(status == noErr ? "⌥Space" : "Menu bar")
        } else {
            model.setShortcutLabel("⌘Space")
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "flashlight.on.fill",
                accessibilityDescription: "Floodlight"
            )
            button.target = self
            button.action = #selector(togglePanel)
            button.toolTip = "Floodlight"
        }
        statusItem = item
    }

    private func installMenu() {
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
        rebuild.target = self
        appMenu.addItem(rebuild)

        let launch = NSMenuItem(
            title: "Toggle Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        appMenu.addItem(launch)
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Floodlight",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu
    }

    private func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
