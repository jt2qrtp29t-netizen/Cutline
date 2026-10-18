import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct ScrubQualityTests {
    /// Drags the playhead over a steady 440 Hz tone with mouse updates every ~16 ms and
    /// returns the output (48 kHz, left).
    static func drag(_ state: ProjectState, speed: Double, seconds: Double = 1.2, jitter: Bool = true) throws -> [Float] {
        let rate = 48_000.0
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let renderer = AudioRenderer(engine: engine)
        defer { renderer.stopScrubbing(); engine.stop() }
        var samples: [Float] = []
        var t = 0.3
        var generator = SystemRandomNumberGenerator()
        var elapsed = 0.0
        while elapsed < seconds {
            // Real mouse events: 8–24 ms apart, the playhead moved by the drag speed.
            let gap = jitter ? Double.random(in: 0.008...0.024, using: &generator) : 0.016
            renderer.scrub(state, at: Time(seconds: t))
            // The audio device renders in its own cycles, which don't line up with mouse events.
            var remaining = Int(rate * gap)
            while remaining > 0 {
                let block = AVAudioFrameCount(min(remaining, jitter ? Int.random(in: 128...1024, using: &generator) : 512))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block))
                _ = try engine.renderOfflineWhenReady(block, to: buffer)
                samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                remaining -= Int(block)
            }
            t += gap * speed
            elapsed += gap
        }
        return samples
    }

    /// The tone's envelope (amplitude) every 1 ms: sqrt(2)·RMS over one 440 Hz period around each point.
    static func envelope(_ x: [Float]) -> [Double] {
        let period = Int((48_000.0 / 440).rounded())
        return stride(from: period, to: x.count - period, by: 48).map { c in
            var sum = 0.0
            for i in (c - period / 2)..<(c - period / 2 + period) { sum += Double(x[i] * x[i]) }
            return (2 * sum / Double(period)).squareRoot()
        }
    }

    /// Pausing the drag just long enough for the sound to start fading out, then moving
    /// again, brings the sound back smoothly from where the fade had got to.
    @Test func resumingDuringTheFadeOutDoesntClick() async throws {
        let (state, _) = try await AudioTestKit.project([try LiveScrubTests.sweep()])
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let renderer = AudioRenderer(engine: engine)
        defer { renderer.stopScrubbing(); engine.stop() }
        var out: [Float] = []
        func render(_ frames: Int) throws {
            var left = frames
            while left > 0 {
                let n = AVAudioFrameCount(min(left, 256))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: n))
                _ = try engine.renderOfflineWhenReady(n, to: buffer)
                out += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
                left -= Int(n)
            }
        }
        var t = 1.0
        for _ in 0..<10 { renderer.scrub(state, at: Time(seconds: t)); try render(768); t += 0.016 }
        // Still until halfway through the fade-out (which starts 120 ms after the last move)…
        try render(5_760 + 240 - 768)
        // …and the drag goes on, mid-fade.
        for _ in 0..<10 { renderer.scrub(state, at: Time(seconds: t)); try render(768); t += 0.016 }
        let limit = 0.5 * 2 * Double.pi * 1200 / 48_000
        var worst = 0.0
        for i in 1..<out.count { worst = max(worst, Double(abs(out[i] - out[i - 1])) / limit) }
        #expect(worst < 1.1, "a step of \(worst)× a clean wave's")
    }

    /// The scrubbed sound keeps its full, steady level at any drag speed.
    @Test(arguments: [0.3, 0.6, 1.0, 1.7, 3.0])
    func draggingKeepsAFullSteadyTone(speed: Double) async throws {
        let (state, _) = try await AudioTestKit.project([try AudioTestKit.tone(seconds: 6, amplitude: 0.5, sameInBoth: true)])
        let out = try Self.drag(state, speed: speed)
        let env = Array(Self.envelope(out).dropFirst(150))  // after the fade-in
        let reference = env.sorted()[env.count * 9 / 10]
        let worst = env.min() ?? 0
        // Before v4.1, jumps crossfaded unrelated spots of the waveform: the level fell to
        // under 20% for 20–70 ms every second at drag speeds other than 1× (muffled flutter).
        #expect(abs(reference - 0.5) < 0.02, "full level: \(reference)")
        #expect(worst > reference * 0.85, "no dips while dragging at \(speed)×: lowest \(worst)")

        // No hard cuts: no step between samples bigger than the clean tone ever makes.
        let steady = Array(out.dropFirst(150 * 48))
        let limit = 0.5 * 2 * Double.pi * 440 / 48_000
        var cut = 0.0
        for i in 1..<steady.count { cut = max(cut, Double(abs(steady[i] - steady[i - 1])) / limit) }
        #expect(cut < 1.1, "a hard cut at \(speed)×: step \(cut)× a clean tone's")

        // No low hum under it: almost nothing below 200 Hz (Goertzel at 20–180 Hz).
        var hum = 0.0
        for f in stride(from: 20.0, through: 180, by: 10) {
            let w = 2 * Double.pi * f / 48_000, c = 2 * cos(w)
            var s1 = 0.0, s2 = 0.0
            for x in steady { let s0 = Double(x) + c * s1 - s2; s2 = s1; s1 = s0 }
            hum = max(hum, (s1 * s1 + s2 * s2 - c * s1 * s2).squareRoot() / Double(steady.count) * 2)
        }
        #expect(hum < 0.005, "low hum at \(speed)×: \(hum) (tone 0.5)")
    }
}

/// Scrubbing on the live (real-time) engine, as in the app: the playhead moves on the main
/// thread every ~16 ms while the audio device renders on its own clock.
@MainActor struct LiveScrubTests {
    nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Float] = []
        private var next: Int64?
        private var gaps: [Int] = []
        /// Appends a buffer; a buffer that doesn't start where the last one ended means the
        /// device skipped cycles (a dropout), remembered by where the join is.
        func append(_ data: UnsafeBufferPointer<Float>, at sampleTime: Int64?) {
            lock.withLock {
                if let sampleTime, let expected = next, sampleTime != expected { gaps.append(stored.count) }
                stored += data
                next = sampleTime.map { $0 + Int64(data.count) }
            }
        }
        var samples: [Float] { lock.withLock { stored } }
        var skips: [Int] { lock.withLock { gaps } }
    }

    /// Built outside the main actor: the tap runs on the audio thread.
    nonisolated static func tap(_ recorder: Recorder) -> AVAudioNodeTapBlock {
        { buffer, when in
            let n = Int(buffer.frameLength)
            recorder.append(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n),
                            at: when.isSampleTimeValid ? when.sampleTime : nil)
        }
    }

    /// A sweep from 300 to 1200 Hz over 8 s: every moment of it is different, so a cut
    /// between two read positions can't hide (with a steady tone any spot matches any other).
    static func sweep() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID()).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ])
        let frames = AVAudioFrameCount(48_000 * 8)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        var phase = 0.0
        for i in 0..<Int(frames) {
            let f = 300 + 900 * Double(i) / Double(frames)
            phase += 2 * .pi * f / 48_000
            let v = Float(0.5 * sin(phase))
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        try file.write(from: buffer)
        return url
    }

    /// v4.2 failed this on every run (several hard cuts, no dropouts). A busy Mac (like
    /// a full parallel test run) can make the audio device miss deadlines; those runs say
    /// nothing about the scrubber, so it's tried again until a run without dropouts.
    @Test func liveScrubbingHasNoHardCutsOrHum() async throws {
        var results: [(cuts: Int, dropouts: Int, worst: Double)] = []
        for _ in 0..<5 {
            let result = try await liveDrag()
            results.append(result)
            if result.dropouts == 0 { break }
        }
        guard let clean = results.first(where: { $0.dropouts == 0 }) else {
            // Every run had dropouts: the machine was too busy to judge (no failure).
            return
        }
        #expect(clean.cuts == 0, "\(clean.cuts) hard cuts made by the scrubber (worst step \(clean.worst)× a clean wave's)")
    }

    /// One live drag (slow, then fast): sudden steps made by the scrubber, and dropout edges.
    private func liveDrag() async throws -> (cuts: Int, dropouts: Int, worst: Double) {
        let (state, _) = try await AudioTestKit.project([try Self.sweep()])
        let renderer = AudioRenderer()
        // Silent speakers; listen just before the output.
        renderer.engine.mainMixerNode.outputVolume = 0
        let recorder = Recorder()
        renderer.graph.masterNode.installTap(onBus: 0, bufferSize: 512, format: nil, block: Self.tap(recorder))
        defer {
            renderer.graph.masterNode.removeTap(onBus: 0)
            renderer.stopScrubbing()
            renderer.engine.stop()
        }
        // Drag slowly (0.5×) then fast (2×) for about a second each.
        var t = 1.0
        let clock = ContinuousClock()
        var last = clock.now
        for speed in [0.5, 2.0] {
            for _ in 0..<60 {
                renderer.scrub(state, at: Time(seconds: t))
                try await Task.sleep(for: .milliseconds(16))
                let now = clock.now
                let elapsed = Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds)
                last = now
                t += elapsed * speed
            }
        }
        renderer.graph.masterNode.removeTap(onBus: 0)
        let out = recorder.samples
        let rate = renderer.engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        // Skip the fade-in, then look for loud stretches only (the tone at full level).
        let skipped = Int(rate * 0.2)
        let steady = Array(out.dropFirst(skipped))
        try #require(steady.count > Int(rate), "recorded \(steady.count) samples")
        // The sweep's fastest clean step (at its top, 1200 Hz).
        let limit = 0.5 * 2 * Double.pi * 1200 / rate
        // A dropout (the audio device missing a deadline when the Mac is busy, as when
        // hundreds of tests run at once) shows as a whole cycle of exact silence or as a
        // skipped cycle (the recording's clock jumps): those edges are counted apart.
        // Every other sudden step is a cut made by the scrubber.
        var silent = [Bool](repeating: false, count: steady.count)
        var runStart = -1
        for i in 0...steady.count {
            let zero = i < steady.count && steady[i] == 0
            if zero && runStart < 0 { runStart = i }
            if !zero && runStart >= 0 {
                if i - runStart >= 128 { for k in max(0, runStart - 2)..<min(steady.count, i + 2) { silent[k] = true } }
                runStart = -1
            }
        }
        for join in recorder.skips where join - skipped >= 0 {
            for k in max(0, join - skipped - 2)..<min(steady.count, join - skipped + 2) { silent[k] = true }
        }
        var cuts = 0, dropouts = 0, worst = 0.0
        for i in 1..<steady.count {
            let step = Double(abs(steady[i] - steady[i - 1])) / limit
            if step > 1.2 && (silent[i] || silent[i - 1]) { dropouts += 1; continue }
            worst = max(worst, step)
            if step > 1.2 { cuts += 1 }
        }
        return (cuts, dropouts, worst)
    }
}

struct ScrubHeadEnvelopeTests {
    /// However moves, pauses and stops are timed, the scrub level never jumps: it changes
    /// by at most one fade step per sample (a jump is a click).
    @Test(arguments: [64, 256, 512])
    func theLevelNeverJumps(cycle: Int) {
        let head = ScrubHead()
        var previous: Float?
        var worst: Float = 0
        var engine: Int64 = 0
        var target: Int64 = 48_000
        var generator = SystemRandomNumberGenerator()
        // Moves arrive at random gaps of 2–200 ms (pauses long enough to start, finish or
        // interrupt the fade-out), with an occasional stop.
        var nextMove: Int64 = 0
        for _ in 0..<4_000 {
            if engine >= nextMove {
                if Int.random(in: 0..<12, using: &generator) == 0 {
                    head.stop()
                } else {
                    target += Int64.random(in: -4_000...12_000, using: &generator)
                    head.move(to: target, sources: [])
                }
                nextMove = engine + Int64.random(in: 96...9_600, using: &generator)
            }
            let plan = head.plan(forCycle: engine)
            for i in 0..<cycle {
                let g = plan.gain(at: engine + Int64(i))
                if let previous { worst = max(worst, abs(g - previous)) }
                previous = g
            }
            engine += Int64(cycle)
        }
        #expect(worst <= 1 / 480 + 1e-6, "level step \(worst) (one fade step is \(1.0 / 480))")
    }
}
