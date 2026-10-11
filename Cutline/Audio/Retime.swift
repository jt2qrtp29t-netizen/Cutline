import AVFoundation
import CryptoKit
import Foundation

/// The sound of a clip that changes speed (or plays tape-style), rendered ahead of time
/// in timeline time from the clip's time-remap function: sample `i` of the result is the
/// source at `clip.sourceTime(at: clip.start + i / 48 kHz)`, exactly where the picture
/// is. The speed changes smoothly sample by sample, so ramps never click. Rendering is
/// deterministic, so playback, export and every rerender sound the same; results are
/// cached on disk by what they depend on.
nonisolated enum RetimedAudio {
    /// Bumped when the algorithms change, so old renders aren't reused.
    private static let version = 1

    /// Clips whose sound needs rendering ahead of time. Constant speed with the pitch
    /// kept plays through the time-pitch unit live, exactly as before.
    static func needsRendering(_ clip: Clip) -> Bool {
        clip.hasSpeedRamp || (clip.speed != 1 && !clip.preservesPitch)
    }

    /// A name for everything the render depends on (not the clip's place on the timeline).
    static func signature(of clip: Clip, source: PreparedAudio) -> String {
        var text = "v\(version)|\(source.url.path)|\(DiskCache.stamp(for: source.url) ?? "")|\(clip.sourceStart.ticks)|\(clip.duration.ticks)"
        text += "|\(clip.speed)|\(clip.preservesPitch)"
        for frame in clip.animation.keyframes(for: .speed) {
            text += "|\(frame.time.ticks):\(frame.value):\(frame.easing)"
        }
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static var folder: URL { DiskCache.retimed.folder }

    static func url(for signature: String) -> URL {
        folder.appendingPathComponent("retimed-\(signature).caf")
    }

    /// The rendered file if it's already on disk.
    static func existing(_ clip: Clip, source: PreparedAudio) -> PreparedAudio? {
        let url = url(for: signature(of: clip, source: source))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        DiskCache.touch(url)
        return PreparedAudio(url: url, isMono: source.isMono)
    }

    /// Renders (or finds) the retimed sound of `clip` (as it plays, widened to its span):
    /// a 48 kHz stereo file as long as the clip, starting at its start.
    static func prepare(_ clip: Clip, source: PreparedAudio) throws -> PreparedAudio {
        if let existing = existing(clip, source: source) { return existing }
        let url = url(for: signature(of: clip, source: source))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rendered = try render(clip, source: source.url)
        let temporary = folder.appendingPathComponent("partial-\(UUID().uuidString).caf")
        do {
            let format = AudioGraphFormat.format
            let file = try AVAudioFile(forWriting: temporary, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: rendered)
        }
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: temporary) } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
        return PreparedAudio(url: url, isMono: source.isMono)
    }

    /// Source positions (in source samples) for each output sample, computed exactly every
    /// 16 samples and linearly between (the curve is smooth on that scale).
    static func positions(for clip: Clip, count: Int) -> [Double] {
        let rate = AudioGraphFormat.sampleRate
        let remap = clip.remap
        let base = clip.sourceStart.seconds * rate
        var result = [Double](repeating: 0, count: count)
        let step = 16
        var i = 0
        var previous = base + remap.sourceSeconds(at: 0) * rate
        while i < count {
            let j = min(i + step, count)
            let next = base + remap.sourceSeconds(at: Double(j) / rate) * rate
            let span = Double(j - i)
            for k in i..<j { result[k] = previous + (next - previous) * Double(k - i) / span }
            previous = next
            i = j
        }
        return result
    }

    static func render(_ clip: Clip, source: URL) throws -> AVAudioPCMBuffer {
        let rate = AudioGraphFormat.sampleRate
        let count = max(1, Int((clip.duration.seconds * rate).rounded()))
        let positions = positions(for: clip, count: count)
        // Read the source span the clip uses (and a margin for the filters).
        let file = try AVAudioFile(forReading: source)
        let margin = 4096.0
        let low = max(0, Int(((positions.min() ?? 0) - margin).rounded(.down)))
        let high = min(Int(file.length), Int(((positions.max() ?? 0) + margin).rounded(.up)))
        var left: [Float] = [], right: [Float] = []
        if high > low, let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(high - low)) {
            file.framePosition = AVAudioFramePosition(low)
            try file.read(into: pcm, frameCount: AVAudioFrameCount(high - low))
            let n = Int(pcm.frameLength)
            left = Array(UnsafeBufferPointer(start: pcm.floatChannelData![0], count: n))
            right = pcm.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: pcm.floatChannelData![1], count: n)) : left
        }
        let local = positions.map { $0 - Double(low) }
        let output: (left: [Float], right: [Float])
        if clip.preservesPitch {
            output = TimeStretcher.stretch(left: left, right: right, positions: local)
        } else {
            output = TapeResampler.resample(left: left, right: right, positions: local)
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: AudioGraphFormat.format, frameCapacity: AVAudioFrameCount(count)) else {
            throw ExportError.setupFailed("the retimed audio couldn’t be prepared.")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        output.left.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
        output.right.withUnsafeBufferPointer { buffer.floatChannelData![1].update(from: $0.baseAddress!, count: count) }
        return buffer
    }
}

/// Tape-style speed: the source read faster or slower, so the pitch follows the speed
/// (like a record or tape). Band-limited interpolation with a windowed-sinc kernel whose
/// cutoff follows the speed, so speeding up doesn't alias.
nonisolated enum TapeResampler {
    /// Zero crossings each side of the kernel at 100%.
    private static let zeroCrossings = 8
    private static let tableSize = 4096
    /// g(u) for u in 0…1 (the kernel is symmetric): sinc(zeroCrossings·u) × Blackman window.
    private static let table: [Double] = (0...tableSize).map { i in
        let u = Double(i) / Double(tableSize)
        let x = Double(zeroCrossings) * u
        let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
        let window = 0.42 + 0.5 * cos(.pi * u) + 0.08 * cos(2 * .pi * u)
        return sinc * window
    }

    @inline(__always) private static func kernel(_ u: Double) -> Double {
        let a = abs(u)
        guard a < 1 else { return 0 }
        let p = a * Double(tableSize)
        let i = Int(p)
        let f = p - Double(i)
        return table[i] + (table[min(i + 1, tableSize)] - table[i]) * f
    }

    static func resample(left: [Float], right: [Float], positions: [Double]) -> (left: [Float], right: [Float]) {
        let n = positions.count
        var outL = [Float](repeating: 0, count: n), outR = [Float](repeating: 0, count: n)
        guard !left.isEmpty else { return (outL, outR) }
        let last = left.count - 1
        for i in 0..<n {
            let p = positions[i]
            // Local speed: source samples per output sample.
            let previous = positions[max(i - 1, 0)], next = positions[min(i + 1, n - 1)]
            let speed = n > 1 ? abs(next - previous) / Double(min(i + 1, n - 1) - max(i - 1, 0)) : 1
            let cutoff = min(1, 1 / max(speed, 1e-6))
            let half = Double(zeroCrossings) / cutoff
            let first = Int((p - half).rounded(.up)), end = Int((p + half).rounded(.down))
            var sumL = 0.0, sumR = 0.0, weights = 0.0
            if end >= first {
                for k in first...end {
                    let w = kernel((Double(k) - p) / half)
                    // Beyond the media is silence (not left out), so edges aren't boosted.
                    if k >= 0 && k <= last {
                        sumL += w * Double(left[k])
                        sumR += w * Double(right[k])
                    }
                    weights += w
                }
            }
            // Normalized by the kernel's sum, so a constant stays exactly constant.
            if weights > 1e-9 {
                outL[i] = Float(sumL / weights)
                outR[i] = Float(sumR / weights)
            }
        }
        return (outL, outR)
    }
}

/// Speed with the pitch kept: WSOLA (waveform-similarity overlap-add). Windows of the
/// source are laid down every `hop` output samples at the source position the curve
/// gives there, each nudged (within ±`tolerance`) to the spot most like the natural
/// continuation of the previous window, so waveforms join up without phasing. Hann
/// windows at 50% overlap add up to exactly 1, so at 100% the source comes out unchanged.
nonisolated enum TimeStretcher {
    static let window = 1024
    static let hop = 512
    static let tolerance = 384

    private static let hann: [Double] = (0..<window).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(window)) }

    static func stretch(left: [Float], right: [Float], positions: [Double]) -> (left: [Float], right: [Float]) {
        let n = positions.count
        var outL = [Double](repeating: 0, count: n + window), outR = [Double](repeating: 0, count: n + window)
        guard !left.isEmpty else { return ([Float](repeating: 0, count: n), [Float](repeating: 0, count: n)) }
        let mono = zip(left, right).map { Double($0) + Double($1) }
        let count = left.count

        @inline(__always) func at(_ x: [Double], _ i: Int) -> Double { i >= 0 && i < count ? x[i] : 0 }

        /// Normalized similarity of the source at `a` and `b` over a window (every `stride` samples).
        func similarity(_ a: Int, _ b: Int, stride: Int) -> Double {
            var dot = 0.0, energy = 0.0
            var k = 0
            while k < window {
                let x = at(mono, a + k), y = at(mono, b + k)
                dot += x * y
                energy += y * y
                k += stride
            }
            return energy > 1e-12 ? dot / energy.squareRoot() : 0
        }

        // Window k is centered on output sample k·hop; it covers [k·hop − window/2, k·hop + window/2).
        var previousStart: Int?
        var k = 0
        while k * hop - window / 2 < n {
            let center = min(k * hop, n - 1)
            let nominal = Int(positions[center].rounded()) - window / 2
            var start = nominal
            if let previousStart {
                let natural = previousStart + hop
                if natural != nominal {
                    // Coarse search, then refine around the best.
                    var best = nominal, bestScore = -Double.infinity
                    for d in stride(from: -tolerance, through: tolerance, by: 4) {
                        let score = similarity(natural, nominal + d, stride: 4)
                        if score > bestScore { bestScore = score; best = nominal + d }
                    }
                    let coarse = best
                    for d in -3...3 where d != 0 {
                        let score = similarity(natural, coarse + d, stride: 1)
                        if score > bestScore { bestScore = score; best = coarse + d }
                    }
                    if similarity(natural, coarse, stride: 1) >= bestScore { best = coarse }
                    start = best
                }
            }
            let outStart = k * hop - window / 2
            for i in 0..<window {
                let o = outStart + i
                guard o >= 0, o < n else { continue }
                let s = start + i
                guard s >= 0, s < count else { continue }
                outL[o] += hann[i] * Double(left[s])
                outR[o] += hann[i] * Double(right[s])
            }
            previousStart = start
            k += 1
        }
        return (outL.prefix(n).map { Float($0) }, outR.prefix(n).map { Float($0) })
    }
}

extension Notification.Name {
    /// A clip's retimed sound finished rendering (playback can pick it up).
    static let retimedAudioReady = Notification.Name("app.cutline.retimedAudioReady")
}

/// Live playback's retimed sounds: rendered in the background (as soon as a clip's speed
/// curve settles), used once they're ready.
final class RetimedAudioCenter {
    static let shared = RetimedAudioCenter()

    private var ready: [String: PreparedAudio] = [:]
    private var rendering: Set<String> = []
    /// The latest render wanted per clip while one is running (drag-heavy edits don't queue up).
    private var pending: [UUID: (Clip, PreparedAudio, String)] = [:]
    private var running: [UUID: String] = [:]

    /// The retimed sound if it's ready; otherwise starts rendering it and returns nil.
    func ready(_ clip: Clip, source: PreparedAudio) -> PreparedAudio? {
        let signature = RetimedAudio.signature(of: clip, source: source)
        if let prepared = ready[signature], FileManager.default.fileExists(atPath: prepared.url.path) { return prepared }
        if let existing = RetimedAudio.existing(clip, source: source) {
            ready[signature] = existing
            return existing
        }
        start(clip, source: source, signature: signature)
        return nil
    }

    func isRendering(_ clipID: UUID) -> Bool { running[clipID] != nil }

    /// Starts rendering every retimed audio clip in the project that isn't ready.
    func prefetch(_ state: ProjectState) {
        for index in state.trackIndices(of: .audio) {
            let track = state.tracks[index]
            for clip in track.clips where RetimedAudio.needsRendering(clip) {
                guard let media = state.mediaItem(clip.mediaID), let source = AudioSourceCache.shared.prepared(for: media) else { continue }
                let playing = ClipEnvelope(clip, track: track, isActive: true, monoSource: source.isMono).playbackClip(clip)
                _ = ready(playing, source: source)
            }
        }
    }

    private func start(_ clip: Clip, source: PreparedAudio, signature: String) {
        guard !rendering.contains(signature) else { return }
        if running[clip.id] != nil {
            pending[clip.id] = (clip, source, signature)
            return
        }
        rendering.insert(signature)
        running[clip.id] = signature
        Task {
            let prepared = try? await Task.detached(priority: .userInitiated) {
                try RetimedAudio.prepare(clip, source: source)
            }.value
            rendering.remove(signature)
            running[clip.id] = nil
            if let prepared {
                ready[signature] = prepared
                NotificationCenter.default.post(name: .retimedAudioReady, object: nil)
            }
            if let (next, nextSource, nextSignature) = pending.removeValue(forKey: clip.id), ready[nextSignature] == nil {
                start(next, source: nextSource, signature: nextSignature)
            }
            // Keep the in-memory index small; the files stay on disk.
            if ready.count > 64 { ready.removeAll() }
        }
    }
}
