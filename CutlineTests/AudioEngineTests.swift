import AVFoundation
import Foundation
import Testing
@testable import Cutline

enum AudioTestError: Error {
    case notPrepared(String)
}

/// Builds sound files and renders projects offline (no speakers) for audio tests.
@MainActor enum AudioTestKit {
    /// A sine tone file: `channels` channels (the second, if any, at 1.5× the frequency).
    static func tone(channels: AVAudioChannelCount = 2, rate: Double = 48_000, seconds: Double = 2,
                     frequency: Double = 440, amplitude: Double = 0.5, float: Bool = true, sameInBoth: Bool = false,
                     phase: Double = 0) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(channels)-\(Int(rate))-\(UUID()).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: float ? 32 : 16, AVLinearPCMIsFloatKey: float,
        ])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            let f = c == 0 || sameInBoth ? frequency : frequency * 1.5
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float(sin(2 * .pi * f * Double(i) / rate + phase) * amplitude) }
        }
        try file.write(from: buffer)
        return url
    }

    /// A project with `urls` as clips one after another on audio track A1 (more tracks if asked).
    static func project(_ urls: [URL], audioTracks: Int = 1) async throws -> (ProjectState, [UUID: PreparedAudio]) {
        var state = ProjectState(settings: .default, videoTracks: 1, audioTracks: audioTracks, textTracks: 0)
        var sources: [UUID: PreparedAudio] = [:]
        var cursor = Time.zero
        for url in urls {
            let media = try await MediaImporter.makeItem(for: url)
            state.media.append(media)
            guard let prepared = await AudioSourceCache.shared.preparedAudio(media) else {
                throw AudioTestError.notPrepared(url.lastPathComponent)
            }
            sources[media.id] = prepared
            let ids = TimelineEditing.place(media, at: cursor, onTrack: state.trackIndices(of: .audio)[0], in: &state)
            cursor = ids.compactMap { state.clip($0)?.end }.max() ?? cursor
        }
        return (state, sources)
    }

    nonisolated struct Rendered: Sendable {
        var left: [Float] = []
        var right: [Float] = []

        func rms(_ channel: [Float], _ range: Range<Int>) -> Double {
            let slice = channel[range.clamped(to: 0..<channel.count)]
            guard !slice.isEmpty else { return 0 }
            return (slice.reduce(0.0) { $0 + Double($1 * $1) } / Double(slice.count)).squareRoot()
        }

        func rms(seconds: ClosedRange<Double>) -> (left: Double, right: Double) {
            let range = Int(seconds.lowerBound * 48_000)..<Int(seconds.upperBound * 48_000)
            return (rms(left, range), rms(right, range))
        }

        /// Largest jump between neighboring samples (a click shows up as a big one).
        var largestStep: Float {
            zip(left, left.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        }
    }

    /// Renders on a background thread (as export does), never blocking the main actor
    /// that other tests share.
    static func render(_ state: ProjectState, sources: [UUID: PreparedAudio], seconds: Double, from start: Double = 0) async throws -> Rendered {
        let range = TimeRange(start: Time(seconds: start), end: Time(seconds: start + seconds))
        return try await Task.detached {
            var out = Rendered()
            try AudioGraph.render(state, range: range, sources: sources) { buffer in
                let n = Int(buffer.frameLength)
                out.left += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n)
                out.right += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: n)
            }
            return out
        }.value
    }

    static func samples(of url: URL) throws -> (left: [Float], right: [Float]) {
        let file = try AVAudioFile(forReading: url)
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: pcm)
        let n = Int(pcm.frameLength)
        let left = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: n))
        let right = pcm.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: pcm.floatChannelData![1], count: n)) : left
        return (left, right)
    }

    static func audioTrack(_ state: ProjectState, _ n: Int = 0) -> Int { state.trackIndices(of: .audio)[n] }
    static func firstClip(_ state: ProjectState) -> Clip { state.tracks[audioTrack(state)].clips[0] }
}

@MainActor struct AudioEngineTests {
    @Test func anUntouchedChainLeavesTheSamplesExactlyAsTheyAre() async throws {
        let url = try AudioTestKit.tone()
        let (state, sources) = try await AudioTestKit.project([url])
        let rendered = try await AudioTestKit.render(state, sources: sources, seconds: 1)
        let original = try AudioTestKit.samples(of: url)
        var worst: Float = 0
        for i in 0..<48_000 {
            worst = max(worst, abs(rendered.left[i] - original.left[i]), abs(rendered.right[i] - original.right[i]))
        }
        #expect(worst < 1e-6, "identity: largest difference \(worst)")
    }

    @Test func gainIsInDecibels() async throws {
        #expect(abs(AudioLevel.linear(fromDB: -6.0206) - 0.5) < 1e-4)
        #expect(abs(AudioLevel.linear(fromDB: 12) - 3.98107) < 1e-4)
        #expect(abs(AudioLevel.db(fromLinear: 2) - 6.0206) < 1e-3)
        #expect(AudioLevel.linear(fromDB: AudioLevel.silenceDB) == 0)

        let (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone()])
        let reference = try await AudioTestKit.render(state, sources: sources, seconds: 0.5).rms(seconds: 0.1...0.4)
        for (clipDB, trackDB, masterDB) in [(-6.0206, 0.0, 0.0), (0, -12, 0), (3, 3, -6.0206)] {
            var adjusted = state
            let clip = AudioTestKit.firstClip(state)
            adjusted.updateClip(clip.id) { $0.gainDB = clipDB }
            adjusted.tracks[AudioTestKit.audioTrack(state)].audio.volumeDB = trackDB
            adjusted.audio.master.volumeDB = masterDB
            let level = try await AudioTestKit.render(adjusted, sources: sources, seconds: 0.5).rms(seconds: 0.1...0.4)
            let expected = AudioLevel.linear(fromDB: clipDB + trackDB + masterDB)
            #expect(abs(level.left / reference.left - expected) < 1e-3, "\(clipDB)+\(trackDB)+\(masterDB) dB")
        }
    }

    /// Pan keeps the law clips always had: stereo sources balance, mono ones pan with
    /// constant power (measured on v3.7's engine: center −3 dB, −0.5 → 0.924 / 0.383).
    @Test func panSoundsAsItAlwaysHas() async throws {
        for (mono, pan, left, right) in [(false, 0.0, 1.0, 1.0), (false, -0.5, 1.0, 0.5), (false, 1.0, 0.0, 1.0),
                                         (true, 0.0, 0.70711, 0.70711), (true, -0.5, 0.92388, 0.38268), (true, -1.0, 1.0, 0.0)] {
            let gains = PanLaw.gains(pan: pan, monoSource: mono)
            #expect(abs(gains.left - left) < 1e-4 && abs(gains.right - right) < 1e-4, "mono \(mono) pan \(pan)")
        }
        // Rendered: a mono 44.1 kHz file (converted on the way in) and a stereo one.
        for mono in [true, false] {
            let url = try AudioTestKit.tone(channels: mono ? 1 : 2, rate: mono ? 44_100 : 48_000, float: false)
            let (state, sources) = try await AudioTestKit.project([url])
            #expect(sources.values.first?.isMono == mono)
            let center = try await AudioTestKit.render(state, sources: sources, seconds: 0.5).rms(seconds: 0.1...0.4)
            var panned = state
            panned.updateClip(AudioTestKit.firstClip(state).id) { $0.pan = -0.5; $0.volume = 1.5 }
            let level = try await AudioTestKit.render(panned, sources: sources, seconds: 0.5).rms(seconds: 0.1...0.4)
            let law = PanLaw.gains(pan: -0.5, monoSource: mono), centerLaw = PanLaw.gains(pan: 0, monoSource: mono)
            #expect(abs(level.left / center.left - 1.5 * law.left / centerLaw.left) < 2e-3)
            #expect(abs(level.right / center.right - 1.5 * law.right / centerLaw.right) < 2e-3)
        }
    }

    @Test func fadeCurvesHaveTheirShapes() async throws {
        #expect(FadeCurve.linear.gain(0.25) == 0.25)
        #expect(abs(FadeCurve.equalPower.gain(0.5) - 0.70711) < 1e-4)
        #expect(abs(FadeCurve.logarithmic.gain(0.5) - log10(5.5)) < 1e-9)
        for curve in FadeCurve.allCases { #expect(curve.gain(0) == 0 && abs(curve.gain(1) - 1) < 1e-12) }
        // An equal-power crossfade keeps the power constant; a linear one the amplitude.
        for u in stride(from: 0.0, through: 1, by: 0.1) {
            let a = FadeCurve.equalPower.gain(u), b = FadeCurve.equalPower.gain(1 - u)
            #expect(abs(a * a + b * b - 1) < 1e-9)
            #expect(abs(FadeCurve.linear.gain(u) + FadeCurve.linear.gain(1 - u) - 1) < 1e-9)
        }

        // Rendered: a one-second fade-in reaches the curve's level at each point.
        let (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 2)])
        let flat = try await AudioTestKit.render(state, sources: sources, seconds: 1.2)
        for curve in FadeCurve.allCases {
            var faded = state
            faded.updateClip(AudioTestKit.firstClip(state).id) { $0.fadeIn = AudioFade(duration: Time(seconds: 1), curve: curve) }
            let out = try await AudioTestKit.render(faded, sources: sources, seconds: 1.2)
            for u in [0.25, 0.5, 0.75] {
                let i = Int(u * 48_000)
                let window = (i - 240)..<(i + 240)
                let ratio = out.rms(out.left, window) / flat.rms(flat.left, window)
                #expect(abs(ratio - curve.gain(u)) < 0.01, "\(curve) at \(u): \(ratio)")
            }
            #expect(out.largestStep < 0.05, "no clicks")
        }
    }

    @Test func soloOverridesMuteAndSeveralTracksCanSolo() async throws {
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone()], audioTracks: 3)
        let clip = AudioTestKit.firstClip(state)
        let a1 = AudioTestKit.audioTrack(state, 0), a2 = AudioTestKit.audioTrack(state, 1), a3 = AudioTestKit.audioTrack(state, 2)
        var copy = clip
        copy.id = UUID()
        state.tracks[a2].clips = [copy]
        copy.id = UUID()
        state.tracks[a3].clips = [copy]

        state.tracks[a1].isMuted = true
        state.tracks[a1].isSoloed = true
        state.tracks[a2].isSoloed = true
        #expect(state.isTrackActive(a1), "solo overrides mute")
        #expect(state.isTrackActive(a2) && !state.isTrackActive(a3), "several solos play; the rest don't")
        let soloed = try await AudioTestKit.render(state, sources: sources, seconds: 0.5).rms(seconds: 0.1...0.4)
        state.tracks[a1].isSoloed = false
        let one = try await AudioTestKit.render(state, sources: sources, seconds: 0.5).rms(seconds: 0.1...0.4)
        #expect(abs(soloed.left / one.left - 2) < 1e-3, "two soloed tracks sound, then one")
    }

    @Test func cuttingThroughKeyframesAndFadesChangesNothing() async throws {
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 2)])
        let clip = AudioTestKit.firstClip(state)
        state.updateClip(clip.id) { c in
            c.animation.setKeyframe(.volume, at: .zero, value: 0.2)
            c.animation.setKeyframe(.volume, at: Time(seconds: 1.6), value: 1.2)
            c.animation.keyframes[.volume]![0].easing = .easeInOut
            c.animation.setKeyframe(.pan, at: Time(seconds: 0.2), value: -0.6)
            c.animation.setKeyframe(.pan, at: Time(seconds: 1.8), value: 0.6)
            c.fadeIn = AudioFade(duration: Time(seconds: 0.3), curve: .logarithmic)
            c.fadeOut = AudioFade(duration: Time(seconds: 0.4), curve: .linear)
        }
        let whole = try await AudioTestKit.render(state, sources: sources, seconds: 2)
        var cut = state
        let created = TimelineEditing.blade(at: Time(seconds: 0.77), clips: [clip.id], in: &cut)
        #expect(created.count == 1)
        let left = try #require(cut.clip(clip.id)), right = try #require(cut.clip(created[0]))
        #expect(left.fadeIn == state.clip(clip.id)!.fadeIn && !left.fadeOut.isActive)
        #expect(right.fadeOut == state.clip(clip.id)!.fadeOut && !right.fadeIn.isActive)
        let halves = try await AudioTestKit.render(cut, sources: sources, seconds: 2)
        var worst: Float = 0
        for i in 0..<min(whole.left.count, halves.left.count) {
            worst = max(worst, abs(whole.left[i] - halves.left[i]), abs(whole.right[i] - halves.right[i]))
        }
        #expect(worst < 1e-4, "no click or jump at the cut: largest difference \(worst)")
    }

    @Test func faderChangesGlideInsteadOfClicking() async throws {
        let (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(frequency: 100, amplitude: 0.8)])
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AudioGraphFormat.format, maximumFrameCount: 4096)
        let graph = AudioGraph(engine: engine)
        graph.prepareVoices(state, from: .zero) { sources[$0.id] }
        try engine.start()
        graph.start(at: .zero, hostTime: nil)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var samples: [Float] = []
        func render() throws {
            #expect(try engine.renderOfflineWhenReady(1024, to: buffer) == .success)
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        }
        for _ in 0..<4 { try render() }
        // Pull the fader from 0 to −40 dB and mute another moment later.
        var quieter = state
        quieter.tracks[AudioTestKit.audioTrack(state)].audio.volumeDB = -40
        graph.update(quieter)
        for _ in 0..<4 { try render() }
        quieter.tracks[AudioTestKit.audioTrack(state)].isMuted = true
        graph.update(quieter)
        for _ in 0..<4 { try render() }
        graph.removeVoices()
        engine.stop()

        let steps = zip(samples, samples.dropFirst()).map { abs($1 - $0) }
        // A 100 Hz tone at 0.8 moves at most ~0.0105 per sample; a click would jump far more.
        #expect((steps.max() ?? 1) < 0.012, "largest step \(steps.max() ?? 0)")
        #expect(samples.suffix(512).allSatisfy { abs($0) < 1e-6 }, "muted in the end")
        let afterChange = samples[4096 + 512..<4096 + 1024].map { abs($0) }.max() ?? 1
        #expect(afterChange < 0.8 * 0.011, "the new level is reached within a few milliseconds")
    }

    @Test func savingAndLoadingKeepsEverythingAndOldProjectsLoad() throws {
        var state = ProjectState()
        let a1 = state.trackIndices(of: .audio)[0]
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "Voice", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        clip.gainDB = -3.5
        clip.fadeIn = AudioFade(duration: Time(seconds: 0.5), curve: .logarithmic)
        clip.fadeOut = AudioFade(duration: Time(seconds: 1), curve: .linear)
        clip.animation.setKeyframe(.volume, at: Time(seconds: 1), value: 0.5)
        state.tracks[a1].clips = [clip]
        state.tracks[a1].audio.volumeDB = -6
        state.tracks[a1].audio.pan = 0.25
        state.tracks[a1].audio.keyframes["volume"] = [Keyframe(time: Time(seconds: 2), value: -12, easing: .easeIn)]
        state.audio.master.volumeDB = -1
        #expect(try ProjectState.decode(state.encoded()) == state)

        // A project saved before the Audio tab: no audio keys anywhere.
        var json = try #require(try JSONSerialization.jsonObject(with: state.encoded()) as? [String: Any])
        json["audio"] = nil
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        for t in tracks.indices {
            tracks[t]["audio"] = nil
            var clips = tracks[t]["clips"] as? [[String: Any]] ?? []
            for c in clips.indices { clips[c]["gainDB"] = nil; clips[c]["fadeIn"] = nil; clips[c]["fadeOut"] = nil }
            tracks[t]["clips"] = clips
        }
        json["tracks"] = tracks
        let old = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        let oldClip = try #require(old.clip(clip.id))
        #expect(oldClip.gainDB == 0 && !oldClip.fadeIn.isActive && !oldClip.fadeOut.isActive)
        #expect(old.tracks[a1].audio == .neutral && old.audio == ProjectAudio())
        #expect(oldClip.animation == clip.animation, "everything else as saved")
    }

    /// What plays (the real-time renderer, run offline here) and what's exported are the same samples.
    @Test func previewAndExportMatch() async throws {
        var (state, _) = try await AudioTestKit.project([try AudioTestKit.tone(channels: 1, rate: 44_100, seconds: 2)])
        let clip = AudioTestKit.firstClip(state)
        state.updateClip(clip.id) { c in
            c.gainDB = -2
            c.pan = 0.3
            c.fadeIn = AudioFade(duration: Time(seconds: 0.2), curve: .equalPower)
            c.animation.setKeyframe(.volume, at: Time(seconds: 0.5), value: 1.4)
            c.animation.setKeyframe(.volume, at: Time(seconds: 1.5), value: 0.4)
        }
        state.tracks[AudioTestKit.audioTrack(state)].audio.volumeDB = -4
        state.tracks[AudioTestKit.audioTrack(state)].audio.keyframes["pan"] = [Keyframe(time: .zero, value: -0.5), Keyframe(time: Time(seconds: 2), value: 0.5)]

        // Preview: the playback renderer on an offline engine.
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AudioGraphFormat.format, maximumFrameCount: 4096)
        let renderer = AudioRenderer(engine: engine)
        renderer.start(state, at: .zero, hostTime: nil)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var preview: [Float] = []
        while preview.count < 96_000 {
            #expect(try engine.renderOfflineWhenReady(4096, to: buffer) == .success)
            preview += UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength))
        }
        renderer.stop()
        engine.stop()

        // Export: the export mixer's file.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mix-\(UUID()).caf")
        let snapshot = ExportSnapshot(state: state, urls: [:], range: TimeRange(start: .zero, end: Time(seconds: 2)), settings: ExportSettings())
        try await ExportAudioMixer.render(snapshot, to: url, cancellation: ExportCancellation())
        let exported = try AudioTestKit.samples(of: url).right
        var worst: Float = 0
        for i in 0..<96_000 { worst = max(worst, abs(preview[i] - exported[i])) }
        #expect(worst < 1e-5, "preview vs export: largest difference \(worst)")
    }

    /// One real-time check that sound reaches the output device.
    @Test func realPlaybackReachesTheOutput() async throws {
        let (state, _) = try await AudioTestKit.project([try AudioTestKit.tone(amplitude: 0.01)])
        let renderer = AudioRenderer()
        renderer.isMuted = false
        let start = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05)
        renderer.start(state, at: .zero, hostTime: start)
        guard renderer.engine.isRunning else {
            Issue.record("no output device to play to")
            return
        }
        _ = renderer.graph.masterMeter.read()
        try await Task.sleep(for: .milliseconds(400))
        let level = renderer.graph.masterMeter.read()
        renderer.stop()
        try await Task.sleep(for: .milliseconds(60))
        #expect(level.left > 0.005, "the master meter saw the tone while playing in real time: \(level)")
        #expect(renderer.engine.outputNode.lastRenderTime != nil, "the output device rendered")
    }
}
