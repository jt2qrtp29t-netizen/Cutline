import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct LoudnessDuckingTests {
    private func lufs(_ dbfs: Double) -> Double { pow(10, dbfs / 20) }

    /// Feeds a file through a fresh meter.
    private func meter(_ url: URL) throws -> LoudnessMeter {
        let samples = try AudioTestKit.samples(of: url)
        let meter = LoudnessMeter()
        for i in samples.left.indices { meter.process(Double(samples.left[i]), Double(samples.right[i])) }
        return meter
    }

    /// EBU Tech 3341: a stereo 1 kHz sine at −23 dBFS reads −23.0 LUFS momentary,
    /// short-term and integrated.
    @Test func theMeterReadsTheEBUReferenceTone() async throws {
        let url = try AudioTestKit.tone(seconds: 5, frequency: 1000, amplitude: lufs(-23), sameInBoth: true)
        let m = try meter(url)
        #expect(abs(m.momentary - -23) < 0.1, "momentary \(m.momentary)")
        #expect(abs(m.shortTerm - -23) < 0.1, "short-term \(m.shortTerm)")
        #expect(abs(m.integrated - -23) < 0.1, "integrated \(m.integrated)")
        let quieter = try meter(try AudioTestKit.tone(seconds: 5, frequency: 1000, amplitude: lufs(-33), sameInBoth: true))
        #expect(abs(quieter.integrated - -33) < 0.1)

        // Measured through the graph, as Normalize does, it's the same.
        let (state, sources) = try await AudioTestKit.project([url])
        let measured = try await Task.detached {
            try LoudnessAnalyzer.measure(state, range: TimeRange(start: .zero, end: Time(seconds: 5)), sources: sources, ducking: nil)
        }.value
        #expect(abs(measured.integrated - -23) < 0.1)
    }

    @Test func silenceDoesntPullTheIntegratedLoudnessDown() async throws {
        // 5 s of −23 LUFS, then 5 s of silence: the absolute gate (−70 LUFS) ignores the silence.
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 5, frequency: 1000, amplitude: lufs(-23), sameInBoth: true)])
        state.tracks[AudioTestKit.audioTrack(state)].clips[0].duration = Time(seconds: 5)
        let (frozen, frozenSources) = (state, sources)
        let measured = try await Task.detached {
            try LoudnessAnalyzer.measure(frozen, range: TimeRange(start: .zero, end: Time(seconds: 10)), sources: frozenSources, ducking: nil)
        }.value
        #expect(abs(measured.integrated - -23) < 0.2, "\(measured.integrated)")
    }

    @Test func truePeakFindsPeaksBetweenSamples() throws {
        // A quarter-rate sine at 45°: every sample is ±0.707 (−3 dBFS) but the wave peaks at 1.0.
        let url = try AudioTestKit.tone(seconds: 1, frequency: 12_000, amplitude: 1, sameInBoth: true, phase: .pi / 4)
        let samples = try AudioTestKit.samples(of: url)
        #expect(abs(Double(samples.left.map(abs).max() ?? 0) - 0.7071) < 0.001)
        let m = try meter(url)
        #expect(abs(AudioLevel.db(fromLinear: m.truePeak)) < 0.4, "true peak \(AudioLevel.db(fromLinear: m.truePeak)) dBTP")
        let plain = try meter(try AudioTestKit.tone(seconds: 1, frequency: 1000, amplitude: 0.5, sameInBoth: true))
        #expect(abs(AudioLevel.db(fromLinear: plain.truePeak) - -6.02) < 0.2)
    }

    @Test func normalizeHitsTheTargetForAClipATrackAndTheProject() async throws {
        let quiet = try AudioTestKit.tone(seconds: 2.5, frequency: 440, amplitude: 0.05)
        let loud = try AudioTestKit.tone(seconds: 2.5, frequency: 660, amplitude: 0.4)
        var (state, sources) = try await AudioTestKit.project([quiet], audioTracks: 2)
        let (second, secondSources) = try await AudioTestKit.project([loud])
        state.media += second.media
        sources.merge(secondSources) { a, _ in a }
        var music = second.tracks[AudioTestKit.audioTrack(second)].clips[0]
        music.id = UUID()
        state.tracks[AudioTestKit.audioTrack(state, 1)].clips = [music]
        // The second track has a compressor, so its level doesn't follow gain one to one.
        state.tracks[AudioTestKit.audioTrack(state, 1)].audio.effects = [AudioEffect(kind: .compressor, values: ["threshold": -20, "ratio": 4, "makeup": 3])]
        let clip = AudioTestKit.firstClip(state)
        let trackID = state.tracks[AudioTestKit.audioTrack(state, 1)].id
        let allSources = sources

        func measure(_ s: ProjectState, _ target: NormalizeTarget) async throws -> Double {
            let (measured, range) = try #require(LoudnessAnalyzer.measurementState(s, for: target))
            return try await Task.detached {
                let ducking = try DuckingAnalyzer.curve(for: s, sources: allSources)
                return try LoudnessAnalyzer.measure(measured, range: range, sources: allSources, ducking: ducking).integrated
            }.value
        }

        for (target, lufs) in [(NormalizeTarget.clip(clip.id), -14.0), (.track(trackID), -16), (.project, -14)] {
            let snapshot = state
            let result = try await Task.detached { try Normalizer.normalize(snapshot, target, to: lufs, sources: allSources) }.value
            state.applyNormalizeGain(result.gainChange, to: target)
            let after = try await measure(state, target)
            #expect(abs(after - lufs) < 0.5, "\(target) normalized to \(after) LUFS")
        }
        // The gain stays visible and editable where Normalize put it.
        #expect(state.clip(clip.id)!.gainDB > 10, "the quiet clip got a clip gain boost")
        #expect(state.tracks[AudioTestKit.audioTrack(state, 1)].audio.volumeDB != 0)
    }

    @Test func normalizingIsOneUndoStep() async throws {
        let (state, _) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 3, amplitude: 0.05)])
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        editor.store.undoManager = undo
        let clip = AudioTestKit.firstClip(state)
        editor.normalize(.clip(clip.id))
        let deadline = Date().addingTimeInterval(20)
        while editor.audioActivity != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(editor.state.clip(clip.id)!.gainDB > 5, "\(editor.audioMessage ?? "")")
        #expect(editor.audioMessage?.contains("−14.0 LUFS") == true)
        undo.undo()
        #expect(editor.state.clip(clip.id)!.gainDB == 0)
    }

    /// A game tone with a voice that talks from 2 s to 4 s.
    private func duckingProject() async throws -> (ProjectState, [UUID: PreparedAudio], UUID, UUID) {
        let game = try AudioTestKit.tone(seconds: 7, frequency: 300, amplitude: 0.3)
        let voice = try AudioTestKit.tone(seconds: 3, frequency: 1200, amplitude: 0.3)
        var (state, sources) = try await AudioTestKit.project([game], audioTracks: 2)
        let (v, vSources) = try await AudioTestKit.project([voice])
        state.media += v.media
        sources.merge(vSources) { a, _ in a }
        var talk = v.tracks[AudioTestKit.audioTrack(v)].clips[0]
        talk.start = Time(seconds: 2)
        talk.duration = Time(seconds: 2)
        let voiceTrack = AudioTestKit.audioTrack(state, 1)
        state.tracks[voiceTrack].clips = [talk]
        let gameID = state.tracks[AudioTestKit.audioTrack(state)].id, voiceID = state.tracks[voiceTrack].id
        state.audio.ducking = DuckingSettings(voiceTrackID: voiceID, gameTrackID: gameID)
        return (state, sources, voiceID, gameID)
    }

    @Test func duckingLowersTheGameWhileTheVoiceTalksAndReleases() async throws {
        let (base, sources, voiceID, _) = try await duckingProject()
        var state = base
        let settings = try #require(state.audio.ducking)
        // Hear only the game track (the voice still drives the ducking).
        state.tracks[try #require(state.tracks.firstIndex { $0.id == voiceID })].isMuted = true
        let snapshot = state
        let curve = try await Task.detached { try DuckingAnalyzer.curve(for: snapshot, sources: sources) }.value
        func render() async throws -> AudioTestKit.Rendered {
            try await Task.detached {
                var out = AudioTestKit.Rendered()
                try AudioGraph.render(snapshot, range: TimeRange(start: .zero, end: Time(seconds: 7)), sources: sources, ducking: curve) { b in
                    out.left += UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength))
                    out.right += UnsafeBufferPointer(start: b.floatChannelData![1], count: Int(b.frameLength))
                }
                return out
            }.value
        }
        let out = try await render()
        let reference = out.rms(seconds: 0.5...1.5).left
        func level(_ at: Double) -> Double { 20 * log10(out.rms(seconds: (at - 0.02)...(at + 0.02)).left / reference) }
        #expect(abs(level(3)) - abs(settings.amountDB) < 0.3 && level(3) < -11.5, "down by the amount while talking: \(level(3))")
        #expect(level(2.0) < -10, "already down when the voice starts (it starts early by the attack time): \(level(2.0))")
        #expect(abs(level(1.7)) < 0.1, "not before that")
        let releaseMid = 4 + DuckingSettings.holdMS / 1000 + settings.releaseMS / 2000
        #expect(abs(level(releaseMid) - settings.amountDB / 2) < 1.5, "half way back half way through the release: \(level(releaseMid))")
        #expect(abs(level(6)) < 0.1, "back up after")
        #expect(out.largestStep < 0.06, "no clicks")

        // Deterministic: the same every time, and the same in preview and export.
        let again = try await render()
        #expect(again.left == out.left)
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AudioGraphFormat.format, maximumFrameCount: 4096)
        _ = try await DuckingCenter.shared.prepare(for: state)
        let renderer = AudioRenderer(engine: engine)
        renderer.start(state, at: .zero, hostTime: nil)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var preview: [Float] = []
        while preview.count < 7 * 48_000 {
            #expect(try engine.renderOfflineWhenReady(4096, to: buffer) == .success)
            preview += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        renderer.stop()
        engine.stop()
        var worst: Float = 0
        for i in 0..<out.left.count { worst = max(worst, abs(preview[i] - out.left[i])) }
        #expect(worst < 1e-5, "preview vs export: \(worst)")
    }

    @Test func deletingTheVoiceTrackResetsDuckingCleanly() async throws {
        let (state, _, voiceID, gameID) = try await duckingProject()
        let editor = EditorController(store: ProjectStore(state: state))
        editor.selectedAudioTrackID = voiceID
        #expect(editor.state.audio.ducking?.voiceTrackID == voiceID)
        // Deleting a voice clip keeps the setup (the voice just has nothing to say).
        let talk = try #require(editor.state.tracks.first { $0.id == voiceID }?.clips.first)
        editor.deleteClips([talk.id])
        #expect(editor.state.audio.ducking != nil)
        let index = try #require(editor.state.tracks.firstIndex { $0.id == voiceID })
        editor.deleteTrack(at: index)
        #expect(editor.state.audio.ducking == nil, "the setup is cleared with its track")
        #expect(editor.selectedAudioTrackID == nil, "and the track selection")
        #expect(editor.audioSettingsTrack?.id == gameID)
        // Ducking a track under itself isn't allowed.
        editor.setDucking(voice: gameID, game: gameID)
        #expect(editor.state.audio.ducking == nil)
    }

    @Test func theMasterLimiterAndSettingsSave() async throws {
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 2, amplitude: 0.5)])
        state.audio.master.volumeDB = 9
        state.audio.master.limiterEnabled = true
        state.audio.master.ceilingDB = -2
        let out = try await AudioTestKit.render(state, sources: sources, seconds: 2)
        let peak = Double((out.left + out.right).map(abs).max() ?? 0)
        #expect(peak <= AudioLevel.linear(fromDB: -2) + 1e-6, "held under the ceiling: \(peak)")

        state.audio.loudnessTarget = -16
        state.audio.ducking = DuckingSettings(voiceTrackID: UUID(), gameTrackID: UUID())
        state.audio.ducking?.amountDB = -18
        // (Ducking with unknown tracks is pruned on edits; saving keeps it as is.)
        #expect(try ProjectState.decode(state.encoded()) == state)
        var json = try #require(try JSONSerialization.jsonObject(with: state.encoded()) as? [String: Any])
        json["audio"] = nil
        let old = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.audio.loudnessTarget == -14 && old.audio.ducking == nil && !old.audio.master.limiterEnabled)
    }
}
