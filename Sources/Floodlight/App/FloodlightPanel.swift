import AppKit
import Combine
import SwiftUI

final class FloodlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloodlightPanelController {
    let panel: FloodlightPanel
    private let model: SearchCoordinator
    private var localKeyMonitor: Any?
    private var sizeObservation: AnyCancellable?

    init(model: SearchCoordinator) {
        self.model = model
        panel = FloodlightPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 72),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        panel.contentViewController = NSHostingController(rootView: SearchView(model: model))
        panel.setContentSize(NSSize(width: 680, height: 72))

        sizeObservation = Publishers.CombineLatest(model.$query, model.$results)
            .map { [weak model] _, _ in model?.panelHeight ?? 72 }
            .removeDuplicates()
            .sink { [weak self] height in
                self?.resize(to: height)
            }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
    }

    deinit {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        positionOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        model.prepareForPresentation()
    }

    func hide() {
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

    private func resize(to height: CGFloat) {
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: 680, height: height)
        frame.origin.y = top - height
        panel.animator().setFrame(frame, display: true)
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return event }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 125:
            model.moveSelection(by: 1)
            return nil
        case 126:
            model.moveSelection(by: -1)
            return nil
        case 36, 76:
            if modifiers.contains(.command) {
                model.revealSelection()
            } else {
                model.openSelection()
            }
            return nil
        case 53:
            hide()
            return nil
        default:
            break
        }

        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                model.copySelection()
                return nil
            case "l":
                model.chooseRoot()
                return nil
            case "r":
                model.rebuildIndex()
                return nil
            case "y":
                model.togglePreview()
                return nil
            default:
                break
            }
        }

        return event
    }
}
