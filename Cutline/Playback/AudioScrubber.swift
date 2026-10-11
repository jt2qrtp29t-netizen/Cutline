import AVFoundation

/// One clip's sound near the playhead, decoded into memory so its clip node can read
/// it at the scrub head (at normal speed, constant pitch).
nonisolated struct ScrubSource: Sendable {
    let clipID: UUID
    /// The clip's span on the timeline, in samples.
    let clipStart: Int64
    let clipEnd: Int64
    /// Source time (seconds) at the clip's start, and the clip's speed curve.
    let sourceStart: Double
    let remap: TimeRemap
    /// Source time of the first decoded sample.
    let bufferStart: Double
    let left: [Float]
    let right: [Float]

    var bufferEnd: Double { bufferStart + Double(left.count) / AudioGraphFormat.sampleRate }

    func covers(_ range: ClosedRange<Double>) -> Bool {
        range.lowerBound >= bufferStart && range.upperBound <= bufferEnd
    }

    /// The source's sound at a timeline sample (silence outside the clip or the buffer).
    func sample(atTimeline s: Int64) -> (Float, Float) {
        guard s >= clipStart, s < clipEnd else { return (0, 0) }
        let sourceTime = sourceStart + remap.sourceSeconds(at: Double(s - clipStart) / AudioGraphFormat.sampleRate)
        let position = (sourceTime - bufferStart) * AudioGraphFormat.sampleRate
        let index = Int(position)
        guard index >= 0, index + 1 < left.count else { return (0, 0) }
        let f = Float(position - Double(index))
        return (left[index] + (left[index + 1] - left[index]) * f,
                right[index] + (right[index + 1] - right[index]) * f)
    }

    /// The same samples for a clip whose timing or speed changed.
    func retimed(for clip: Clip, id: UUID) -> ScrubSource {
        ScrubSource(clipID: id, clipStart: AudioGraphFormat.sample(of: clip.start), clipEnd: AudioGraphFormat.sample(of: clip.end),
                    sourceStart: clip.sourceStart.seconds, remap: clip.remap, bufferStart: bufferStart, left: left, right: right)
    }
}

/// Decodes and keeps the audio around the playhead for scrubbing, per clip.
final class ScrubSourceLoader {
    private var buffers: [UUID: ScrubSource] = [:]
    /// Buffers no longer needed, kept a few seconds before they're released here: the
    /// audio thread may still hold them in a clip node's settings, and it must never be
    /// the one to free megabytes of samples (that can make the sound drop out).
    private var retired: [(until: ContinuousClock.Instant, source: ScrubSource)] = []

    /// How far around the playhead (in timeline seconds) audio is kept decoded.
    static let window = 3.0

    /// Sources for the audible clips near `time` (decoding more as the playhead moves).
    func sources(around time: Time, in state: ProjectState) -> [ScrubSource] {
        let center = time.seconds
        let window = (center - Self.window)...(center + Self.window)
        var result: [ScrubSource] = []
        for trackIndex in state.trackIndices(of: .audio) {
            let track = state.tracks[trackIndex]
            for original in track.clips {
                // Scrub across crossfades too: the clip as it sounds, widened to its span.
                let clip = ClipEnvelope(original, track: track, isActive: true, monoSource: false).playbackClip(original)
                let start = clip.start.seconds, end = clip.end.seconds
                guard end > window.lowerBound, start < window.upperBound,
                      let media = state.mediaItem(clip.mediaID),
                      let url = AudioSourceCache.shared.readableURL(for: media) else { continue }
                // The source span the window needs, within the clip.
                let from = clip.sourceTime(at: Time(seconds: max(window.lowerBound, start))).seconds
                let to = clip.sourceTime(at: Time(seconds: min(window.upperBound, end))).seconds
                let fastest = clip.remap.extremes(over: clip.duration.seconds).upperBound
                var source = buffers[original.id]
                if source == nil || !source!.covers(from...max(from, to)) {
                    source = Self.load(url, clip: clip, around: from...max(from, to), margin: Self.window * fastest)
                }
                guard let loaded = source?.retimed(for: clip, id: original.id) else { continue }
                if let previous = buffers[original.id], previous.left.count != loaded.left.count || previous.bufferStart != loaded.bufferStart {
                    retired.append((ContinuousClock.now + .seconds(3), previous))
                }
                buffers[original.id] = loaded
                result.append(loaded)
            }
        }
        let kept = Set(result.map(\.clipID))
        let now = ContinuousClock.now
        retired.removeAll { $0.until < now }
        for (id, source) in buffers where !kept.contains(id) { retired.append((now + .seconds(3), source)) }
        buffers = buffers.filter { kept.contains($0.key) }
        return result
    }

    private static func load(_ url: URL, clip: Clip, around range: ClosedRange<Double>, margin: Double) -> ScrubSource? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        let first = AVAudioFramePosition(max(0, (range.lowerBound - margin) * rate))
        let last = min(file.length, AVAudioFramePosition((range.upperBound + margin) * rate))
        guard last > first,
              let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(last - first)) else { return nil }
        file.framePosition = first
        do { try file.read(into: pcm, frameCount: AVAudioFrameCount(last - first)) } catch { return nil }
        guard let data = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength)
        let left = Array(UnsafeBufferPointer(start: data[0], count: frames))
        let right = pcm.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: frames)) : left
        return ScrubSource(clipID: clip.id, clipStart: 0, clipEnd: 0, sourceStart: 0, remap: clip.remap,
                           bufferStart: Double(first) / rate, left: left, right: right)
    }
}
