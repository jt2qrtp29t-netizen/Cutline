import AppKit
import SwiftUI

/// Switches workspace tabs with horizontal scrolling, such as a mouse's thumb wheel
/// (e.g. MX Master): scrolling right moves to the tab on the right. Areas that
/// scroll horizontally themselves (the timeline) are marked with
/// `.horizontalScrollZone()` and keep their scrolling.
struct ScrollTabSwitcher: NSViewRepresentable {
    let editor: EditorController

    func makeNSView(context: Context) -> SwitcherView {
        let view = SwitcherView()
        view.onStep = { step in editor.switchWorkspace(by: step) }
        return view
    }

    func updateNSView(_ view: SwitcherView, context: Context) {
        view.onStep = { step in editor.switchWorkspace(by: step) }
    }

    final class SwitcherView: NSView {
        var onStep: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var lastEvent: TimeInterval = 0
        /// After switching, the rest of that flick is ignored so one flick moves one tab.
        private var cooldownUntil: TimeInterval = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { self.handle(event) }
                return consumed ? nil : event
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// Returns true if the event switched tabs (or belongs to a flick that did).
        private func handle(_ event: NSEvent) -> Bool {
            guard event.window === window, let window else { return false }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            // Mostly-horizontal scrolling only, and not the coasting after a trackpad swipe.
            guard abs(dx) > abs(dy) * 1.5, event.momentumPhase.isEmpty else { return false }
            guard !HorizontalScrollZone.contains(event.locationInWindow, in: window) else { return false }

            let now = event.timestamp
            if now < cooldownUntil {
                cooldownUntil = now + 0.25
                return true
            }
            if now - lastEvent > 0.3 { accumulated = 0 }
            lastEvent = now
            accumulated += dx
            // Wheel notches are line-sized; trackpads and smooth wheels send points.
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 30 : 1
            guard abs(accumulated) >= threshold else { return true }
            // Negative deltaX scrolls content toward the right, as in a browser.
            onStep?(accumulated < 0 ? 1 : -1)
            accumulated = 0
            cooldownUntil = now + 0.25
            return true
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Marks a view whose horizontal scrolling must not switch tabs.
struct HorizontalScrollZone: NSViewRepresentable {
    @MainActor private static var zones = NSHashTable<NSView>.weakObjects()

    static func contains(_ point: NSPoint, in window: NSWindow) -> Bool {
        zones.allObjects.contains { zone in
            zone.window === window && zone.convert(zone.bounds, to: nil).contains(point)
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = ZoneView()
        Self.zones.add(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class ZoneView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

extension View {
    func horizontalScrollZone() -> some View {
        background(HorizontalScrollZone())
    }
}
