import Foundation
import Testing
@testable import Cutline

struct PresetTests {
    let settings = ProjectSettings(name: "T", width: 1920, height: 1080, frameRate: 30)
    let frame = Time.frame(fps: 30)

    func clip(duration: Double = 4) -> Clip {
        Clip(id: UUID(), mediaID: UUID(), name: "c", start: Time(seconds: 10),
             duration: Time(seconds: duration), sourceStart: .zero)
    }

    /// Value of a parameter `seconds` into the clip.
    func value(_ clip: Clip, _ property: AnimatableProperty, _ seconds: Double) -> Double {
        clip.value(of: property, at: clip.start + Time(seconds: seconds))
    }

    @Test func fadeInAndOut() {
        let faded = AnimationPreset.fade.apply(to: clip(), placement: .animateIn, duration: 0.5, settings: settings)
        #expect(value(faded, .opacity, 0) == 0)
        #expect(value(faded, .opacity, 0.5) == 1)
        #expect(value(faded, .opacity, 2) == 1)
        #expect(faded.animation.keyframes(for: .opacity).first?.easing == .easeOut)

        let out = AnimationPreset.fade.apply(to: clip(), placement: .animateOut, duration: 0.5, settings: settings)
        let lastFrame = 4 - frame.seconds
        #expect(value(out, .opacity, lastFrame) == 0, "fully faded on the last frame shown")
        #expect(value(out, .opacity, lastFrame - 0.5) == 1)
        #expect(out.animation.keyframes(for: .opacity).first?.easing == .easeIn, "fade out accelerates")
    }

    @Test func slidesStartOrEndOffscreenRelativeToTheCurrentPosition() {
        var base = clip()
        base.transform.positionX = 100
        let fromLeft = AnimationPreset.slideLeft.apply(to: base, placement: .animateIn, duration: 0.5, settings: settings)
        #expect(value(fromLeft, .positionX, 0) == 100 - 1920)
        #expect(value(fromLeft, .positionX, 0.5) == 100)

        let toBottom = AnimationPreset.slideDown.apply(to: clip(), placement: .animateOut, duration: 1, settings: settings)
        #expect(value(toBottom, .positionY, 4 - frame.seconds) == 1080)
        #expect(value(toBottom, .positionY, 2) == 0)
    }

    @Test func zoomPopOvershootsAndBounceSettles() {
        let pop = AnimationPreset.zoomPop.apply(to: clip(), placement: .animateIn, duration: 1, settings: settings)
        #expect(value(pop, .scale, 0) == AnimatableProperty.scale.range.lowerBound, "zoom is clamped to its minimum")
        #expect(abs(value(pop, .scale, 0.7) - 1.12) < 0.001, "overshoots before settling")
        #expect(value(pop, .scale, 1) == 1)
        #expect(value(pop, .opacity, 0) == 0)

        let bounce = AnimationPreset.bounce.apply(to: clip(), placement: .animateIn, duration: 1, settings: settings)
        #expect(value(bounce, .positionY, 0) < -500, "starts above the frame")
        let samples = stride(from: 0.0, through: 1.0, by: 1.0 / 30).map { value(bounce, .positionY, $0) }
        #expect(samples.max()! <= 0.0001, "never falls below its resting place")
        #expect(value(bounce, .positionY, 1) == 0)
    }

    @Test func shakesReturnToRest() {
        let shake = AnimationPreset.shake.apply(to: clip(), placement: .animateIn, duration: 0.5, settings: settings)
        let samples = stride(from: 0.0, through: 0.5, by: 1.0 / 60).map { value(shake, .positionX, $0) }
        #expect(samples.map(abs).max()! > 20 && samples.map(abs).max()! <= 1920 * 0.025 + 0.001)
        #expect(value(shake, .positionX, 0.5) == 0)
    }

    @Test func gameplayPresetsStartAtTheGivenTime() {
        let punch = AnimationPreset.zoomPunch.apply(to: clip(), placement: .at(Time(seconds: 2)), duration: 0.45, settings: settings)
        let frames = punch.animation.keyframes(for: .scale)
        #expect(frames.first?.time == Time(seconds: 2))
        #expect(value(punch, .scale, 1.9) == 1, "nothing changes before the playhead")
        let peak = stride(from: 2.0, through: 2.45, by: 1.0 / 60).map { value(punch, .scale, $0) }.max()!
        #expect(abs(peak - 1.25) < 0.01)
        // 0.45 s ends between frames; the last keyframe snaps to a frame boundary.
        #expect(value(punch, .scale, 2.5) == 1)

        let shakeA = AnimationPreset.screenShake.apply(to: clip(), placement: .at(Time(seconds: 1)), duration: 0.5, settings: settings)
        let shakeB = AnimationPreset.screenShake.apply(to: clip(), placement: .at(Time(seconds: 1)), duration: 0.5, settings: settings)
        func points(_ clip: Clip) -> [[Double]] {
            [AnimatableProperty.positionX, .positionY].map { p in
                clip.animation.keyframes(for: p).flatMap { [$0.time.seconds, $0.value] }
            }
        }
        #expect(points(shakeA) == points(shakeB), "the same every time")
        #expect(shakeA.isAnimated(.positionX) && shakeA.isAnimated(.positionY))
        #expect(value(shakeA, .positionX, 1.5) == 0 && value(shakeA, .positionY, 1.5) == 0)
    }

    @Test func presetsKeepExistingKeyframesOutsideTheirWindow() {
        var base = clip()
        base.animation.keyframes[.positionX] = [Keyframe(time: Time(seconds: 1), value: 0),
                                                Keyframe(time: Time(seconds: 3), value: 400)]
        let shaken = AnimationPreset.screenShake.apply(to: base, placement: .at(Time(seconds: 1.5)), duration: 0.5, settings: settings)
        let times = shaken.animation.keyframes(for: .positionX).map(\.time)
        #expect(times.contains(Time(seconds: 1)) && times.contains(Time(seconds: 3)))
        // At the window's edges the clip is exactly where the existing animation puts it.
        #expect(abs(value(shaken, .positionX, 1.5) - value(base, .positionX, 1.5)) < 0.001)
        #expect(abs(value(shaken, .positionX, 2) - value(base, .positionX, 2)) < 0.001)
    }

    @Test func applyingIsOneUndoStepAndSkipsClipsAwayFromThePlayhead() {
        var state = ProjectState()
        let a = clip()
        var b = clip()
        b.id = UUID()
        b.start = Time(seconds: 20)
        state.tracks[0].clips = [a, b]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo

        undo.beginUndoGrouping()
        editor.applyPreset(.fade, placement: .animateIn, duration: 0.5, to: [a.id, b.id])
        undo.endUndoGrouping()
        #expect(editor.state.clip(a.id)!.isAnimated(.opacity) && editor.state.clip(b.id)!.isAnimated(.opacity))
        #expect(undo.undoActionName == "Fade In")
        undo.undo()
        #expect(!editor.state.clip(a.id)!.isAnimated(.opacity) && !editor.state.clip(b.id)!.isAnimated(.opacity))

        editor.playback.seek(to: Time(seconds: 11))
        undo.beginUndoGrouping()
        editor.applyPreset(.zoomPunch, placement: .at(.zero), duration: 0.45, to: [a.id, b.id])
        undo.endUndoGrouping()
        #expect(editor.state.clip(a.id)!.isAnimated(.scale))
        #expect(!editor.state.clip(b.id)!.isAnimated(.scale), "the playhead isn't over clip b")
    }

    @Test func mirroredEasingPlaysBackwards() {
        let curve = Easing.bezier(x1: 0.2, y1: 0.7, x2: 0.4, y2: 1)
        for u in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(abs(curve.mirrored.apply(u) - (1 - curve.apply(1 - u))) < 1e-6)
        }
        #expect(Easing.easeIn.mirrored == .easeOut)
    }
}
