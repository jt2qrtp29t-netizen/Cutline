import AppKit
import Foundation
import Testing
@testable import Cutline

@MainActor struct NavigationTests {
    @Test func horizontalScrollStepsThroughTabsAndStopsAtTheEnds() {
        let editor = EditorController(store: ProjectStore(state: ProjectState()))
        #expect(editor.workspace == .edit)
        editor.switchWorkspace(by: -1)
        #expect(editor.workspace == .edit, "nothing left of the first tab")
        editor.switchWorkspace(by: 1)
        #expect(editor.workspace == .effects)
        editor.switchWorkspace(by: 1)
        #expect(editor.workspace == .color)
        editor.switchWorkspace(by: 1)
        #expect(editor.workspace == .audio, "Audio comes after Color")
        editor.switchWorkspace(by: 1)
        editor.switchWorkspace(by: 1)
        editor.switchWorkspace(by: 1)
        #expect(editor.workspace == .export, "stops at the last tab")
        editor.switchWorkspace(by: -1)
        #expect(editor.workspace == .playground)
    }

    @Test func optionDraggingMovesThePlayheadOneFrameAtATime() {
        var state = ProjectState()
        state.tracks[0].clips = [Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero,
                                      duration: Time(seconds: 20), sourceStart: .zero)]
        let editor = EditorController(store: ProjectStore(state: state))
        let fps = editor.fps
        // Zoomed far out: 10 points per second, so a normal drag covers several frames per point.
        let layout = TimelineLayout(pixelsPerSecond: 10, tracks: state.tracks)
        editor.playback.seek(to: Time(seconds: 5))

        let step = EditorController.fineScrubPointsPerFrame
        let x = layout.x(for: Time(seconds: 5))
        editor.dragPlayhead(viewportX: x, contentX: x, layout: layout, modifiers: .option)
        #expect(editor.playback.currentTime == Time(seconds: 5), "starting doesn't jump")
        editor.dragPlayhead(viewportX: x + step * 0.6, contentX: x + step * 0.6, layout: layout, modifiers: .option)
        #expect(editor.playback.currentTime == Time(seconds: 5), "less than a step: no move")
        editor.dragPlayhead(viewportX: x + step * 3.2, contentX: x + step * 3.2, layout: layout, modifiers: .option)
        #expect(editor.playback.currentTime == (Time(seconds: 5) + Time(seconds: 3.0 / Double(fps))).snappedToFrame(fps: fps))
        editor.dragPlayhead(viewportX: x - step * 2, contentX: x - step * 2, layout: layout, modifiers: .option)
        #expect(editor.playback.currentTime == (Time(seconds: 5) - Time(seconds: 2.0 / Double(fps))).snappedToFrame(fps: fps))

        // Letting go of Option makes the playhead follow the pointer again.
        editor.dragPlayhead(viewportX: x + 100, contentX: x + 100, layout: layout, modifiers: [])
        #expect(!editor.isFineScrubbing)
        #expect(editor.playback.currentTime == Time(seconds: 15).snappedToFrame(fps: fps))
        editor.endPlayheadDrag()
    }
}

struct TabScrollGestureTests {
    /// Feeds deltas 16 ms apart starting at `start`; returns the steps taken and the end time.
    private func play(_ deltas: [CGFloat], precise: Bool = true, into gesture: inout TabScrollGesture,
                      start: TimeInterval, interval: TimeInterval = 0.016) -> (steps: [Int], end: TimeInterval) {
        var steps: [Int] = []
        var t = start
        for d in deltas {
            let step = gesture.feed(dx: d, precise: precise, at: t)
            if step != 0 { steps.append(step) }
            t += interval
        }
        return (steps, t)
    }

    let flick: [CGFloat] = [-2, -5, -10, -16, -14, -10, -7, -5, -4, -3, -3, -2, -2, -2]
    let coast = [CGFloat](repeating: -1, count: 40)

    @Test func eachSmoothFlickMovesOneTabEvenWhileTheLastOneIsStillCoasting() {
        var gesture = TabScrollGesture()
        // Three flicks back to back, each starting while the previous one coasts.
        let result = play(flick + coast + flick + coast + flick + coast, into: &gesture, start: 100)
        #expect(result.steps == [1, 1, 1])
    }

    @Test func coastingAloneNeverStepsAgain() {
        var gesture = TabScrollGesture()
        let result = play(flick + [CGFloat](repeating: -1, count: 200), into: &gesture, start: 100)
        #expect(result.steps == [1])
    }

    @Test func notchedWheelsStepPerNotchBurstAndReverse() {
        var gesture = TabScrollGesture()
        var t: TimeInterval = 100
        var steps: [Int] = []
        // Continuous spinning is one flick; pauses separate flicks; scrolling left steps left.
        for burst: [CGFloat] in [[-1, -1, -1, -1], [-1, -1], [1, 1, 1]] {
            let r = play(burst, precise: false, into: &gesture, start: t, interval: 0.03)
            steps += r.steps
            t = r.end + 0.4
        }
        #expect(steps == [1, 1, -1])
    }
}
