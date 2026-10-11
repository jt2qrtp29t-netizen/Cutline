import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct AudioSpeedTests {
    /// The tone's frequency over a stretch of the render, by counting zero crossings.
    private func frequency(_ samples: [Float], seconds range: ClosedRange<Double>) -> Double {
        let a = Int(range.lowerBound * 48_000), b = min(samples.count, Int(range.upperBound * 48_000))
        var crossings = 0
        for i in (a + 1)..<b where (samples[i - 1] < 0) != (samples[i] < 0) { crossings += 1 }
        return Double(crossings) / 2 / (Double(b - a) / 48_000)
    }

    /// Sets a clip's speed curve the way the editor does (same source, length from the curve).
    private func retime(_ state: inout ProjectState, speed: Double = 1, ramp: [Double]? = nil, preservesPitch: Bool) {
        let track = AudioTestKit.audioTrack(state)
        var clip = state.tracks[track].clips[0]
        let source = clip.sourceDuration
        clip.preservesPitch = preservesPitch
        clip.speed = speed
        if let ramp {
            let last = clip.duration.seconds
            clip.animation.keyframes[.speed] = ramp.enumerated().map {
                Keyframe(time: Time(seconds: last * Double($0.offset) / Double(ramp.count - 1)), value: $0.element)
            }
        }
        clip.refitDuration(toSource: source)
        state.tracks[track].clips[0] = clip
    }

    @Test func constantSpeedWithPitchKeptIsUnchanged() throws {
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        clip.speed = 2
        #expect(!RetimedAudio.needsRendering(clip), "plays live through the time-pitch unit, as before")
        clip.preservesPitch = false
        #expect(RetimedAudio.needsRendering(clip))
        clip.preservesPitch = true
        clip.animation.keyframes[.speed] = [Keyframe(time: .zero, value: 1), Keyframe(time: Time(seconds: 1), value: 2)]
        #expect(RetimedAudio.needsRendering(clip))
    }

    @Test func pitchIsKeptOrFollowsSpeed() async throws {
        let url = try AudioTestKit.tone(seconds: 8, frequency: 440, amplitude: 0.5, sameInBoth: true)
        let (base, sources) = try await AudioTestKit.project([url])

        // Tape at a constant 200%: an octave up, half as long.
        var tape = base
        retime(&tape, speed: 2, preservesPitch: false)
        #expect(AudioTestKit.firstClip(tape).duration == Time(seconds: 4))
        let tapeRender = try await AudioTestKit.render(tape, sources: sources, seconds: 3)
        #expect(abs(frequency(tapeRender.left, seconds: 0.5...2.5) - 880) < 6)

        // Ramp 100% → 200% with the pitch kept: 440 Hz all the way.
        var kept = base
        retime(&kept, ramp: [1, 2], preservesPitch: true)
        let keptClip = AudioTestKit.firstClip(kept)
        #expect(abs(keptClip.duration.seconds - 8 / 1.5) < 1e-3)
        let keptRender = try await AudioTestKit.render(kept, sources: sources, seconds: keptClip.duration.seconds)
        for window in [0.3...0.8, 2.4...2.9, 4.4...4.9] {
            #expect(abs(frequency(keptRender.left, seconds: window) - 440) < 10, "\(window)")
        }

        // The same ramp tape-style: the pitch follows the speed moment by moment.
        var ramped = base
        retime(&ramped, ramp: [1, 2], preservesPitch: false)
        let clip = AudioTestKit.firstClip(ramped)
        let render = try await AudioTestKit.render(ramped, sources: sources, seconds: clip.duration.seconds)
        for t in [0.5, 2.5, 4.5] {
            let expected = 440 * clip.speed(at: Time(seconds: t))
            #expect(abs(frequency(render.left, seconds: (t - 0.1)...(t + 0.1)) - expected) < 12, "at \(t) s: \(expected) Hz")
        }

        // Semitones and cents go on top: +12 semitones on the kept-pitch ramp is 880 Hz.
        var shifted = kept
        shifted.tracks[AudioTestKit.audioTrack(kept)].clips[0].pitchSemitones = 12
        let shiftedRender = try await AudioTestKit.render(shifted, sources: sources, seconds: 3)
        #expect(abs(frequency(shiftedRender.left, seconds: 0.5...2.5) - 880) < 15)
    }

    /// Bursts in the source land where the picture shows those source moments.
    @Test func soundFollowsTheSameCurveAsThePicture() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clicks-\(UUID()).wav")
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            ])
            let frames = AVAudioFrameCount(48_000 * 8)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                let t = Double(i) / 48_000
                // 20 ms bursts of 1 kHz at each whole second.
                let inBurst = t >= 1 && t - t.rounded(.down) < 0.02
                let v = Float(inBurst ? 0.8 * sin(2 * .pi * 1_000 * t) : 0)
                buffer.floatChannelData![0][i] = v
                buffer.floatChannelData![1][i] = v
            }
            try file.write(from: buffer)
        }
        let (base, sources) = try await AudioTestKit.project([url])
        for preservesPitch in [false, true] {
            var state = base
            retime(&state, ramp: [0.5, 2, 1], preservesPitch: preservesPitch)
            let clip = AudioTestKit.firstClip(state)
            let render = try await AudioTestKit.render(state, sources: sources, seconds: clip.duration.seconds)
            for second in 1...6 {
                let expected = clip.remap.offset(forSourceSeconds: Double(second))
                guard expected < clip.duration.seconds - 0.1 else { continue }
                let from = Int((expected - 0.15) * 48_000), to = Int((expected + 0.15) * 48_000)
                let onset = (from..<to).first { abs(render.left[$0]) > 0.2 }.map { Double($0) / 48_000 }
                let error = abs((onset ?? -1) - expected)
                #expect(error < (preservesPitch ? 0.012 : 0.002), "burst \(second) (pitch kept: \(preservesPitch)): \(onset ?? -1) vs \(expected)")
            }
        }
    }

    @Test func fadesStayInTimelineTimeAtAnySpeed() async throws {
        let url = try AudioTestKit.tone(seconds: 8, frequency: 300, amplitude: 0.5, sameInBoth: true)
        let (base, sources) = try await AudioTestKit.project([url])
        func faded(_ state: ProjectState) -> ProjectState {
            var s = state
            let track = AudioTestKit.audioTrack(s)
            s.tracks[track].clips[0].fadeIn = AudioFade(duration: Time(seconds: 1), curve: .linear)
            return s
        }
        let plain = try await AudioTestKit.render(faded(base), sources: sources, seconds: 1.5)
        for preservesPitch in [false, true] {
            var state = base
            retime(&state, ramp: [2, 0.5], preservesPitch: preservesPitch)
            let render = try await AudioTestKit.render(faded(state), sources: sources, seconds: 1.5)
            for t in [0.25, 0.5, 0.75, 1.25] {
                let a = plain.rms(seconds: (t - 0.05)...(t + 0.05)).left, b = render.rms(seconds: (t - 0.05)...(t + 0.05)).left
                #expect(abs(a - b) < 0.02, "at \(t) s: \(a) vs \(b)")
            }
        }
    }

    @Test func rampsDontClickAndAFlatCurveIsTheSource() async throws {
        let url = try AudioTestKit.tone(seconds: 6, frequency: 440, amplitude: 0.5, sameInBoth: true)
        let (base, sources) = try await AudioTestKit.project([url])
        // A steep ramp tape-style: the waveform stays smooth (no jumps between samples).
        var state = base
        retime(&state, ramp: [0.25, 4], preservesPitch: false)
        let clip = AudioTestKit.firstClip(state)
        let render = try await AudioTestKit.render(state, sources: sources, seconds: clip.duration.seconds - 0.05)
        var worst = 0.0, worstAt = 0
        // From 10 ms in: the test tone itself starts abruptly at full slope, which any
        // band-limited reading rings at for a few samples.
        for i in 480..<render.left.count {
            let speed = clip.speed(at: Time(seconds: Double(i) / 48_000))
            // A sine's largest step between samples, at the frequency it has here.
            let limit = 0.5 * 2 * .pi * 440 * speed / 48_000
            let r = Double(abs(render.left[i] - render.left[i - 1])) / limit
            if r > worst { worst = r; worstAt = i }
        }
        #expect(worst < 1.1, "largest step against a clean sine's: \(worst) at sample \(worstAt)")

        // Unlocked with End = Start (a flat curve at 100%): the source exactly.
        var flat = base
        retime(&flat, ramp: [1, 1], preservesPitch: true)
        let flatRender = try await AudioTestKit.render(flat, sources: sources, seconds: 3)
        let original = try AudioTestKit.samples(of: url)
        var diff: Float = 0
        for i in 0..<(48_000 * 3) { diff = max(diff, abs(flatRender.left[i] - original.left[i])) }
        #expect(diff < 1e-4, "\(diff)")
    }

    /// Playback (rendered in the background) and export (rendered with the snapshot) use the same file.
    @Test func playbackAndExportShareTheRender() async throws {
        let url = try AudioTestKit.tone(seconds: 4, sameInBoth: true)
        var (state, sources) = try await AudioTestKit.project([url])
        retime(&state, ramp: [1, 3], preservesPitch: true)
        let clip = AudioTestKit.firstClip(state)
        let source = try #require(sources[clip.mediaID])
        // Rendered off the main thread, as export does.
        let (exported, again) = try await Task.detached {
            let exported = try RetimedAudio.prepare(clip, source: source)
            let again = try RetimedAudio.render(clip, source: source.url)
            return (exported, Array(UnsafeBufferPointer(start: again.floatChannelData![0], count: Int(again.frameLength))))
        }.value
        #expect(RetimedAudioCenter.shared.ready(clip, source: source)?.url == exported.url)
        let saved = try AudioTestKit.samples(of: exported.url)
        #expect(again == saved.left, "deterministic")
    }
}
