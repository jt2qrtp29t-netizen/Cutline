import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct GradeWorkflowTests {
    private func setup(clips count: Int = 3) -> (EditorController, UndoManager, [Clip]) {
        var state = ProjectState()
        let clips = (0..<count).map { i in
            Clip(id: UUID(), mediaID: UUID(), name: "c\(i)", start: Time(seconds: Double(i) * 4),
                 duration: Time(seconds: i == 2 ? 1 : 4), sourceStart: .zero)
        }
        state.tracks[0].clips = clips
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        return (editor, undo, clips)
    }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func copyAndPasteAGradeWithItsKeyframes() {
        let (editor, undo, clips) = setup()
        step(undo) {
            editor.store.edit("Grade") { state in
                state.updateClip(clips[0].id) { clip in
                    clip.color.gain = ColorWheel(x: 0.2, y: -0.1, master: 0.3)
                    clip.color.curves.green = ToneCurve(points: [CurvePoint(x: 0, y: 0.1), CurvePoint(x: 1, y: 1)])
                    clip.animation.setKeyframe(.temperature, at: .zero, value: -0.5)
                    clip.animation.setKeyframe(.temperature, at: Time(seconds: 3), value: 0.5)
                    clip.animation.setKeyframe(.scale, at: .zero, value: 2)   // motion: not part of the grade
                }
            }
        }
        editor.selection = [clips[0].id]
        editor.copyGrade()
        #expect(editor.copiedGrade?.sourceName == "c0")

        editor.selection = [clips[1].id, clips[2].id]
        step(undo) { editor.pasteGrade() }
        let b = editor.state.clip(clips[1].id)!, c = editor.state.clip(clips[2].id)!
        #expect(b.color == editor.state.clip(clips[0].id)!.color && c.color.gain.master == 0.3)
        #expect(b.animation.keyframes(for: .temperature).count == 2)
        #expect(c.animation.keyframes(for: .temperature).count == 1, "the keyframe past the 1 s clip's end is dropped")
        #expect(!b.isAnimated(.scale), "motion isn't pasted")
        #expect(undo.undoActionName == "Paste Grade to 2 Clips")
        undo.undo()
        #expect(editor.state.clip(clips[1].id)!.color.isNeutral && editor.state.clip(clips[2].id)!.color.isNeutral)
    }

    @Test func applyToTrackSkipsLockedClips() {
        let (editor, undo, clips) = setup()
        step(undo) {
            editor.store.edit("Setup") { state in
                state.updateClip(clips[0].id) { $0.color.offset.master = -0.2 }
                state.updateClip(clips[2].id) { $0.isLocked = true }
            }
        }
        step(undo) { editor.applyGradeToTrack(from: clips[0].id) }
        #expect(editor.state.clip(clips[1].id)!.color.offset.master == -0.2)
        #expect(editor.state.clip(clips[2].id)!.color.isNeutral, "locked")
    }

    @Test func beforeShowsTheUngradedFrameWithoutChangingTheProject() async throws {
        let media = try await PlaybackTests.media("Sunset")
        var state = ProjectState(settings: ProjectSettings(name: "T", width: 1920, height: 1080, frameRate: 30),
                                 videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [media]
        var clip = Clip(id: UUID(), mediaID: media.id, name: "Sunset", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        clip.color.offset.master = -0.5
        clip.animation.setKeyframe(.saturation, at: .zero, value: 0)
        state.tracks[0].clips = [clip]

        let stripped = state.withoutGrades()
        #expect(stripped.tracks[0].clips[0].color.isNeutral && !stripped.tracks[0].clips[0].isAnimated(.saturation))
        #expect(state.tracks[0].clips[0].color.offset.master == -0.5, "the project itself is untouched")

        func pixel(_ state: ProjectState) async throws -> [Int] {
            let output = try await CompositionBuilder.build(state, urls: [media.id: media.fileURL])
            let generator = AVAssetImageGenerator(asset: output.composition)
            generator.videoComposition = output.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let p = try TextRenderTests.pixel(try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image, x: 200, y: 150)
            return [p.r, p.g, p.b]
        }
        var ungraded = state
        ungraded.tracks[0].clips[0].color = .neutral
        ungraded.tracks[0].clips[0].animation = ClipAnimation()
        let expected = try await pixel(ungraded)
        let before = try await pixel(stripped)
        #expect(before == expected)
        #expect(try await pixel(state) != expected, "graded is different")

        let editor = EditorController(store: ProjectStore(state: state))
        editor.isHoldingBefore = true
        #expect(editor.showsUngraded && editor.playback.gradeBypassed)
        editor.isHoldingBefore = false
        editor.bypassGrade = true
        #expect(editor.playback.gradeBypassed)
        editor.bypassGrade = false
        #expect(!editor.playback.gradeBypassed && editor.state == state)
    }
}
