import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct AudioLayoutTests {
    @Test func theAudioTabShowsAudioKeyframes() {
        var state = ProjectState()
        let a1 = state.trackIndices(of: .audio)[0]
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "Voice", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        clip.animation.setKeyframe(.volume, at: .zero, value: 0.5)
        clip.animation.setKeyframe(.positionX, at: .zero, value: 10)
        state.tracks[a1].clips = [clip]
        let eq = AudioEffect(kind: .equalizer)
        state.tracks[a1].audio.effects = [eq]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.selection = [clip.id]
        editor.workspace = .audio
        #expect(editor.audioClip?.id == clip.id && editor.effectsClip == nil, "audio clips belong to the Audio tab")
        let lane = KeyframeLane(editor: editor, layout: TimelineLayout(pixelsPerSecond: 50, tracks: state.tracks), visibleRect: .zero)
        #expect(lane.rows(for: clip) == [.volume], "only sound keyframes here")
        editor.workspace = .effects
        #expect(!lane.rows(for: clip).contains(.volume), "and not in Effects")
        #expect(AnimatableProperty.volume.isAudio && !AnimatableProperty.volume.isColor && !AnimatableProperty.volume.isMotion)

        let lowCut = AudioEffectKind.equalizer.parameter("lowCut")!
        #expect(editor.trackParameterTitle("volume", in: editor.state.tracks[a1]) == "Volume")
        #expect(editor.trackParameterTitle(eq.keyframeKey(lowCut), in: editor.state.tracks[a1]) == "Equalizer · Low Cut")
    }

    @Test func trackKeyframesRetimeAsOneStepAndChangeEasing() {
        var state = ProjectState()
        let a1 = state.trackIndices(of: .audio)[0]
        let first = Keyframe(time: Time(seconds: 1), value: -6), second = Keyframe(time: Time(seconds: 3), value: 0)
        state.tracks[a1].audio.keyframes["volume"] = [first, second]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        let id = state.tracks[a1].id

        undo.beginUndoGrouping()
        for ms in stride(from: 100, through: 1_000, by: 100) {
            editor.moveTrackKeyframe(first.id, key: "volume", track: id, by: Time(seconds: Double(ms) / 1000))
        }
        editor.endAudioAdjustment("Move Keyframe")
        undo.endUndoGrouping()
        #expect(editor.state.tracks[a1].audio.keyframes["volume"]?.first?.time == Time(seconds: 2))
        undo.undo()
        #expect(editor.state.tracks[a1].audio.keyframes["volume"]?.first?.time == Time(seconds: 1), "one drag, one undo")

        undo.beginUndoGrouping()
        editor.setTrackKeyframeEasing(.easeOut, id: first.id, key: "volume", track: id)
        undo.endUndoGrouping()
        #expect(editor.state.tracks[a1].audio.keyframes["volume"]?.first?.easing == .easeOut)
        undo.beginUndoGrouping()
        editor.deleteTrackKeyframe(first.id, key: "volume", track: id)
        editor.deleteTrackKeyframe(second.id, key: "volume", track: id)
        undo.endUndoGrouping()
        #expect(editor.state.tracks[a1].audio.keyframes["volume"] == nil)
    }

    /// The Playground has its own audio graph: sandbox mixing never reaches the project's.
    @Test func thePlaygroundHasItsOwnAudioGraph() async throws {
        var (base, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 2, amplitude: 0.4)])
        base.id = UUID()
        let editor = EditorController(store: ProjectStore(state: base))
        editor.playgroundFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        let clip = AudioTestKit.firstClip(base)
        editor.sendToPlayground([clip.id])
        let sandbox = try #require(editor.playground?.editor)
        #expect(sandbox.playback.audio.graph !== editor.playback.audio.graph)
        #expect(sandbox.playback.audio.engine !== editor.playback.audio.engine)

        // Mix the sandbox's copy very differently.
        let sandboxTrack = try #require(sandbox.audioTrackIndices.first { !sandbox.state.tracks[$0].clips.isEmpty })
        let sandboxID = sandbox.state.tracks[sandboxTrack].id
        sandbox.applyPreset(.radio, to: sandboxID)
        sandbox.adjustTrackAudio(.volume, to: -20, track: sandboxID)
        sandbox.endAudioAdjustment("Change Volume")
        #expect(editor.state == base, "nothing reaches the project")

        // Each renders its own mix.
        let project = try await AudioTestKit.render(editor.state, sources: sources, seconds: 1.5)
        let scratch = try await AudioTestKit.render(sandbox.state, sources: sources, seconds: 1.5, from: sandbox.state.tracks[sandboxTrack].clips[0].start.seconds)
        let projectLevel = project.rms(seconds: 0.5...1.2).left, scratchLevel = scratch.rms(seconds: 0.5...1.2).left
        #expect(projectLevel > 0.2 && scratchLevel < projectLevel * 0.3, "\(projectLevel) vs \(scratchLevel)")
    }
}

struct AudioWindowFitTests {
    @Test func sideColumnsShrinkSoTheTabFitsTheWindow() {
        // Roomy window: the widths as set.
        let wide = AudioWorkspaceLayout.fit(mixer: 460, panel: 340, available: 1800)
        #expect(wide.mixer == 460 && wide.panel == 340)
        // A small window (like 1000 points): everything still fits, the preview keeps its share.
        for available in [1100.0, 1000, 900, 760] {
            let fitted = AudioWorkspaceLayout.fit(mixer: 460, panel: 340, available: available)
            #expect(fitted.mixer + fitted.panel + AudioWorkspaceLayout.dividers + AudioWorkspaceLayout.minimumPreview <= available + 0.001,
                    "\(available): \(fitted)")
            #expect(fitted.mixer >= AudioWorkspaceLayout.mixerRange.lowerBound && fitted.panel >= AudioWorkspaceLayout.panelRange.lowerBound)
        }
        // Tiny windows bottom out at the minimums rather than vanishing.
        let tiny = AudioWorkspaceLayout.fit(mixer: 460, panel: 340, available: 500)
        #expect(tiny.mixer == AudioWorkspaceLayout.mixerRange.lowerBound && tiny.panel == AudioWorkspaceLayout.panelRange.lowerBound)
    }

    @Test func theMixerNeverHidesTrackStrips() {
        // Master and loudness stay pinned only when a whole track strip fits beside them;
        // otherwise everything scrolls together.
        #expect(MixerLayout.pinsMaster(width: 460))
        #expect(!MixerLayout.pinsMaster(width: 300), "the case in the screenshot: the strip would get no room")
        #expect(!MixerLayout.pinsMaster(width: MixerLayout.masterAndLoudnessWidth + MixerLayout.stripWidth))
    }
}

@MainActor struct WindowSizeTests {
    @Test func projectWindowsAreAtLeast60PercentOfA27InchDisplay() {
        #expect(WindowMetrics.preferredMinimumWidth == 1536, "60% of 2560 points")
        let screen = NSScreen.main?.visibleFrame.width ?? 1536
        #expect(WindowMetrics.minimumWidth == min(1536, screen), "never wider than the screen")
        #expect(WindowMetrics.defaultWidth >= WindowMetrics.minimumWidth)
    }
}
