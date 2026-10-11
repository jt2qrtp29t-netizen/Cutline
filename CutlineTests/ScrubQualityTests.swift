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
            let block = AVAudioFrameCount(rate * gap)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block))
            _ = try engine.renderOfflineWhenReady(block, to: buffer)
            samples += UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
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
    }
}
