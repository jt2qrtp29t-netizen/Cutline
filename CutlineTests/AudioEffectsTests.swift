import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct AudioEffectsTests {
    /// Level change in dB between two RMS values.
    private func db(_ a: Double, _ b: Double) -> Double { 20 * log10(max(a, 1e-12) / max(b, 1e-12)) }

    /// A tone on A1 with the given chain, rendered; plus the same tone rendered dry.
    private func run(_ effects: [AudioEffect], frequency: Double = 1000, amplitude: Double = 0.5, seconds: Double = 1.5,
                     keyframes: [String: [Keyframe]] = [:]) async throws -> (wet: AudioTestKit.Rendered, dry: AudioTestKit.Rendered) {
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: seconds + 0.5, frequency: frequency, amplitude: amplitude)])
        let dry = try await AudioTestKit.render(state, sources: sources, seconds: seconds)
        state.tracks[AudioTestKit.audioTrack(state)].audio.effects = effects
        state.tracks[AudioTestKit.audioTrack(state)].audio.keyframes = keyframes
        return (try await AudioTestKit.render(state, sources: sources, seconds: seconds), dry)
    }

    private func gain(_ result: (wet: AudioTestKit.Rendered, dry: AudioTestKit.Rendered), _ window: ClosedRange<Double> = 0.8...1.3) -> Double {
        db(result.wet.rms(seconds: window).left, result.dry.rms(seconds: window).left)
    }

    @Test func neutralEffectsLeaveTheSoundUntouched() async throws {
        let chain = [AudioEffect(kind: .equalizer),
                     AudioEffect(kind: .gate, values: ["range": 0]),
                     AudioEffect(kind: .noiseReduction, values: ["amount": 0]),
                     AudioEffect(kind: .limiter, values: ["ceiling": 0]),
                     AudioEffect(kind: .compressor, values: ["threshold": 0, "knee": 0])]
        let (wet, dry) = try await run(chain)
        var worst: Float = 0
        for i in 0..<dry.left.count { worst = max(worst, abs(wet.left[i] - dry.left[i]), abs(wet.right[i] - dry.right[i])) }
        #expect(worst < 1e-6, "a chain at neutral settings is transparent: \(worst)")
    }

    @Test func theEqualizerCutsAndBoostsWhereItShould() async throws {
        let bell = AudioEffect(kind: .equalizer, values: ["mid1Freq": 1000, "mid1Gain": 12, "mid1Q": 1])
        #expect(abs(gain(try await run([bell], frequency: 1000)) - 12) < 0.3, "+12 dB at the center")
        #expect(abs(gain(try await run([bell], frequency: 8000))) < 1, "far away it hardly changes")
        let lowCut = AudioEffect(kind: .equalizer, values: ["lowCut": 500])
        #expect(gain(try await run([lowCut], frequency: 100)) < -40, "24 dB per octave below the cut")
        #expect(abs(gain(try await run([lowCut], frequency: 4000))) < 0.2)
        let highCut = AudioEffect(kind: .equalizer, values: ["highCut": 3400])
        #expect(gain(try await run([highCut], frequency: 9000)) < -30)
        let shelf = AudioEffect(kind: .equalizer, values: ["highFreq": 4000, "highGain": -6])
        #expect(abs(gain(try await run([shelf], frequency: 14_000)) - -6) < 0.5)
    }

    @Test func theCompressorSettlesOnItsCurve() async throws {
        // A −6 dBFS peak tone, threshold −20 dB, 4:1: settles at −20 + 14 / 4 = −16.5 dB.
        let comp = AudioEffect(kind: .compressor, values: ["threshold": -20, "ratio": 4, "attack": 1, "release": 50, "knee": 0, "makeup": 0])
        let result = try await run([comp])
        #expect(abs(gain(result) - (-16.5 - -6.02)) < 0.6, "\(gain(result)) dB")
        var withMakeup = comp
        withMakeup.values["makeup"] = 6
        #expect(abs(gain(try await run([withMakeup])) - (-16.5 + 6 - -6.02)) < 0.6)
        #expect(CompressorDSP.gainComputer(-30, threshold: -20, ratio: 4, knee: 0) == 0)
        #expect(abs(CompressorDSP.gainComputer(0, threshold: -20, ratio: 4, knee: 0) - -15) < 1e-9)
    }

    @Test func theGateClosesOnQuietSoundAndOpensForLoudOnes() async throws {
        let gate = AudioEffect(kind: .gate, values: ["threshold": -40, "range": -40, "attack": 1, "hold": 20, "release": 30])
        #expect(gain(try await run([gate], amplitude: 0.005)) < -38, "a −46 dBFS tone is held down")
        #expect(abs(gain(try await run([gate], amplitude: 0.5))) < 0.05, "a loud one passes")
        #expect(try await run([gate], amplitude: 0.005).wet.largestStep < 0.01)
    }

    @Test func theDeEsserOnlyTouchesTheHighEnd() async throws {
        let deEsser = AudioEffect(kind: .deEsser, values: ["frequency": 5000, "threshold": -30, "amount": 8])
        let sibilant = gain(try await run([deEsser], frequency: 9000, amplitude: 0.3))
        #expect(sibilant < -6 && sibilant > -9, "a loud 9 kHz tone is turned down: \(sibilant) dB")
        #expect(abs(gain(try await run([deEsser], frequency: 250, amplitude: 0.3))) < 0.3, "a low tone isn't")
    }

    @Test func theLimiterHoldsTheCeiling() async throws {
        let limiter = AudioEffect(kind: .limiter, values: ["ceiling": -1, "release": 80])
        let (wet, _) = try await run([AudioEffect(kind: .equalizer, values: ["lowGain": 12, "lowFreq": 5000]), limiter], frequency: 300)
        let peak = (wet.left + wet.right).map { abs($0) }.max() ?? 0
        #expect(Double(peak) <= AudioLevel.linear(fromDB: -1) + 1e-6, "peak \(peak)")
        #expect(Double(peak) > AudioLevel.linear(fromDB: -1.5), "and doesn't squash far below it")
    }

    @Test func noiseReductionTurnsDownQuietBands() async throws {
        let nr = AudioEffect(kind: .noiseReduction, values: ["threshold": -50, "amount": 12, "release": 50])
        #expect(abs(gain(try await run([nr], frequency: 3000, amplitude: 0.001)) - -12) < 0.5, "quiet hiss drops by the amount")
        #expect(abs(gain(try await run([nr], frequency: 3000, amplitude: 0.3))) < 0.1, "a clear sound is left alone")
    }

    @Test func bypassAndOrderWork() async throws {
        var boost = AudioEffect(kind: .equalizer, values: ["mid1Freq": 1000, "mid1Gain": 12])
        boost.isBypassed = true
        #expect(abs(gain(try await run([boost]))) < 1e-4, "a bypassed effect passes the sound")

        // EQ boost into a limiter is held at the ceiling; the other way round it isn't.
        boost.isBypassed = false
        let limiter = AudioEffect(kind: .limiter, values: ["ceiling": -6])
        let limited = try await run([boost, limiter]).wet
        let boosted = try await run([limiter, boost]).wet
        #expect((limited.left.map(abs).max() ?? 0) < (boosted.left.map(abs).max() ?? 0) * 0.6)

        // Bypassing while it plays glides; no click.
        let (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(frequency: 100, amplitude: 0.4)])
        var chained = state
        chained.tracks[AudioTestKit.audioTrack(state)].audio.effects = [AudioEffect(kind: .equalizer, values: ["lowFreq": 300, "lowGain": 12])]
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AudioGraphFormat.format, maximumFrameCount: 4096)
        let graph = AudioGraph(engine: engine)
        graph.prepareVoices(chained, from: .zero) { sources[$0.id] }
        try engine.start()
        graph.start(at: .zero, hostTime: nil)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var samples: [Float] = []
        for k in 0..<8 {
            if k == 4 {
                chained.tracks[AudioTestKit.audioTrack(state)].audio.effects[0].isBypassed = true
                graph.update(chained)
            }
            #expect(try engine.renderOfflineWhenReady(1024, to: buffer) == .success)
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        graph.removeVoices()
        engine.stop()
        let largestStep = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(largestStep < 0.04, "largest step \(largestStep)")
    }

    @Test func effectParametersFollowTheirKeyframes() async throws {
        let eq = AudioEffect(kind: .equalizer, values: ["mid1Freq": 1000, "mid1Q": 1])
        let key = eq.keyframeKey(try #require(AudioEffectKind.equalizer.parameter("mid1Gain")))
        let frames = [Keyframe(time: Time(seconds: 0.5), value: 0), Keyframe(time: Time(seconds: 1.5), value: 12)]
        let result = try await run([eq], seconds: 2, keyframes: [key: frames])
        #expect(abs(gain(result, 0.3...0.45)) < 0.2, "before the keyframes: 0 dB")
        #expect(abs(gain(result, 0.98...1.02) - 6) < 0.7, "half way: about +6 dB")
        #expect(abs(gain(result, 1.6...1.9) - 12) < 0.3, "after: +12 dB")
        // A 1 kHz tone at amplitude 2 (+12 dB) moves up to 0.26 per sample; a click would be far more.
        #expect(result.wet.largestStep < 0.3)
    }

    @Test func presetsWriteEditableEffectsAndEverythingSaves() async throws {
        var state = ProjectState()
        let a1 = state.trackIndices(of: .audio)[0]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        func grouped(_ body: () -> Void) { undo.beginUndoGrouping(); body(); undo.endUndoGrouping() }
        let id = state.tracks[a1].id

        grouped { editor.applyPreset(.voice, to: id) }
        var audio = editor.state.tracks[a1].audio
        #expect(audio.presetName == "Voice (commentary)")
        #expect(audio.effects.map(\.kind) == AudioPreset.voice.effects.map(\.kind))
        #expect(Set(audio.effects.map(\.id)).isDisjoint(with: AudioPreset.voice.effects.map(\.id)), "each track gets its own effects")
        let comp = try #require(audio.effects.first { $0.kind == .compressor })
        let threshold = try #require(AudioEffectKind.compressor.parameter("threshold"))

        // Presets set ordinary values: editable, one undo step per drag.
        grouped {
            for v in stride(from: -22.0, through: -30, by: -1) { editor.adjustTrackParameter(.effect(comp, threshold, track: id), to: v) }
            editor.endAudioAdjustment("Change Threshold")
        }
        #expect(editor.state.tracks[a1].audio.effects.first { $0.id == comp.id }?.values["threshold"] == -30)
        undo.undo()
        #expect(editor.state.tracks[a1].audio.effects.first { $0.id == comp.id }?.values["threshold"] == -22)

        // Keyframes, bypass, order, removal.
        editor.playback.seek(to: Time(seconds: 1))
        grouped { editor.toggleTrackKeyframe(.effect(comp, threshold, track: id)) }
        #expect(editor.trackKeyframes(.effect(comp, threshold, track: id)).count == 1)
        grouped { editor.setBypassed(true, effect: comp.id, in: id) }
        grouped { editor.moveEffect(comp.id, by: -1, in: id) }
        audio = editor.state.tracks[a1].audio
        #expect(audio.effects.firstIndex { $0.id == comp.id } == 2 && audio.effects.first { $0.id == comp.id }?.isBypassed == true)
        #expect(try ProjectState.decode(editor.state.encoded()) == editor.state, "chains, presets and keyframes save and load")
        grouped { editor.removeEffect(comp.id, from: id) }
        #expect(editor.state.tracks[a1].audio.keyframes.isEmpty, "removing an effect removes its keyframes")
        #expect(editor.state.tracks[a1].audio.effects.count == AudioPreset.voice.effects.count - 1)

        // A project from before effects existed loads with empty chains.
        var json = try #require(try JSONSerialization.jsonObject(with: editor.state.encoded()) as? [String: Any])
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        for i in tracks.indices { tracks[i]["audio"] = nil }
        json["tracks"] = tracks
        state = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        #expect(state.tracks[a1].audio.effects.isEmpty && state.tracks[a1].audio.presetName == nil)
    }

    @Test func previewAndExportMatchWithTheVoicePreset() async throws {
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 2, frequency: 220, amplitude: 0.6)])
        let a1 = AudioTestKit.audioTrack(state)
        state.tracks[a1].audio.effects = AudioPreset.voice.makeEffects()
        let eq = state.tracks[a1].audio.effects[2]
        state.tracks[a1].audio.keyframes[eq.keyframeKey(try #require(AudioEffectKind.equalizer.parameter("mid2Gain")))] =
            [Keyframe(time: .zero, value: -6), Keyframe(time: Time(seconds: 2), value: 6)]
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AudioGraphFormat.format, maximumFrameCount: 4096)
        let renderer = AudioRenderer(engine: engine)
        renderer.start(state, at: .zero, hostTime: nil)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var preview: [Float] = []
        while preview.count < 96_000 {
            #expect(try engine.renderOfflineWhenReady(4096, to: buffer) == .success)
            preview += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        renderer.stop()
        engine.stop()
        let exported = try await AudioTestKit.render(state, sources: sources, seconds: 2).left
        var worst: Float = 0
        for i in 0..<96_000 { worst = max(worst, abs(preview[i] - exported[i])) }
        #expect(worst < 1e-5, "preview vs export: \(worst)")
    }
}
