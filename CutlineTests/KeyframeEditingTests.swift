import Foundation
import Testing
@testable import Cutline

/// The keyframe actions behind the Effects tab, including undo.
struct KeyframeEditingTests {
    private func makeEditor() -> (EditorController, UUID, UndoManager) {
        var state = ProjectState()
        let clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: Time(seconds: 1),
                        duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        editor.selection = [clip.id]
        return (editor, clip.id, undo)
    }

    private func grouped(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func diamondAddsAndRemovesAKeyframeAtThePlayhead() throws {
        let (editor, id, undo) = makeEditor()
        editor.playback.seek(to: Time(seconds: 2))
        let clip = try #require(editor.effectsClip)
        grouped(undo) { editor.toggleKeyframe(.opacity, in: clip) }
        let frames = editor.state.clip(id)!.animation.keyframes(for: .opacity)
        #expect(frames.count == 1 && frames[0].time == Time(seconds: 1) && frames[0].value == 1)
        #expect(editor.keyframeAtPlayhead(.opacity, in: editor.state.clip(id)!) != nil)

        grouped(undo) { editor.toggleKeyframe(.opacity, in: editor.state.clip(id)!) }
        #expect(!editor.state.clip(id)!.isAnimated(.opacity))
        undo.undo()
        #expect(editor.state.clip(id)!.animation.keyframes(for: .opacity).count == 1, "undo brings it back")
    }

    @Test func changingAnAnimatedValueSetsAKeyframeAtThePlayhead() throws {
        let (editor, id, undo) = makeEditor()
        editor.playback.seek(to: Time(seconds: 1))
        grouped(undo) { editor.toggleKeyframe(.positionX, in: editor.state.clip(id)!) }
        editor.playback.seek(to: Time(seconds: 4))
        grouped(undo) { editor.setEffectValue(.positionX, of: id, to: 300) }
        let clip = editor.state.clip(id)!
        #expect(clip.animation.keyframes(for: .positionX).map(\.value) == [0, 300])
        #expect(abs(clip.value(of: .positionX, at: Time(seconds: 2.5)) - 150) < 0.001)

        // Un-animated parameters just change their value.
        grouped(undo) { editor.setEffectValue(.rotation, of: id, to: 45) }
        #expect(editor.state.clip(id)!.transform.rotation == 45)
        #expect(!editor.state.clip(id)!.isAnimated(.rotation))
    }

    @Test func retimingEasingAndDeletingAreUndoable() throws {
        let (editor, id, undo) = makeEditor()
        grouped(undo) {
            editor.store.edit("Setup") { state in
                state.updateClip(id) { clip in
                    clip.animation.keyframes[.scale] = [Keyframe(time: .zero, value: 1), Keyframe(time: Time(seconds: 2), value: 2)]
                }
            }
        }
        let second = editor.state.clip(id)!.animation.keyframes(for: .scale)[1]
        let ref = KeyframeRef(clipID: id, property: .scale, keyframeID: second.id)

        // A drag is one undo step, snapped to frames.
        grouped(undo) {
            for step in 1...5 { editor.dragKeyframes([ref], by: Time(seconds: 0.1 * Double(step))) }
            editor.endGesture("Move Keyframe")
        }
        #expect(editor.keyframe(ref)?.time == Time(seconds: 2.5))
        undo.undo()
        #expect(editor.keyframe(ref)?.time == Time(seconds: 2))

        grouped(undo) { editor.setEasing(.easeOut, for: KeyframeRef(clipID: id, property: .scale, keyframeID: editor.state.clip(id)!.animation.keyframes(for: .scale)[0].id)) }
        #expect(editor.state.clip(id)!.animation.keyframes(for: .scale)[0].easing == .easeOut)

        // In the Effects tab, Delete removes selected keyframes, not the clip.
        editor.workspace = .effects
        editor.selectedKeyframes = [ref]
        grouped(undo) { editor.deleteSelection() }
        #expect(editor.state.clip(id) != nil)
        #expect(editor.state.clip(id)!.animation.keyframes(for: .scale).count == 1)
        #expect(editor.selectedKeyframes.isEmpty)
        undo.undo()
        #expect(editor.keyframe(ref) != nil)
    }

    @Test func keyframeSelectionIsClearedWhenTheClipGoes() {
        let (editor, id, _) = makeEditor()
        editor.store.edit("Setup") { state in
            state.updateClip(id) { $0.animation.keyframes[.opacity] = [Keyframe(time: .zero, value: 0)] }
        }
        let frame = editor.state.clip(id)!.animation.keyframes(for: .opacity)[0]
        editor.selectedKeyframes = [KeyframeRef(clipID: id, property: .opacity, keyframeID: frame.id)]
        editor.deleteSelection()
        editor.pruneKeyframeSelection()
        #expect(editor.selectedKeyframes.isEmpty)
        #expect(editor.effectsClip == nil)
    }

    @Test func effectsClipIsOnlyVisualClips() {
        var state = ProjectState()
        let audio = Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero, duration: Time(seconds: 1), sourceStart: .zero)
        state.tracks[1].clips = [audio]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.selection = [audio.id]
        #expect(editor.effectsClip == nil, "audio clips have nothing to animate here")
    }
}
