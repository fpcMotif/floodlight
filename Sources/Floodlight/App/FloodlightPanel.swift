import AppKit
import FloodlightEngine
import Observation
import SwiftUI

final class FloodlightPanel: NSPanel {
    var keyEquivalentHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

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
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.keyEquivalentHandler = { [weak self] event in
            self?.handleCommandKeyEquivalent(event) ?? false
        }
        panel.contentViewController = Self.makeContentController(model: model)
        panel.setContentSize(
            NSSize(
                width: FloodlightMetrics.panelWidth,
                height: FloodlightMetrics.searchHeight
            )
        )
        if #unavailable(macOS 26.0) {
            panel.contentView?.wantsLayer = true
            panel.contentView?.layer?.cornerRadius = FloodlightMetrics.cornerRadius
            panel.contentView?.layer?.cornerCurve = .continuous
            panel.contentView?.layer?.masksToBounds = true
        }

        observeQueryForPanelHeight()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
        resignActiveObservation = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard self?.panel.isVisible == true else { return }
                self?.hide()
            }
        }
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let resignActiveObservation {
            NotificationCenter.default.removeObserver(resignActiveObservation)
        }
    }

    private static func makeContentController(model: SearchCoordinator) -> NSViewController {
        let hostingController = NSHostingController(rootView: SearchView(model: model))
        guard #available(macOS 26.0, *) else {
            return hostingController
        }

        let glassView = NSGlassEffectView()
        glassView.style = .regular
        glassView.cornerRadius = FloodlightMetrics.cornerRadius
        glassView.contentView = hostingController.view
        glassView.translatesAutoresizingMaskIntoConstraints = false

        let backdropView = NSVisualEffectView()
        backdropView.material = .hudWindow
        backdropView.blendingMode = .behindWindow
        backdropView.state = .active
        backdropView.maskImage = makeCapsuleMask()
        backdropView.addSubview(glassView)
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: backdropView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: backdropView.trailingAnchor),
            glassView.topAnchor.constraint(equalTo: backdropView.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: backdropView.bottomAnchor),
        ])

        let glassController = NSViewController()
        glassController.view = backdropView
        glassController.addChild(hostingController)
        return glassController
    }

    @available(macOS 26.0, *)
    private static func makeCapsuleMask() -> NSImage {
        let diameter = FloodlightMetrics.cornerRadius * 2
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(
                roundedRect: rect,
                xRadius: FloodlightMetrics.cornerRadius,
                yRadius: FloodlightMetrics.cornerRadius
            ).fill()
            return true
        }
        let capInset = FloodlightMetrics.cornerRadius - 1
        image.capInsets = NSEdgeInsets(
            top: capInset,
            left: capInset,
            bottom: capInset,
            right: capInset
        )
        image.resizingMode = .stretch
        return image
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
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.prepareForPresentation()
        DispatchQueue.main.async {
            FloodlightPerformance.end("ShowPanel", id: signpost)
        }
    }

    func hide() {
        let signpost = FloodlightPerformance.begin("HidePanel")
        panel.orderOut(nil)
        model.reset()
        quickLook.close()
        FloodlightPerformance.end("HidePanel", id: signpost)
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

    /// Grows or shrinks the panel instead of snapping between heights. Under
    /// Reduce Motion the resize itself is instant — no sliding or growing —
    /// because that spatial movement is exactly what Reduce Motion asks to
    /// remove; `SearchView`'s content crossfade is the substitute motion,
    /// not a faster version of this one.
    private func resize(to height: CGFloat) {
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: FloodlightMetrics.panelWidth, height: height)
        frame.origin.y = top - height

        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.setFrame(frame, display: false, animate: false)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
            return .copySelection
        case "l":
            return .chooseRoot
        case "r":
            return shiftHeld ? .rebuildIndex : .revealSelection
        case "y":
            return .togglePreview
        default:
            return .unmatched
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
