import AppKit
import Observation

/// A project's Playground: a complete second editor (its own project, timeline,
/// undo history, selection and player) plus variants, snapshots and Labs settings.
/// It shares no state with the project's editor and is saved to its own file.
@Observable
final class PlaygroundSession {
    let key: String
    @ObservationIgnored let folder: URL
    /// The sandbox editor. All Playground views use it, just as Edit uses the main one.
    let editor: EditorController
    /// The Playground's own undo history (the project's is never touched).
    @ObservationIgnored let undoManager = UndoManager()

    var origins: [UUID: UUID]
    var variants: [VariantGroup]
    var snapshots: [PlaygroundSnapshot]
    var disabledExperiments: Set<String>
    /// Set when a saved Playground couldn't be read and was set aside.
    var loadProblem: String?
    /// Set when saving fails (the Playground keeps working in memory).
    var saveProblem: String?

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(key: String, projectSettings: ProjectSettings, folder: URL = PlaygroundFile.folder) {
        self.key = key
        self.folder = folder
        var state = PlaygroundState.empty(like: projectSettings)
        switch PlaygroundFile.load(key: key, in: folder) {
        case .loaded(let saved): state = saved
        case .none: break
        case .damaged(let backup):
            loadProblem = "The saved Playground couldn’t be read, so a new one was started. The old file was kept as “\(backup.lastPathComponent)”."
        }
        origins = state.origins
        variants = state.variants
        snapshots = state.snapshots
        disabledExperiments = state.disabledExperiments
        editor = EditorController(store: ProjectStore(state: state.project))
        editor.isSandbox = true
        editor.workspace = .playground
        editor.store.undoManager = undoManager
        undoManager.groupsByEvent = true
        updateRenderFilter()
    }

    /// Everything to save.
    var state: PlaygroundState {
        var state = PlaygroundState(project: editor.state)
        state.origins = origins
        state.variants = variants
        state.snapshots = snapshots
        state.disabledExperiments = disabledExperiments
        return state
    }

    /// Saves shortly after the last change.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        do {
            try PlaygroundFile.save(state, key: key, in: folder)
            saveProblem = nil
        } catch {
            saveProblem = "The Playground couldn’t be saved: \(error.localizedDescription)"
        }
    }

    /// Stops playback and other background work when leaving the Playground tab.
    func deactivate() {
        editor.playback.pause()
        editor.playback.providesFrames = false
        editor.isHoldingBefore = false
        saveNow()
    }

    /// Wipes the Playground: timeline, variants, snapshots and Labs settings. The
    /// project isn't touched.
    func reset() {
        editor.playback.pause()
        let empty = PlaygroundState.empty(like: editor.state.settings)
        editor.selection = []
        editor.selectedKeyframes = []
        editor.selectedTransition = nil
        editor.store.load(empty.project)
        undoManager.removeAllActions()
        origins = [:]
        variants = []
        snapshots = []
        disabledExperiments = []
        updateRenderFilter()
        saveNow()
    }
}
