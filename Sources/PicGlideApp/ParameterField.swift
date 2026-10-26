import AppKit
import SwiftUI

struct ParameterField: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let label: String
    let id: String
    let model: ViewerModel

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.alignment = .right; field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.setAccessibilityLabel(label)
        field.identifier = NSUserInterfaceItemIdentifier("parameter." + id)
        field.stringValue = String(Int(value.rounded()))
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = !model.isBusy
        if field.currentEditor() == nil { field.stringValue = String(Int(value.rounded())) }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ParameterField
        init(_ parent: ParameterField) { self.parent = parent }
        private func commit(_ field: NSTextField) {
            if let value = Double(field.stringValue), value.isFinite,
               value.rounded() == value, parent.range.contains(value) {
                parent.value = value
            } else { NSSound.beep() }
            field.stringValue = String(Int(parent.value.rounded()))
        }
        func controlTextDidBeginEditing(_ notification: Notification) { parent.model.revealControls() }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTextField { commit(field) }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField else { return false }
            switch selector {
            case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
                let current = Double(field.stringValue).flatMap { $0.isFinite ? $0 : nil } ?? parent.value
                parent.value = min(parent.range.upperBound, max(parent.range.lowerBound,
                    current.rounded() + (selector == #selector(NSResponder.moveUp(_:)) ? 1 : -1)))
                field.stringValue = String(Int(parent.value)); field.selectText(nil)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                commit(field); field.window?.makeFirstResponder(parent.model.canvas); return true
            case #selector(NSResponder.cancelOperation(_:)):
                field.stringValue = String(Int(parent.value.rounded()))
                field.window?.makeFirstResponder(parent.model.canvas); return true
            default: return false
            }
        }
    }
}
