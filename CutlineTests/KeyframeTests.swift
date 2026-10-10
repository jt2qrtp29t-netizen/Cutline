import Foundation
import Testing
@testable import Cutline

struct KeyframeTests {
    // MARK: Easing

    @Test func easingCurves() {
        for easing in [Easing.linear, .easeIn, .easeOut, .easeInOut, .bezier(x1: 0.2, y1: 0.8, x2: 0.4, y2: 1.2)] {
            #expect(abs(easing.apply(0)) < 1e-9 && abs(easing.apply(1) - 1) < 1e-9, "\(easing) runs 0 → 1")
        }
        #expect(Easing.linear.apply(0.25) == 0.25)
        // Reference values of the CSS timing functions at the halfway point.
        #expect(abs(Easing.easeIn.apply(0.5) - 0.3153) < 0.001)
        #expect(abs(Easing.easeOut.apply(0.5) - 0.6847) < 0.001)
        #expect(abs(Easing.easeInOut.apply(0.5) - 0.5) < 0.001)
        // A custom curve may overshoot.
        let overshoot = (0...100).map { Easing.bezier(x1: 0.3, y1: 1.6, x2: 0.6, y2: 1.4).apply(Double($0) / 100) }
        #expect(overshoot.max()! > 1.05)
        // Ease in starts slowly, ease out finishes slowly.
        #expect(Easing.easeIn.apply(0.1) < 0.05 && Easing.easeOut.apply(0.9) > 0.95)
    }

    @Test func interpolationHoldsOutsideKeyframes() {
        var animation = ClipAnimation()
        animation.keyframes[.opacity] = [Keyframe(time: Time(seconds: 1), value: 0, easing: .easeInOut),
                                         Keyframe(time: Time(seconds: 3), value: 1)]
        #expect(animation.value(of: .opacity, atOffset: .zero) == 0)
        #expect(abs(animation.value(of: .opacity, atOffset: Time(seconds: 2))! - 0.5) < 0.001)
        #expect(animation.value(of: .opacity, atOffset: Time(seconds: 9)) == 1)
        #expect(animation.value(of: .scale, atOffset: .zero) == nil, "un-animated parameters use the clip's value")
    }

    // MARK: Blade

    private func animatedClip() -> Clip {
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: Time(seconds: 2),
                        duration: Time(seconds: 10), sourceStart: .zero)
        clip.animation.keyframes[.positionX] = [
            Keyframe(time: .zero, value: -500, easing: .easeIn),
            Keyframe(time: Time(seconds: 4), value: 300, easing: .bezier(x1: 0.1, y1: 0.9, x2: 0.3, y2: 1.3)),
            Keyframe(time: Time(seconds: 9), value: 0, easing: .easeOut),
        ]
        clip.animation.keyframes[.rotation] = [Keyframe(time: Time(seconds: 1), value: 0, easing: .easeInOut),
                                               Keyframe(time: Time(seconds: 8), value: 180)]
        clip.transform.scale = 0.7
        return clip
    }

    @Test(arguments: [2.5, 4.0, 5.3, 6.0, 9.75, 11.5])
    func bladeSplitsAnimationWithoutAJump(cutSeconds: Double) throws {
        var state = ProjectState(videoTracks: 1, audioTracks: 0, textTracks: 0)
        let original = animatedClip()
        state.tracks[0].clips = [original]
        let cut = Time(seconds: cutSeconds)
        TimelineEditing.blade(at: cut, clips: [], in: &state)
        let halves = state.tracks[0].clips
        try #require(halves.count == 2)
        let (left, right) = (halves[0], halves[1])

        // Both halves reproduce the original motion at every frame.
        var t = original.start
        while t < original.end {
            let piece = t < cut ? left : right
            for property in AnimatableProperty.allCases {
                let expected = original.value(of: property, at: t)
                let actual = piece.value(of: property, at: t)
                #expect(abs(expected - actual) < 1e-6, "\(property) at \(t.seconds)s: \(actual) vs \(expected)")
            }
            t += Time.frame(fps: 30)
        }
        // The first half ends exactly where the second begins.
        for property in [AnimatableProperty.positionX, .rotation] {
            let end = left.animation.keyframes(for: property).last
            let start = right.animation.keyframes(for: property).first
            #expect(end?.time == cut - original.start && start?.time == .zero)
            #expect(end?.value == start?.value)
            #expect(abs(end!.value - original.value(of: property, at: cut)) < 1e-9)
        }
    }

    @Test func trimmingTheStartKeepsTheAnimationInPlace() {
        let original = animatedClip()
        let trimmed = TimelineEditing.trimmedStart(original, to: Time(seconds: 5))
        for seconds in stride(from: 5.0, to: 12.0, by: 0.5) {
            let t = Time(seconds: seconds)
            #expect(abs(trimmed.value(of: .positionX, at: t) - original.value(of: .positionX, at: t)) < 1e-9)
        }
    }

    // MARK: Save / load

    @Test func keyframesRoundTrip() throws {
        var state = ProjectState()
        state.tracks[0].clips = [animatedClip()]
        let decoded = try ProjectState.decode(state.encoded())
        #expect(decoded == state)
        #expect(decoded.tracks[0].clips[0].animation.keyframes(for: .positionX)[1].easing
                == .bezier(x1: 0.1, y1: 0.9, x2: 0.3, y2: 1.3))
    }

    @Test func oldStartEndProjectsLoadAsTwoKeyframes() throws {
        let mediaID = UUID()
        let json = """
        {"version":3,"settings":{"name":"Old","width":1920,"height":1080,"frameRate":30},
         "media":[{"id":"\(mediaID)","name":"m","path":"/m.mov","duration":6000,"width":1280,"height":720,"frameRate":30,"hasVideo":true,"hasAudio":false}],
         "tracks":[{"id":"\(UUID())","name":"V1","kind":"video","clips":[{"id":"\(UUID())","mediaID":"\(mediaID)","name":"m",
           "start":0,"duration":3000,"sourceStart":0,"transform":{"positionX":-400,"positionY":100,"endPositionX":400,"scale":1}}]}],
         "markers":[]}
        """
        let state = try ProjectState.decode(Data(json.utf8))
        let clip = state.tracks[0].clips[0]
        let frames = clip.animation.keyframes(for: .positionX)
        #expect(frames.count == 2)
        #expect(frames.first?.time == .zero && frames.first?.value == -400)
        #expect(frames.last?.value == 400 && frames.last!.time < clip.duration)
        #expect(!clip.isAnimated(.positionY), "Y had no end value, so it stays still")
        #expect(clip.value(of: .positionY, at: Time(seconds: 2)) == 100)
        // Halfway through, it's halfway across (linear, like before).
        #expect(abs(clip.value(of: .positionX, at: Time(seconds: 2.5))) < 1)
        // Saving again writes keyframes, not the old fields.
        let saved = String(decoding: try state.encoded(), as: UTF8.self)
        #expect(!saved.contains("endPositionX"))
    }

    // MARK: Deleting animated clips and tracks

    @Test func deletingAnimatedClipsAndTracksClearsSelection() {
        var state = ProjectState()
        let first = animatedClip()
        var second = animatedClip()
        second.id = UUID()
        second.start = Time(seconds: 20)
        state.tracks[0].clips = [first, second]
        let editor = EditorController(store: ProjectStore(state: state))

        editor.selection = [first.id]
        editor.deleteSelection()
        #expect(editor.selection.isEmpty)
        #expect(editor.state.clip(first.id) == nil)

        editor.selection = [second.id]
        editor.deleteTrack(at: 0)
        #expect(editor.selection.isEmpty)
        #expect(editor.state.allClips.isEmpty)
        #expect(editor.state.trackIndices(of: .video).isEmpty)
    }
}
