import AppKit
import FloodlightEngine
import Observation
import SwiftUI

final class FloodlightPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyEquivalentHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class FloodlightPanelController {
    let panel: FloodlightPanel
    private let model: SearchCoordinator
    private let quickLook = QuickLookController()

    private var localKeyMonitor: Any?
    private var resignActiveObservation: NSObjectProtocol?
    private var accessibilityDisplayObservation: NSObjectProtocol?
    private var appliedGlassSlabState: Bool?

    init(model: SearchCoordinator) {
        self.model = model
        panel = FloodlightPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloodlightMetrics.panelWidth,
                height: FloodlightMetrics.searchHeight
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .none
        panel.keyEquivalentHandler = { [weak self] event in
            self?.handleCommandKeyEquivalent(event) ?? false
        }
        panel.setContentSize(
            NSSize(
                width: FloodlightMetrics.panelWidth,
                height: FloodlightMetrics.searchHeight
            )
        )
        applyGlassSlabState()

        observeQueryForPanelHeight()

        localKeyMonitor = NSEvent
            .addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyEvent(event) ?? event
            }
        resignActiveObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            // queue: .main is untyped; AppKit delivers this on the main thread.
            MainActor.assumeIsolated {
                guard self?.panel.isVisible == true else { return }
                self?.hide()
            }
        }
        // Reduce Transparency (and other accessibility display settings) can
        // change while Floodlight keeps running — re-derive the slab instead
        // of only deciding once at launch, so toggling it in System Settings
        // takes effect without a relaunch.
        accessibilityDisplayObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main is untyped; AppKit delivers this on the main thread.
            MainActor.assumeIsolated {
                self?.applyGlassSlabState()
            }
        }
    }

    isolated deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let resignActiveObservation {
            NotificationCenter.default.removeObserver(resignActiveObservation)
        }
        if let accessibilityDisplayObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityDisplayObservation)
        }
    }

    /// Rebuilds the content controller for the current glass-slab decision.
    /// Safe to call repeatedly — `makeContentController` always builds a
    /// fresh `SearchView(model:)` over the same `model` instance, so
    /// `SearchCoordinator`'s state (query, results, selection) survives the
    /// swap untouched; only the surrounding material changes.
    private func applyGlassSlabState() {
        let usesGlassSlab = Self.shouldUseGlassSlab()
        guard usesGlassSlab != appliedGlassSlabState else { return }
        appliedGlassSlabState = usesGlassSlab
        panel.contentViewController = Self.makeContentController(
            model: model,
            usesGlassSlab: usesGlassSlab
        )
        // The glass slab (`NSGlassEffectView`) rounds its own corners; every
        // other path — macOS 14/15, or macOS 26 with Reduce Transparency —
        // needs the layer-based corner mask instead, or the panel renders
        // as a plain square. `contentViewController` always hands back a
        // fresh `contentView`, so there's nothing stale to unset here.
        if !usesGlassSlab {
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = FloodlightMetrics.cornerRadius
            panel.contentView?.layer?.cornerCurve = .continuous
            panel.contentView?.layer?.masksToBounds = true
        }
    }

    /// Whether the panel gets the real `NSGlassEffectView` slab — macOS 26
    /// and Reduce Transparency off. Computed once per panel and reused for
    /// both the content-controller choice and the corner-mask fallback, so
    /// the two decisions can never disagree about which path is active.
    private static func shouldUseGlassSlab() -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return GlassAvailability.rendersGlass(
            isSupported: true,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
    }

    private static func makeContentController(
        model: SearchCoordinator,
        usesGlassSlab: Bool
    ) -> NSViewController {
        let hostingController = NSHostingController(
            rootView: SearchView(model: model, usesGlassSlab: usesGlassSlab)
        )
        guard #available(macOS 26.0, *), usesGlassSlab else {
            return hostingController
        }

        let glassView = NSGlassEffectView()
        glassView.style = .clear
        glassView.cornerRadius = FloodlightMetrics.cornerRadius
        glassView.contentView = hostingController.view

        let glassController = NSViewController()
        glassController.view = glassView
        glassController.addChild(hostingController)
        return glassController
    }

    func toggle() {
        if Self.shouldHideOnToggle(
            panelIsVisible: panel.isVisible,
            panelIsKeyWindow: panel.isKeyWindow,
            applicationIsActive: NSApp.isActive
        ) {
            hide()
        } else {
            show()
        }
    }

    static func shouldHideOnToggle(
        panelIsVisible: Bool,
        panelIsKeyWindow: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        panelIsVisible && panelIsKeyWindow && applicationIsActive
    }

    func show() {
        let signpost = FloodlightPerformance.begin("ShowPanel")
        defer { FloodlightPerformance.end("ShowPanel", id: signpost) }
        positionOnActiveScreen()
        model.prepareForPresentation()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeKey()
    }

    func hide() {
        let signpost = FloodlightPerformance.begin("HidePanel")
        defer { FloodlightPerformance.end("HidePanel", id: signpost) }
        quickLook.close()
        panel.orderOut(nil)
        model.reset()
    }

    private func positionOnActiveScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let frame = panel.frame
        let origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.minY + visibleFrame.height * 0.68 - frame.height / 2
        )
        panel.setFrameOrigin(origin)
    }

    private func togglePreview() {
        guard let url = model.previewableSelectionURL else { return }
        quickLook.toggle(url)
    }

    /// Re-registers after every fire — `withObservationTracking`'s `onChange`
    /// only fires once per registration — and resizes to the height for the
    /// query's current empty/non-empty state. `resize(to:)` already no-ops
    /// within half a point, so a burst of query changes settles at the
    /// correct height without a visible double-resize.
    private func observeQueryForPanelHeight() {
        withObservationTracking {
            _ = model.query
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.resize(to: FloodlightMetrics.panelHeight(hasQuery: !self.model.query.isEmpty))
                self.observeQueryForPanelHeight()
            }
        }
    }

    /// Grows or shrinks the visible panel without slowing result publication.
    /// Hidden panels and Reduce Motion use the final frame immediately.
    private func resize(to height: CGFloat) {
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: FloodlightMetrics.panelWidth, height: height)
        frame.origin.y = top - height

        guard panel.isVisible,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else {
            panel.setFrame(frame, display: false, animate: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard panel.isVisible, event.window === panel || panel.isKeyWindow else {
            return event
        }

        switch event.keyCode {
        case 125:
            model.moveSelection(by: 1)
            return nil
        case 126:
            model.moveSelection(by: -1)
            return nil
        default:
            break
        }

        return event
    }

    private func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool {
        guard panel.isVisible, event.window === panel || panel.isKeyWindow else {
            return false
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command) else { return false }

        let characters = event.charactersIgnoringModifiers?.lowercased()
        let fieldEditor = panel.firstResponder as? NSTextView
        if Self.performSearchTextEditingCommand(characters, in: fieldEditor) {
            return true
        }

        if Self.commandDigit(for: characters) != nil {
            if let index = Self.filterShortcutIndex(for: characters) {
                let options = model.filterOptions
                if options.indices.contains(index) {
                    model.selectFilter(options[index].filter)
                }
            }
            // Consume every command-digit combination, including currently
            // unused slots, so it never reaches the field editor and beeps.
            return true
        }

        switch Self.panelCommand(
            for: characters,
            shiftHeld: modifiers.contains(.shift)
        ) {
        case .copySelection:
            model.copySelection()
        case .chooseRoot:
            RootPicker.chooseAndApply(to: model)
        case .rebuildIndex:
            model.rebuildIndex()
        case .revealSelection:
            model.revealSelection()
        case .togglePreview:
            togglePreview()
        case .unmatched:
            return false
        }
        return true
    }

    enum PanelCommand: Hashable, Sendable {
        case copySelection
        case chooseRoot
        case rebuildIndex
        case revealSelection
        case togglePreview
        case unmatched
    }

    static func panelCommand(for characters: String?, shiftHeld: Bool) -> PanelCommand {
        switch characters {
        case "c":
            .copySelection
        case "l":
            .chooseRoot
        case "r":
            shiftHeld ? .rebuildIndex : .revealSelection
        case "y":
            .togglePreview
        case "\r", "\n":
            .revealSelection
        default:
            .unmatched
        }
    }

    static func performSearchTextEditingCommand(
        _ characters: String?,
        in fieldEditor: NSTextView?,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let fieldEditor, fieldEditor.isFieldEditor else { return false }

        switch characters {
        case "a":
            fieldEditor.selectAll(nil)
        case "c" where fieldEditor.selectedRange().length > 0:
            writeSelectedText(from: fieldEditor, to: pasteboard)
        case "v":
            if let value = pasteboard.string(forType: .string) {
                fieldEditor.insertText(
                    value,
                    replacementRange: fieldEditor.selectedRange()
                )
            }
        case "x":
            let selection = fieldEditor.selectedRange()
            if selection.length > 0 {
                writeSelectedText(from: fieldEditor, to: pasteboard)
                fieldEditor.insertText("", replacementRange: selection)
            }
        default:
            return false
        }
        return true
    }

    private static func writeSelectedText(
        from fieldEditor: NSTextView,
        to pasteboard: NSPasteboard
    ) {
        let selection = fieldEditor.selectedRange()
        guard selection.length > 0 else { return }
        let value = (fieldEditor.string as NSString).substring(with: selection)
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }

    static func commandDigit(for characters: String?) -> Int? {
        guard
            let characters,
            characters.count == 1,
            let digit = characters.first?.wholeNumberValue
        else {
            return nil
        }
        return digit
    }

    static func filterShortcutIndex(for characters: String?) -> Int? {
        guard let digit = commandDigit(for: characters), (1...5).contains(digit) else {
            return nil
        }
        return digit - 1
    }
}
