import AppKit
import SwiftUI

struct FloodlightTextField: NSViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let focusGeneration: Int
    let onSubmit: () -> Void
    let onCommandSubmit: () -> Void
    let onCancel: () -> Void
    var onTab: () -> Void = {}
    var onShiftTab: () -> Void = {}
    var onBackspaceOnEmpty: () -> Void = {}

    /// What a command selector means inside the search field. Pure and
    /// static — the delegate consumes a selector exactly when this maps it,
    /// so Tab can never fall through to the field editor's focus traversal,
    /// and backspace stays ordinary editing while there's text to delete.
    enum FieldCommand: Hashable {
        case submit
        case commandSubmit
        case cancel
        case tab
        case shiftTab
        case backspaceOnEmptyText
    }

    static func fieldCommand(
        for commandSelector: Selector,
        commandKeyIsDown: Bool,
        textIsEmpty: Bool
    ) -> FieldCommand? {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            commandKeyIsDown ? .commandSubmit : .submit
        case #selector(NSResponder.cancelOperation(_:)):
            .cancel
        case #selector(NSResponder.insertTab(_:)):
            .tab
        case #selector(NSResponder.insertBacktab(_:)):
            .shiftTab
        case #selector(NSResponder.deleteBackward(_:)) where textIsEmpty:
            .backspaceOnEmptyText
        default:
            nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.font = .systemFont(ofSize: FloodlightMetrics.Typography.inputSize, weight: .light)
        textField.textColor = .labelColor
        textField.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .font: textField.font as Any,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
        )
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        context.coordinator.lastFocusGeneration = focusGeneration
        context.coordinator.shouldCollapseSelectionAfterNextEdit = true
        requestFocus(for: textField)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self

        if textField.stringValue != text {
            textField.stringValue = text
        }

        if context.coordinator.lastFocusGeneration != focusGeneration {
            context.coordinator.lastFocusGeneration = focusGeneration
            context.coordinator.shouldCollapseSelectionAfterNextEdit = true
            requestFocus(for: textField)
        }
    }

    private func requestFocus(for textField: NSTextField) {
        // Next run-loop turn: makeFirstResponder is unsafe during SwiftUI update.
        DispatchQueue.main.async { [weak textField] in
            guard let textField, let window = textField.window else { return }
            if
                let editor = window.fieldEditor(false, for: textField) as? NSTextView,
                window.firstResponder === editor
            {
                editor.insertionPointColor = .controlAccentColor
                Self.placeInsertionPointAtEnd(in: editor)
                return
            }
            window.makeFirstResponder(textField)
            Self.applyAccentInsertionPoint(in: window, for: textField)
        }
    }

    private static func applyAccentInsertionPoint(in window: NSWindow, for textField: NSTextField) {
        guard let editor = window.fieldEditor(false, for: textField) as? NSTextView else {
            return
        }
        editor.insertionPointColor = .controlAccentColor
        placeInsertionPointAtEnd(in: editor)
    }

    private static func placeInsertionPointAtEnd(in editor: NSTextView) {
        editor.setSelectedRange(
            NSRange(location: editor.string.utf16.count, length: 0)
        )
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FloodlightTextField
        var lastFocusGeneration: Int?
        var shouldCollapseSelectionAfterNextEdit = false

        init(parent: FloodlightTextField) {
            self.parent = parent
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            guard
                let textField = notification.object as? NSTextField,
                let window = textField.window
            else {
                return
            }
            FloodlightTextField.applyAccentInsertionPoint(in: window, for: textField)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue

            guard shouldCollapseSelectionAfterNextEdit else { return }
            shouldCollapseSelectionAfterNextEdit = false
            // Next run-loop turn: mutating the field editor during didChange re-enters AppKit.
            DispatchQueue.main.async { [weak textField] in
                guard
                    let textField,
                    let window = textField.window,
                    let editor = window.fieldEditor(false, for: textField) as? NSTextView,
                    window.firstResponder === editor
                else {
                    return
                }
                FloodlightTextField.placeInsertionPointAtEnd(in: editor)
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            guard
                let command = FloodlightTextField.fieldCommand(
                    for: commandSelector,
                    commandKeyIsDown: NSApp.currentEvent?.modifierFlags.contains(.command) == true,
                    textIsEmpty: textView.string.isEmpty
                )
            else {
                return false
            }

            // Next run-loop turn: panel/SwiftUI actions must not nest in doCommandBy.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch command {
                case .submit:
                    parent.onSubmit()
                case .commandSubmit:
                    parent.onCommandSubmit()
                case .cancel:
                    parent.onCancel()
                case .tab:
                    parent.onTab()
                case .shiftTab:
                    parent.onShiftTab()
                case .backspaceOnEmptyText:
                    parent.onBackspaceOnEmpty()
                }
            }
            return true
        }
    }
}
