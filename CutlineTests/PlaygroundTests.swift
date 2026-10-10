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

@MainActor struct SendAndPromoteTests {
    @Test func sentClipsAreIndependentSnapshots() {
        let (editor, undo, original) = PlaygroundTests.makeProject()
        editor.sendToPlayground([original.id])
        let playground = editor.playground!
        #expect(editor.workspace == .playground)
        let copy = playground.editor.state.allClips.first!
        #expect(copy.id != original.id && copy.color == original.color, "a copy with its own ID and the same look")
        #expect(playground.origins[copy.id] == original.id)
        #expect(!undo.canUndo, "sending doesn't touch the project's history")

        // Editing the copy leaves the original alone.
        playground.editor.store.edit("Grade") { $0.updateClip(copy.id) { $0.color.gain.master = -0.7 } }
        #expect(editor.state.clip(original.id)!.color.gain.master == 0.2)

        // Deleting the original (or its whole track) doesn't affect the copy.
        PlaygroundTests.step(undo) { editor.selection = [original.id]; editor.deleteSelection() }
        #expect(playground.editor.state.clip(copy.id)?.color.gain.master == -0.7)
        #expect(playground.editor.originalInProject(of: copy.id) == nil)
        PlaygroundTests.step(undo) { editor.deleteTrack(at: 0) }
        #expect(playground.editor.state.clip(copy.id) != nil)
    }

    @Test func linkedClipsAndMediaTravelTogether() {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "m", path: "/tmp/m.mov", duration: Time(seconds: 10), width: 1920, height: 1080,
                              frameRate: 30, hasVideo: true, hasAudio: true)
        state.media = [media]
        let link = UUID()
        var video = Clip(id: UUID(), mediaID: media.id, name: "v", start: Time(seconds: 2), duration: Time(seconds: 3), sourceStart: .zero)
        var audio = video
        audio.id = UUID()
        video.linkID = link
        audio.linkID = link
        state.tracks[0].clips = [video]
        state.tracks[1].clips = [audio]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.playgroundFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        editor.sendToPlayground([video.id])
        let scratch = editor.playground!.editor.state
        #expect(scratch.allClips.count == 2 && scratch.media.map(\.id) == [media.id])
        let copies = scratch.allClips
        #expect(copies[0].linkID != nil && copies[0].linkID == copies[1].linkID && copies[0].linkID != link)
        #expect(copies.allSatisfy { $0.start == .zero }, "placed at the start of an empty Playground")
    }

    @Test func promotingAddsANewClipAsOneUndoStep() {
        let (editor, undo, original) = PlaygroundTests.makeProject()
        editor.sendToPlayground([original.id])
        let sandbox = editor.playground!.editor
        let copy = sandbox.state.allClips[0]
        sandbox.store.edit("Tweak") { $0.updateClip(copy.id) { $0.transform.scale = 1.5 } }

        editor.playback.seek(to: Time(seconds: 1))   // overlaps the original on V1
        let clipsBefore = editor.state.allClips.count
        PlaygroundTests.step(undo) { sandbox.promoteToEdit([copy.id]) }
        #expect(editor.state.allClips.count == clipsBefore + 1)
        let promoted = editor.state.allClips.first { $0.id != original.id }!
        #expect(promoted.transform.scale == 1.5 && promoted.start == Time(seconds: 1))
        #expect(editor.state.track(ofClip: promoted.id)?.id != editor.state.track(ofClip: original.id)?.id,
                "a new track rather than overwriting the original")
        #expect(editor.workspace == .edit && editor.selection == [promoted.id])
        #expect(editor.state.clip(original.id)!.transform.scale == 1, "the original isn't touched")
        undo.undo()
        #expect(editor.state.allClips.count == clipsBefore && !undo.canUndo, "one undo step")
    }

    @Test func applyingSettingsKeepsTheTargetsFootageAndTiming() {
        let (editor, undo, original) = PlaygroundTests.makeProject()
        editor.sendToPlayground([original.id])
        let sandbox = editor.playground!.editor
        let copy = sandbox.state.allClips[0]
        sandbox.store.edit("Tweak") { state in
            state.updateClip(copy.id) { clip in
                clip.color.offset.master = 0.3
                clip.opacity = 0.5
                clip.duration = Time(seconds: 1)   // timing changes stay in the Playground
                clip.animation.setKeyframe(.rotation, at: .zero, value: 0)
                clip.animation.setKeyframe(.rotation, at: Time(seconds: 3), value: 90)
                clip.animation.setKeyframe(.rotation, at: Time(seconds: 9), value: 0)   // beyond the original's end
            }
        }
        PlaygroundTests.step(undo) { sandbox.applySettingsToProject(from: copy.id, onto: original.id) }
        let updated = editor.state.clip(original.id)!
        #expect(updated.color.offset.master == 0.3 && updated.opacity == 0.5)
        #expect(updated.duration == Time(seconds: 4) && updated.mediaID == original.mediaID, "footage and timing kept")
        #expect(updated.animation.keyframes(for: .rotation).count == 2)
        undo.undo()
        #expect(editor.state.clip(original.id) == original)
    }
}
