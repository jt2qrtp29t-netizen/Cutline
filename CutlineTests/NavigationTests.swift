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
