import AppKit
import SwiftUI

/// Holding B shows the ungraded frame (the "before" view); letting go shows the
/// grade again. Ignored while typing in a text field or with modifier keys held.
struct BeforeKeyMonitor: NSViewRepresentable {
    let editor: EditorController

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.editor = editor
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.editor = editor
    }

    final class MonitorView: NSView {
        weak var editor: EditorController?
        private var monitor: Any?
        private var resignObserver: (any NSObjectProtocol)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self else { return event }
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { self.handle(event) }
                return consumed ? nil : event
            }
            // Letting go outside the window (or switching apps) mustn't leave it stuck on Before.
            resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                    object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.editor?.isHoldingBefore = false
                    self?.editor?.playground?.editor.isHoldingBefore = false
                }
            }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let editor, event.window === window,
                  event.charactersIgnoringModifiers?.lowercased() == "b",
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else { return false }
            // Typing a "b" in a text field stays typing.
            if window?.firstResponder is NSText { return false }
            switch event.type {
            case .keyDown: if !event.isARepeat { editor.activeEditor.isHoldingBefore = true }
            case .keyUp: editor.activeEditor.isHoldingBefore = false
            default: return false
            }
            return true
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }
    }
}
