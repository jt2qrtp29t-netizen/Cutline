import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct ClipToolsTests {
    /// A tone cut in two at `at`, the halves touching with continuous source audio.
    private func cutTone(at seconds: Double, length: Double = 3) async throws -> (ProjectState, [UUID: PreparedAudio], Clip, Clip) {
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: length, frequency: 330)])
        let whole = AudioTestKit.firstClip(state)
        let created = TimelineEditing.blade(at: Time(seconds: seconds), clips: [whole.id], in: &state)
        return (state, sources, try #require(state.clip(whole.id)), try #require(state.clip(created[0])))
    }

    @Test func aLinearCrossfadeAcrossACutIsSeamless() async throws {
        let (state, sources, left, right) = try await cutTone(at: 1.5)
        let reference = try await AudioTestKit.render(state, sources: sources, seconds: 3)
        var faded = state
        let added = faded.addCrossfade(between: left.id, and: right.id, duration: Time(seconds: 0.6), curve: .linear)
        let id = try #require(added)
        let placed = try #require(faded.tracks[AudioTestKit.audioTrack(faded)].placedTransitions().first)
        #expect(placed.transition.id == id && placed.range == TimeRange(start: Time(seconds: 1.2), end: Time(seconds: 1.8)))
        let out = try await AudioTestKit.render(faded, sources: sources, seconds: 3)
        // The two halves play the same continuous sound, so a linear crossfade sums back to it.
        var worst: Float = 0
        for i in 0..<reference.left.count { worst = max(worst, abs(out.left[i] - reference.left[i])) }
        #expect(worst < 1e-4, "largest difference \(worst)")
    }

    @Test func anEqualPowerCrossfadeKeepsTheLevelBetweenDifferentSounds() async throws {
        // Two different tones touching at 1.5 s, each with media before and after the cut.
        let a = try AudioTestKit.tone(seconds: 3, frequency: 300), b = try AudioTestKit.tone(seconds: 3, frequency: 520)
        var (state, sources) = try await AudioTestKit.project([a, b])
        let track = AudioTestKit.audioTrack(state)
        state.tracks[track].clips[0].duration = Time(seconds: 1.5)
        state.tracks[track].clips[1].start = Time(seconds: 1.5)
        state.tracks[track].clips[1].sourceStart = Time(seconds: 1)
        state.tracks[track].clips[1].duration = Time(seconds: 1.5)
        let (first, second) = (state.tracks[track].clips[0], state.tracks[track].clips[1])
        #expect(state.addCrossfade(between: first.id, and: second.id, duration: Time(seconds: 1)) != nil)
        let out = try await AudioTestKit.render(state, sources: sources, seconds: 3)
        let before = out.rms(seconds: 0.4...0.9).left, middle = out.rms(seconds: 1.4...1.6).left, after = out.rms(seconds: 2.1...2.6).left
        #expect(abs(middle / before - 1) < 0.04 && abs(after / before - 1) < 0.02, "steady through the crossfade: \(before) \(middle) \(after)")
        #expect(out.largestStep < 0.06, "no clicks")
    }

    @Test func fadesOutCrossfadesWithoutMediaAndTrims() async throws {
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 2)])
        let clip = AudioTestKit.firstClip(state)
        state.updateClip(clip.id) { $0.fadeOut = AudioFade(duration: Time(seconds: 0.5), curve: .linear) }
        let out = try await AudioTestKit.render(state, sources: sources, seconds: 2)
        let steady = out.rms(seconds: 0.5...1.0).left
        let halfway = out.rms(seconds: 1.74...1.76).left
        #expect(abs(halfway / steady - 0.5) < 0.03, "half way through a linear fade-out: \(halfway / steady)")
        #expect(out.rms(seconds: 1.995...2.0).left < steady * 0.02)

        // Fades always fit their clip: trimming shortens them, together they never exceed it.
        var trimmed = state
        trimmed.updateClip(clip.id) { $0.fadeIn = AudioFade(duration: Time(seconds: 1.2)) }
        TimelineEditing.trim(clip.id, edge: .trailing, to: Time(seconds: 1), in: &trimmed)
        let fitted = try #require(trimmed.clip(clip.id))
        #expect(fitted.fadeIn.duration + fitted.fadeOut.duration <= fitted.duration)

        // A crossfade where the incoming clip has no media before its in-point plays
        // what there is, without a click.
        let second = try AudioTestKit.tone(seconds: 2, frequency: 600)
        var (pair, pairSources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 2), second])
        let t = AudioTestKit.audioTrack(pair)
        #expect(pair.addCrossfade(between: pair.tracks[t].clips[0].id, and: pair.tracks[t].clips[1].id, duration: Time(seconds: 0.4)) != nil)
        let mixed = try await AudioTestKit.render(pair, sources: pairSources, seconds: 4)
        #expect(mixed.rms(seconds: 2.25...2.35).left > 0.1 && mixed.largestStep < 0.08)
        pairSources = [:]
    }

    @Test func fadeAndCrossfadeEditsUndoAndSave() async throws {
        let (state, _, left, right) = try await cutTone(at: 1.5)
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        func grouped(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }

        // Dragging a fade handle: one undo step, limited by the other fade.
        grouped {
            for ms in stride(from: 100, through: 2_000, by: 100) { editor.adjustFade(.leading, of: left.id, to: Time(seconds: Double(ms) / 1000)) }
            editor.endAudioAdjustment("Change Fade In")
        }
        #expect(editor.state.clip(left.id)?.fadeIn.duration == left.duration, "a fade can't outgrow its clip")
        editor.setFade(.trailing, of: [left.id], to: Time(seconds: 1))
        #expect(editor.state.clip(left.id)?.fadeOut.duration == .zero, "no room left for a fade-out")
        undo.undo()
        #expect(editor.state.clip(left.id)?.fadeIn == AudioFade.off, "the drag undoes in one step")
        grouped { editor.setFade(.leading, of: [left.id], to: Time(seconds: 0.3)) }
        grouped { editor.setFadeCurve(.leading, of: [left.id], to: .logarithmic) }
        #expect(editor.state.clip(left.id)?.fadeIn == AudioFade(duration: Time(seconds: 0.3), curve: .logarithmic))

        // Crossfades: between neighbors only, with a curve; saved and loaded.
        #expect(editor.neighbor(of: left.id, after: true)?.id == right.id && editor.neighbor(of: left.id, after: false) == nil)
        grouped { editor.addCrossfade(to: left.id, after: true) }
        let crossfade = try #require(editor.selectedTransition)
        grouped { editor.setCrossfadeCurve(.linear, for: crossfade) }
        #expect(editor.state.transition(crossfade)?.transition.curve == .linear)
        #expect(try ProjectState.decode(editor.state.encoded()) == editor.state)

        // Older transitions (no curve saved) load as equal power.
        var json = try #require(try JSONSerialization.jsonObject(with: editor.state.encoded()) as? [String: Any])
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        for i in tracks.indices {
            tracks[i]["transitions"] = (tracks[i]["transitions"] as? [[String: Any]] ?? []).map { var t = $0; t["curve"] = nil; return t }
        }
        json["tracks"] = tracks
        let old = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.transition(crossfade)?.transition.curve == .equalPower)

        // Deleting a clip takes its crossfade with it.
        grouped { editor.selection = [right.id]; editor.deleteClips([right.id]) }
        #expect(editor.state.transition(crossfade) == nil)
        // Video transitions can't go on audio tracks, and crossfades can't go on video tracks.
        var video = ProjectState()
        let v = Clip(id: UUID(), mediaID: UUID(), name: "v", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        var w = v; w.id = UUID(); w.start = Time(seconds: 2)
        video.tracks[0].clips = [v, w]
        #expect(video.addCrossfade(between: v.id, and: w.id) == nil)
    }

    /// The waveform follows clip gain, volume, fades and crossfades: the same envelope as playback.
    @Test func theWaveformFollowsTheSoundsLevel() async throws {
        let (state, _, left, right) = try await cutTone(at: 1.5)
        var adjusted = state
        adjusted.updateClip(left.id) { $0.gainDB = -6.0206; $0.fadeIn = AudioFade(duration: Time(seconds: 1), curve: .linear) }
        _ = adjusted.addCrossfade(between: left.id, and: right.id, duration: Time(seconds: 1), curve: .linear)
        let track = adjusted.tracks[AudioTestKit.audioTrack(adjusted)]
        let envelope = ClipEnvelope(try #require(adjusted.clip(left.id)), track: track, isActive: true, monoSource: false)
        #expect(abs(envelope.level(at: Time(seconds: 0.5)) - 0.25) < 1e-3, "−6 dB and half way through the fade")
        #expect(abs(envelope.level(at: Time(seconds: 1.5)) - 0.25) < 1e-3, "−6 dB and half way through the crossfade")
        #expect(envelope.level(at: Time(seconds: 2.1)) == 0, "silent after the crossfade")
        #expect(envelope.span == TimeRange(start: .zero, end: Time(seconds: 2)))
    }

    @Test func previewAndExportMatchWithCrossfadesAndFades() async throws {
        var (state, sources, left, right) = try await cutTone(at: 1.2)
        state.updateClip(left.id) { $0.fadeIn = AudioFade(duration: Time(seconds: 0.3), curve: .logarithmic) }
        state.updateClip(right.id) { $0.fadeOut = AudioFade(duration: Time(seconds: 0.4), curve: .equalPower); $0.gainDB = 3 }
        _ = state.addCrossfade(between: left.id, and: right.id, duration: Time(seconds: 0.5), curve: .equalPower)
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AudioGraphFormat.format, maximumFrameCount: 4096)
        let renderer = AudioRenderer(engine: engine)
        renderer.start(state, at: .zero, hostTime: nil)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var preview: [Float] = []
        while preview.count < 144_000 {
            #expect(try engine.renderOfflineWhenReady(4096, to: buffer) == .success)
            preview += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        renderer.stop()
        engine.stop()
        let exported = try await AudioTestKit.render(state, sources: sources, seconds: 3).left
        var worst: Float = 0
        for i in 0..<144_000 { worst = max(worst, abs(preview[i] - exported[i])) }
        #expect(worst < 1e-5, "preview vs export: \(worst)")
    }
}
