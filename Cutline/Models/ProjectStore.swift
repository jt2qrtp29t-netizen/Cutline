import Foundation
import Observation

/// Owns the project state and routes every mutation through the undo manager.
///
/// Undo works by snapshotting: each edit registers the previous `ProjectState`
/// value, and undoing swaps it back in while registering the redo the same way.
/// Because the state is a tree of value types this is cheap and always correct.
///
/// Continuous interactions (dragging a clip, scrubbing a slider) use
/// `beginLiveEdit` / `liveEdit` / `commitLiveEdit` so the whole gesture becomes
/// one undo step.
@Observable
final class ProjectStore {
    private(set) var state: ProjectState
    /// True while a gesture is mutating the state without registering undo.
    private(set) var isLiveEditing = false

    @ObservationIgnored weak var undoManager: UndoManager?
    /// The last coalescible edit, so a run of them (typing, dragging a color well)
    /// becomes a single undo step.
    @ObservationIgnored private var lastCoalesced: (key: String, time: Date)?
    private static let coalescingWindow: TimeInterval = 1.0
    /// The state at the start of the current gesture.
    @ObservationIgnored private(set) var liveBase: ProjectState?

    init(state: ProjectState = ProjectState()) {
        self.state = state
    }

    /// Applies an undoable edit. No-op edits register nothing.
    ///
    /// Edits with the same `coalescingKey` made within a second of each other share
    /// one undo step: undo returns to the state before the first of them.
    func edit(_ actionName: String, coalescingKey: String? = nil, _ body: (inout ProjectState) -> Void) {
        if isLiveEditing { cancelLiveEdit() }
        var next = state
        body(&next)
        guard next != state else { return }
        let previous = state
        state = next

        let now = Date()
        if let coalescingKey, let last = lastCoalesced, last.key == coalescingKey,
           now.timeIntervalSince(last.time) < Self.coalescingWindow, undoManager != nil {
            lastCoalesced = (coalescingKey, now)
            return
        }
        lastCoalesced = coalescingKey.map { ($0, now) }
        registerUndo(restoring: previous, actionName: actionName)
    }

    func beginLiveEdit() {
        if isLiveEditing { return }
        liveBase = state
        isLiveEditing = true
    }

    /// Recomputes the live state from the gesture's starting snapshot, so each
    /// update is absolute rather than cumulative.
    func liveEdit(_ body: (inout ProjectState) -> Void) {
        guard isLiveEditing, let base = liveBase else { return }
        var next = base
        body(&next)
        if next != state { state = next }
    }

    func commitLiveEdit(_ actionName: String) {
        guard isLiveEditing, let base = liveBase else { return }
        isLiveEditing = false
        liveBase = nil
        if base != state {
            lastCoalesced = nil
            registerUndo(restoring: base, actionName: actionName)
        }
    }

    func cancelLiveEdit() {
        guard isLiveEditing, let base = liveBase else { return }
        state = base
        isLiveEditing = false
        liveBase = nil
    }

    /// Replaces the state without touching undo (used when a document is read from disk).
    func load(_ newState: ProjectState) {
        guard newState != state else { return }
        state = newState
        undoManager?.removeAllActions(withTarget: self)
    }

    private func registerUndo(restoring previous: ProjectState, actionName: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.cancelLiveEdit()
                store.lastCoalesced = nil
                let current = store.state
                store.state = previous
                store.registerUndo(restoring: current, actionName: actionName)
            }
        }
        undoManager.setActionName(actionName)
    }
}
