import AppKit
import SwiftUI

struct FloodlightTextField: NSViewRepresentable {
    @Binding var text: String

    let placeholder: String
    let focusGeneration: Int
    let onSubmit: () -> Void
    let onCommandSubmit: () -> Void
    let onCancel: () -> Void

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
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.onCommandSubmit()
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.parent.onSubmit()
                    }
                }
                return true

            case #selector(NSResponder.cancelOperation(_:)):
                DispatchQueue.main.async { [weak self] in
                    self?.parent.onCancel()
                }
                return true

            default:
                return false
            }
        }
    }
}
