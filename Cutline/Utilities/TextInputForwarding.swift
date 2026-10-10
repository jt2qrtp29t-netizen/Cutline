import AppKit

/// Menu items with single-key shortcuts (Space, arrows, Delete) take the key
/// before a focused text field sees it. These helpers detect that case and hand
/// the keystroke back to the field editor so typing keeps working.
enum TextInputForwarding {
    static var activeTextView: NSTextView? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable else { return nil }
        return textView
    }

    /// Returns true if the key was consumed by a text field.
    static func forwardSpace() -> Bool {
        guard let textView = activeTextView else { return false }
        textView.insertText(" ", replacementRange: textView.selectedRange())
        return true
    }

    /// Returns true if the command was consumed by a text field.
    static func forward(_ selector: Selector) -> Bool {
        guard let textView = activeTextView else { return false }
        textView.doCommand(by: selector)
        return true
    }
}
