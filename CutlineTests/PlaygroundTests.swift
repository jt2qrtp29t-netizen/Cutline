import Foundation
import Testing
@testable import Cutline

@MainActor struct PlaygroundTests {
    /// A project editor whose Playground saves to a fresh temporary folder.
    static func makeProject() -> (EditorController, UndoManager, Clip) {
        var state = ProjectState()
        state.id = UUID()
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "Original", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        clip.color.gain.master = 0.2
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.playgroundFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        return (editor, undo, clip)
    }

    static func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func playgroundEditsNeverReachTheProject() {
        let (editor, undo, _) = Self.makeProject()
        let projectBefore = editor.state
        editor.workspace = .playground
        let playground = editor.playground!
        #expect(editor.activeEditor === playground.editor && editor.activeEditor !== editor)

        let pgUndo = playground.undoManager
        pgUndo.groupsByEvent = false
        Self.step(pgUndo) { playground.editor.addTrack(.video) }
        Self.step(pgUndo) {
            playground.editor.store.edit("Scratch") { state in
                state.tracks[0].clips = [Clip(id: UUID(), mediaID: UUID(), name: "Scratch", start: .zero,
                                              duration: Time(seconds: 2), sourceStart: .zero)]
            }
        }
        #expect(editor.state == projectBefore, "the project is untouched")
        #expect(!undo.canUndo, "and so is its undo history")
        #expect(pgUndo.canUndo)

        // Switching tabs keeps both.
        editor.workspace = .edit
        #expect(editor.activeEditor === editor)
        editor.workspace = .playground
        #expect(playground.editor.state.tracks[0].clips.first?.name == "Scratch")
        #expect(editor.playground === playground)
    }

    @Test func playgroundSavesSeparatelyAndLoadsBack() throws {
        let (editor, _, _) = Self.makeProject()
        let playground = editor.ensurePlayground()
        playground.editor.store.edit("Scratch") { state in
            var clip = Clip(id: UUID(), mediaID: UUID(), name: "Saved", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
            clip.color.lift.x = 0.4
            state.tracks[0].clips = [clip]
        }
        playground.snapshots = [PlaygroundSnapshot(name: "First", date: Date(), project: playground.editor.state, variants: [])]
        playground.disabledExperiments = ["noise"]
        playground.saveNow()
        let file = PlaygroundFile.url(for: playground.key, in: editor.playgroundFolder)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(playground.key == editor.state.id?.uuidString)

        // A new window on the same project finds it again.
        let reopened = PlaygroundSession(key: playground.key, projectSettings: editor.state.settings, folder: editor.playgroundFolder)
        #expect(reopened.state == playground.state)
        #expect(reopened.editor.state.tracks[0].clips[0].color.lift.x == 0.4)
        #expect(reopened.snapshots.first?.name == "First" && reopened.disabledExperiments == ["noise"])
    }

    @Test func aDamagedPlaygroundFileIsSetAsideNotFatal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: PlaygroundFile.url(for: "broken", in: folder))
        let session = PlaygroundSession(key: "broken", projectSettings: .default, folder: folder)
        #expect(session.loadProblem != nil)
        #expect(session.editor.state.allClips.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files.contains { $0.contains("damaged") }, "the bad file is kept for inspection")
    }

    @Test func olderProjectsWithoutAnIDOpenNormallyAndKeepTheirPlayground() throws {
        // A v3.1 project: no id, no Playground anywhere.
        var old = ProjectState()
        old.tracks[0].clips = [Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 1), sourceStart: .zero)]
        var json = try JSONSerialization.jsonObject(with: old.encoded()) as! [String: Any]
        json.removeValue(forKey: "id")
        let loaded = try ProjectState.decode(try JSONSerialization.data(withJSONObject: json))
        #expect(loaded.id == nil && loaded.allClips.count == 1)

        // Keyed by file location: the same file gets the same Playground each time.
        let url = URL(fileURLWithPath: "/Users/someone/Movies/Old.cutline")
        #expect(PlaygroundFile.key(projectID: nil, fileURL: url) == PlaygroundFile.key(projectID: nil, fileURL: url))
        #expect(PlaygroundFile.key(projectID: nil, fileURL: url) != PlaygroundFile.key(projectID: nil, fileURL: url.deletingLastPathComponent().appendingPathComponent("Other.cutline")))
    }

    @Test func resetClearsOnlyThePlayground() {
        let (editor, undo, _) = Self.makeProject()
        Self.step(undo) { editor.addTrack(.video) }
        let projectBefore = editor.state
        let playground = editor.ensurePlayground()
        playground.editor.store.edit("Scratch") { state in
            state.tracks[0].clips = [Clip(id: UUID(), mediaID: UUID(), name: "x", start: .zero, duration: Time(seconds: 1), sourceStart: .zero)]
        }
        playground.snapshots = [PlaygroundSnapshot(name: "s", date: Date(), project: playground.editor.state, variants: [])]
        playground.reset()
        #expect(playground.editor.state.allClips.isEmpty && playground.snapshots.isEmpty)
        #expect(!playground.undoManager.canUndo)
        #expect(editor.state == projectBefore && undo.canUndo, "the project and its undo history are untouched")
    }

    @Test func leavingThePlaygroundPausesItsPlayback() {
        let (editor, _, _) = Self.makeProject()
        editor.workspace = .playground
        let playground = editor.playground!
        playground.editor.playback.providesFrames = true
        editor.workspace = .edit
        #expect(!playground.editor.playback.isPlaying && !playground.editor.playback.providesFrames)
    }
}
