import Foundation
import Testing
@testable import Cutline

@MainActor struct ColorEditingTests {
    private func setup() -> (EditorController, UndoManager, Clip) {
        var state = ProjectState()
        let clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        editor.selection = [clip.id]
        return (editor, undo, clip)
    }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func wheelKeyframesCoverPuckAndMasterInOneStep() {
        let (editor, undo, clip) = setup()
        editor.playback.seek(to: Time(seconds: 1))
        step(undo) { editor.toggleWheelKeyframe(.offset, in: editor.state.clip(clip.id)!) }
        let keyed = editor.state.clip(clip.id)!
        #expect(GradeWheel.offset.allProperties.allSatisfy { keyed.isAnimated($0) })
        #expect(editor.wheelHasKeyframeHere(.offset, in: keyed))

        // Changing the wheel at another time adds keyframes there: the offset animates.
        editor.playback.seek(to: Time(seconds: 3))
        step(undo) { editor.setGradeValues([.offsetX: 0.5, .offsetMaster: 0.4], of: clip.id, actionName: "Change Offset") }
        let animated = editor.state.clip(clip.id)!
        #expect(animated.grade(at: Time(seconds: 1)).offset == .neutral)
        #expect(animated.grade(at: Time(seconds: 3)).offset.x == 0.5)
        #expect(abs(animated.grade(at: Time(seconds: 2)).offset.master - 0.2) < 1e-9)

        // Removing at the first keyframe takes all three away in one undo step.
        editor.playback.seek(to: Time(seconds: 1))
        step(undo) { editor.toggleWheelKeyframe(.offset, in: editor.state.clip(clip.id)!) }
        #expect(!editor.wheelHasKeyframeHere(.offset, in: editor.state.clip(clip.id)!))
        undo.undo()
        #expect(editor.wheelHasKeyframeHere(.offset, in: editor.state.clip(clip.id)!))
    }

    @Test func resettingAWheelOrSectionClearsValuesAndKeyframes() {
        let (editor, undo, clip) = setup()
        step(undo) {
            editor.setGradeValues([.liftX: 0.3, .liftMaster: 0.2, .gainY: -0.4, .temperature: 0.5], of: clip.id, actionName: "Grade")
        }
        editor.playback.seek(to: Time(seconds: 2))
        step(undo) { editor.toggleWheelKeyframe(.lift, in: editor.state.clip(clip.id)!) }

        step(undo) { editor.resetWheel(.lift, of: clip.id) }
        var c = editor.state.clip(clip.id)!
        #expect(c.color.lift == .neutral && !c.isAnimated(.liftX) && c.color.gain.y == -0.4)

        step(undo) { editor.resetGrade(.wheels, of: clip.id) }
        c = editor.state.clip(clip.id)!
        #expect(c.color.gain == .neutral && c.color.temperature == 0.5, "basic controls untouched")

        step(undo) { editor.resetGrade(nil, of: clip.id) }
        #expect(editor.state.clip(clip.id)!.color.isNeutral)
        undo.undo()
        #expect(editor.state.clip(clip.id)!.color.temperature == 0.5)
    }

    @Test func gradeValuesAreClampedToTheirRanges() {
        let (editor, undo, clip) = setup()
        step(undo) { editor.setGradeValues([.exposure: 9, .saturation: -1], of: clip.id, actionName: "Grade") }
        let c = editor.state.clip(clip.id)!
        #expect(c.color.exposure == 3 && c.color.saturation == 0)
    }

    @Test func deletingAGradedClipClearsTheSelection() {
        let (editor, undo, clip) = setup()
        step(undo) { editor.setGradeValues([.gainMaster: 0.4], of: clip.id, actionName: "Grade") }
        #expect(editor.colorClip?.id == clip.id)
        step(undo) { editor.deleteSelection() }
        #expect(editor.selection.isEmpty && editor.colorClip == nil)
        // Deleting a whole track with a graded clip.
        undo.undo()
        editor.selection = [clip.id]
        step(undo) { editor.deleteTrack(at: 0) }
        #expect(editor.colorClip == nil)
    }
}

@MainActor struct CurveAndLUTEditingTests {
    private func setup() -> (EditorController, UndoManager, Clip) {
        var state = ProjectState()
        let clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        return (editor, undo, clip)
    }

    private func writeLUT(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cube")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aCurvePointDragIsOneUndoStep() {
        let (editor, undo, clip) = setup()
        undo.beginUndoGrouping()
        editor.beginAdjustment()
        for y in stride(from: 0.5, through: 0.8, by: 0.05) {
            editor.setCurve(.red, to: ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: y), CurvePoint(x: 1, y: 1)]),
                            of: clip.id)
        }
        editor.endAdjustment("Add Curve Point")
        undo.endUndoGrouping()
        #expect(abs(editor.state.clip(clip.id)!.color.curves.red.points[1].y - 0.8) < 1e-9)
        undo.undo()
        #expect(editor.state.clip(clip.id)!.color.curves.red == .identity)
    }

    @Test func validLUTsApplyAndInvalidOnesChangeNothing() throws {
        let (editor, undo, clip) = setup()
        let good = try writeLUT("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n")
        undo.beginUndoGrouping()
        try editor.setLUT(good, for: clip.id)
        undo.endUndoGrouping()
        var c = editor.state.clip(clip.id)!
        #expect(c.color.lut?.path == good.path && editor.lutProblem(of: c) == nil)

        let bad = try writeLUT("LUT_3D_SIZE 3\n0 0 0\n")
        #expect(throws: CubeLUT.ParseError.self) { try editor.setLUT(bad, for: clip.id) }
        #expect(editor.state.clip(clip.id)!.color.lut?.path == good.path, "kept the working LUT")

        // The file disappears: the clip warns and renders without it.
        try FileManager.default.removeItem(at: good)
        c = editor.state.clip(clip.id)!
        #expect(editor.lutProblem(of: c) != nil)
        #expect(LUTLibrary.shared.lut(for: c.color.lut) == nil)

        undo.beginUndoGrouping()
        editor.removeLUT(from: clip.id)
        undo.endUndoGrouping()
        #expect(editor.state.clip(clip.id)!.color.lut == nil)
    }

    @Test func aMissingLUTInASavedProjectLoadsWithAWarning() throws {
        var state = ProjectState()
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        clip.color.lut = LUTReference(name: "Lost", path: "/Volumes/Gone/\(UUID()).cube")
        state.tracks[0].clips = [clip]
        let loaded = try ProjectState.decode(state.encoded())
        let editor = EditorController(store: ProjectStore(state: loaded))
        #expect(editor.lutProblem(of: loaded.tracks[0].clips[0]) != nil)
    }
}
