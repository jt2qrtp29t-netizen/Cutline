import AppKit
import SwiftUI

/// A plain code editor for Python: monospaced, no smart quotes or other automatic
/// substitutions (they'd break code), Tab inserts four spaces, simple syntax colors.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = Coordinator.font
        view.textColor = NSColor(Theme.textPrimary)
        view.backgroundColor = NSColor(Theme.recessed)
        view.insertionPointColor = NSColor(Theme.accent)
        view.textContainerInset = NSSize(width: 6, height: 8)
        scroll.drawsBackground = false
        view.string = text
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        context.coordinator.highlight(view)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            highlight(view)
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertTab(_:)) {
                view.insertText("    ", replacementRange: view.selectedRange())
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // Keep the line's indent (one more after a colon).
                let string = view.string as NSString
                let line = string.lineRange(for: NSRange(location: view.selectedRange().location, length: 0))
                let current = string.substring(with: line)
                var indent = String(current.prefix { $0 == " " })
                if current.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":") { indent += "    " }
                view.insertText("\n" + indent, replacementRange: view.selectedRange())
                return true
            }
            return false
        }

        private static let rules: [(NSRegularExpression, NSColor)] = [
            (#"\b(from|import|class|def|return|if|elif|else|for|while|in|and|or|not|with|as|lambda|None|True|False|self|pass|try|except|raise)\b"#, NSColor(Theme.codeKeyword)),
            (#"\b\d+(\.\d+)?\b"#, NSColor(Theme.codeNumber)),
            (#"("[^"\n]*"|'[^'\n]*')"#, NSColor(Theme.codeString)),
            (#"#[^\n]*"#, NSColor(Theme.codeComment)),
        ].compactMap { pattern, color in (try? NSRegularExpression(pattern: pattern)).map { ($0, color) } }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: Self.font, .foregroundColor: NSColor(Theme.textPrimary)], range: all)
            for (regex, color) in Self.rules {
                for match in regex.matches(in: storage.string, range: all) {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
            storage.endEditing()
        }
    }
}
