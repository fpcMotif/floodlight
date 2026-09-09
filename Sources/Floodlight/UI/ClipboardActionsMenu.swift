import AppKit
import SwiftUI

/// The Selected-Result intents the board's footer and Actions menu dispatch
/// to the Search Session (ADR 0005) — everything else they show comes from
/// Clipboard Search, so neither needs the coordinator itself.
struct ClipboardBoardCommands {
    let paste: @MainActor () -> Void
    let copy: @MainActor () -> Void
    let reveal: @MainActor () -> Void

    @MainActor
    init(session: SearchCoordinator) {
        paste = { session.openSelection() }
        copy = { session.copySelection() }
        reveal = { session.revealSelection() }
    }
}

/// One entry of the board's Actions menu: what it says, the chord the
/// panel already honours for it, and what it does.
struct ClipboardMenuAction {
    let title: String
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags
    let isEnabled: Bool
    /// Starts a new separator-delimited group.
    let startsGroup: Bool
    let handler: @MainActor () -> Void

    /// The actions the panel can perform on the current selection today,
    /// with the shortcuts `FloodlightPanelController.panelCommand` maps —
    /// nothing here promises a chord the panel does not honour. Paste,
    /// Copy, and Show in Finder are the session's Selected-Result intents
    /// (ADR 0005); the facts that enable an item, and the pin and delete
    /// commands, are Clipboard Search's (ADR 0008).
    @MainActor
    static func available(
        commands: ClipboardBoardCommands,
        clipboardSearch: ClipboardSearch,
        boardContext: ClipboardBoardContext,
        pasteLabel: String
    ) -> [ClipboardMenuAction] {
        [
            ClipboardMenuAction(
                title: pasteLabel,
                keyEquivalent: "\r",
                modifiers: [],
                isEnabled: true,
                startsGroup: false,
                handler: commands.paste
            ),
            ClipboardMenuAction(
                title: "Copy",
                keyEquivalent: "c",
                modifiers: [.command],
                isEnabled: true,
                startsGroup: false,
                handler: commands.copy
            ),
            ClipboardMenuAction(
                title: "Quick Look",
                keyEquivalent: " ",
                modifiers: [],
                isEnabled: clipboardSearch.isSelectionPreviewable,
                startsGroup: true,
                handler: { boardContext.requestPreview() }
            ),
            ClipboardMenuAction(
                title: "Show in Finder",
                keyEquivalent: "r",
                modifiers: [.command],
                isEnabled: clipboardSearch.selectionFileURL != nil,
                startsGroup: false,
                handler: commands.reveal
            ),
            ClipboardMenuAction(
                title: clipboardSearch.isSelectionPinned ? "Unpin" : "Pin",
                keyEquivalent: ".",
                modifiers: [.command],
                isEnabled: true,
                startsGroup: true,
                handler: { clipboardSearch.togglePinSelection() }
            ),
            ClipboardMenuAction(
                title: "Delete",
                keyEquivalent: "d",
                modifiers: [.command],
                isEnabled: true,
                startsGroup: false,
                handler: { clipboardSearch.deleteSelection() }
            ),
        ]
    }
}

/// Pops the board's Actions menu from the footer chip it sits behind. A
/// click on the chip and ⌘K both route through
/// `ClipboardBoardContext.requestActions()`, so the two can never diverge.
struct ClipboardActionsMenuAnchor: NSViewRepresentable {
    let commands: ClipboardBoardCommands
    let clipboardSearch: ClipboardSearch
    let boardContext: ClipboardBoardContext
    let pasteLabel: String

    func makeCoordinator() -> Coordinator {
        Coordinator(
            commands: commands,
            clipboardSearch: clipboardSearch,
            boardContext: boardContext,
            pasteLabel: pasteLabel
        )
    }

    func makeNSView(context: Context) -> MenuAnchorView {
        let view = MenuAnchorView()
        context.coordinator.anchor = view
        let coordinator = context.coordinator
        boardContext.actionsHandler = { coordinator.popUpMenu() }
        return view
    }

    func updateNSView(_ view: MenuAnchorView, context: Context) {
        context.coordinator.pasteLabel = pasteLabel
    }

    @MainActor
    final class Coordinator: NSObject {
        private let commands: ClipboardBoardCommands
        private let clipboardSearch: ClipboardSearch
        private let boardContext: ClipboardBoardContext
        var pasteLabel: String
        weak var anchor: NSView?
        private var actions: [ClipboardMenuAction] = []

        init(
            commands: ClipboardBoardCommands,
            clipboardSearch: ClipboardSearch,
            boardContext: ClipboardBoardContext,
            pasteLabel: String
        ) {
            self.commands = commands
            self.clipboardSearch = clipboardSearch
            self.boardContext = boardContext
            self.pasteLabel = pasteLabel
        }

        /// The anchor only exists inside the board, so the menu can only
        /// pop while Clipboard mode is showing it.
        func popUpMenu() {
            guard let anchor else { return }
            actions = ClipboardMenuAction.available(
                commands: commands,
                clipboardSearch: clipboardSearch,
                boardContext: boardContext,
                pasteLabel: pasteLabel
            )
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (index, action) in actions.enumerated() {
                if action.startsGroup, !menu.items.isEmpty {
                    menu.addItem(.separator())
                }
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(runAction(_:)),
                    keyEquivalent: action.keyEquivalent
                )
                item.keyEquivalentModifierMask = action.modifiers
                item.target = self
                item.tag = index
                item.isEnabled = action.isEnabled
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: anchor)
        }

        @objc private func runAction(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag].handler()
        }
    }
}

/// Invisible and click-transparent: the SwiftUI chip above it keeps the
/// hit-testing, this view only lends the menu a position.
final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
