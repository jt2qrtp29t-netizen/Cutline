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
        private var gesture = TabScrollGesture()

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

        /// Returns true if the event was used for switching tabs (and so isn’t passed on).
        private func handle(_ event: NSEvent) -> Bool {
            // The window the event is for: its own, or (for events without one) the
            // window under the pointer. Scroll events go there, whichever window is key.
            let screenPoint: NSPoint
            if let cg = event.cgEvent?.location, let primary = NSScreen.screens.first {
                screenPoint = NSPoint(x: cg.x, y: primary.frame.maxY - cg.y)
            } else {
                screenPoint = NSEvent.mouseLocation
            }
            let target = event.window
                ?? NSApp.window(withWindowNumber: NSWindow.windowNumber(at: screenPoint, belowWindowWithWindowNumber: 0))
            guard AppSettings.shared.scrollSwitchesTabs, let window, target === window else { return false }
            let location = event.window != nil ? event.locationInWindow : window.convertPoint(fromScreen: screenPoint)
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            // Mostly-horizontal scrolling only, and not the coasting after a trackpad swipe.
            guard abs(dx) > abs(dy) * 1.5, event.momentumPhase.isEmpty else { return false }
            guard !HorizontalScrollZone.contains(location, in: window) else { return false }

            let step = gesture.feed(dx: dx, precise: event.hasPreciseScrollingDeltas, at: event.timestamp)
            if step != 0 { onStep?(TabScrollGesture.direction(step, reversed: AppSettings.shared.reverseTabScrolling)) }
            return true
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

/// Turns horizontal scroll events into tab steps: one step per flick of the wheel.
///
/// Smooth-scrolling mice (e.g. with Logi Options+) keep sending small, fading deltas
/// for a while after each flick. Those are ignored, but a new flick is recognised
/// even while the last one is still coasting: by a pause, a change of direction,
/// or deltas suddenly growing again.
nonisolated struct TabScrollGesture {
    /// Points (smooth) or lines (notched wheels) needed to step.
    static let preciseThreshold: CGFloat = 30
    static let lineThreshold: CGFloat = 1
    /// After a step, the same flick can't step again for at least this long.
    static let minimumSuppression: TimeInterval = 0.3
    /// A pause this long starts a new flick.
    static let newFlickGap: TimeInterval = 0.12

    private var accumulated: CGFloat = 0
    private var lastTime: TimeInterval?
    private var lastMagnitude: CGFloat = 0
    /// Set after a step, while the rest of that flick is being ignored.
    private var suppression: (since: TimeInterval, sign: CGFloat)?

    /// The tab step for a scroll step, with the Parameters option to reverse it.
    static func direction(_ step: Int, reversed: Bool) -> Int { reversed ? -step : step }

    /// Feeds one event; returns +1 to move a tab right, -1 left, or 0.
    mutating func feed(dx: CGFloat, precise: Bool, at time: TimeInterval) -> Int {
        guard dx != 0 else { return 0 }
        let magnitude = abs(dx)
        let sign: CGFloat = dx < 0 ? -1 : 1
        let gap = lastTime.map { time - $0 } ?? .infinity
        lastTime = time
        defer { lastMagnitude = magnitude }

        if let suppressed = suppression {
            let paused = gap > Self.newFlickGap
            let reversed = sign != suppressed.sign
            let growing = time - suppressed.since >= Self.minimumSuppression
                && magnitude > max(lastMagnitude * 1.6, lastMagnitude + 2)
            guard paused || reversed || growing else { return 0 }
            suppression = nil
            accumulated = 0
        } else if gap > Self.newFlickGap * 2.5 || (accumulated != 0 && (accumulated < 0) != (dx < 0)) {
            accumulated = 0
        }

        accumulated += dx
        guard abs(accumulated) >= (precise ? Self.preciseThreshold : Self.lineThreshold) else { return 0 }
        // Negative deltaX scrolls content toward the right, as in a browser.
        let step = accumulated < 0 ? 1 : -1
        accumulated = 0
        suppression = (time, sign)
        return step
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
