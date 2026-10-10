import AVFoundation
import os

/// Audio for one clip near the playhead, decoded into memory for the scrub head.
nonisolated struct ScrubSource: Sendable {
    let clipID: UUID
    /// Clip span on the timeline, in seconds.
    let timelineStart: Double
    let timelineEnd: Double
    /// Source time (seconds) at `timelineStart`, and source seconds per timeline second.
    let sourceStart: Double
    let speed: Double
    /// Source time of the first sample in `channels`.
    let bufferStart: Double
    let sampleRate: Double
    /// One or two channels of samples.
    let channels: [[Float]]
    let gainLeft: Float
    let gainRight: Float

    func covers(sourceRange: ClosedRange<Double>) -> Bool {
        let bufferEnd = bufferStart + Double(channels.first?.count ?? 0) / sampleRate
        return sourceRange.lowerBound >= bufferStart && sourceRange.upperBound <= bufferEnd
    }
}

/// State shared with the audio thread.
nonisolated struct ScrubHeadState: Sendable {
    var sources: [ScrubSource] = []
    /// Where the playhead is (timeline seconds) and where audio is being read from.
    var target: Double = 0
    var head: Double = 0
    /// Previous read position while crossfading to a new one.
    var fadingHead: Double = 0
    var crossfadeRemaining = 0
    var gain: Float = 0
    /// Samples rendered since the playhead last moved.
    var idleSamples = 0
    var isActive = false
}

nonisolated final class ScrubShared: @unchecked Sendable {
    let lock = OSAllocatedUnfairLock(initialState: ScrubHeadState())
}

/// Constant-pitch scrubbing, as in most editors: while the playhead moves, audio plays
/// at normal speed from the playhead. When the playhead pulls away (dragging faster or
/// slower than real time) the read position jumps to it with a short crossfade. When
/// the playhead stops, the sound fades out. Pitch never bends and nothing overlaps
/// except the 10 ms crossfades. Rendered sample by sample in an `AVAudioSourceNode`.
final class AudioScrubber {
    let node: AVAudioSourceNode
    private let shared = ScrubShared()
    private var buffers: [UUID: ScrubSource] = [:]

    /// How far around the playhead (in timeline seconds) audio is kept decoded.
    nonisolated private static let window = 3.0

    init(sampleRate: Double) {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        node = AVAudioSourceNode(format: format, renderBlock: Self.makeRenderBlock(shared, sampleRate: sampleRate))
    }

    /// Moves the playhead the scrub head follows, loading audio around it as needed.
    func move(to time: Time, in state: ProjectState) {
        let target = time.seconds
        let sources = makeSources(around: target, in: state)
        shared.lock.withLock { s in
            s.sources = sources
            if !s.isActive || s.gain < 1e-3 {
                // Starting from silence: begin right at the playhead.
                s.head = target
                s.crossfadeRemaining = 0
            }
            s.target = target
            s.idleSamples = 0
            s.isActive = true
        }
    }

    /// Lets the head come to rest; it fades out on its own.
    func stop() {
        shared.lock.withLock { s in
            s.isActive = false
        }
    }

    private func makeSources(around time: Double, in state: ProjectState) -> [ScrubSource] {
        var result: [ScrubSource] = []
        let window = (time - Self.window)...(time + Self.window)
        for trackIndex in state.trackIndices(of: .audio) {
            for clip in state.tracks[trackIndex].clips {
                let start = clip.start.seconds, end = clip.end.seconds
                guard end > window.lowerBound, start < window.upperBound,
                      state.isClipActive(clip, onTrack: trackIndex),
                      let media = state.mediaItem(clip.mediaID),
                      let url = AudioSourceCache.shared.readableURL(for: media)
                else { continue }

                // Source span needed for the window, clipped to the clip.
                let from = clip.sourceStart.seconds + (max(window.lowerBound, start) - start) * clip.speed
                let to = clip.sourceStart.seconds + (min(window.upperBound, end) - start) * clip.speed
                let needed = from...max(from, to)

                var source = buffers[clip.id]
                if source == nil || !(source!.covers(sourceRange: needed)) || source!.speed != clip.speed {
                    source = Self.load(url, clip: clip, around: needed, margin: Self.window * clip.speed)
                }
                guard let loaded = source else { continue }
                // Timing, volume and pan can change without reloading samples.
                let pan = clip.pan.clamped(to: -1...1)
                let refreshed = ScrubSource(
                    clipID: clip.id, timelineStart: start, timelineEnd: end,
                    sourceStart: clip.sourceStart.seconds, speed: clip.speed,
                    bufferStart: loaded.bufferStart, sampleRate: loaded.sampleRate, channels: loaded.channels,
                    gainLeft: Float(clip.volume * min(1, 1 - pan)), gainRight: Float(clip.volume * min(1, 1 + pan))
                )
                buffers[clip.id] = refreshed
                result.append(refreshed)
            }
        }
        // Forget clips far from the playhead.
        let kept = Set(result.map(\.clipID))
        buffers = buffers.filter { kept.contains($0.key) }
        return result
    }

    private static func load(_ url: URL, clip: Clip, around range: ClosedRange<Double>, margin: Double) -> ScrubSource? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let rate = format.sampleRate
        let first = AVAudioFramePosition(max(0, (range.lowerBound - margin) * rate))
        let last = min(file.length, AVAudioFramePosition((range.upperBound + margin) * rate))
        guard last > first, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(last - first)) else { return nil }
        file.framePosition = first
        do { try file.read(into: pcm, frameCount: AVAudioFrameCount(last - first)) } catch { return nil }
        guard let data = pcm.floatChannelData else { return nil }
        let frames = Int(pcm.frameLength)
        let channels = (0..<min(Int(format.channelCount), 2)).map { Array(UnsafeBufferPointer(start: data[$0], count: frames)) }
        return ScrubSource(clipID: clip.id, timelineStart: 0, timelineEnd: 0, sourceStart: 0, speed: clip.speed,
                           bufferStart: Double(first) / rate, sampleRate: rate, channels: channels,
                           gainLeft: 1, gainRight: 1)
    }

    /// The render block runs on the audio thread. It's built in a nonisolated context
    /// so it doesn't inherit main-actor isolation.
    nonisolated private static func makeRenderBlock(_ shared: ScrubShared, sampleRate: Double) -> AVAudioSourceNodeRenderBlock {
        let step = 1 / sampleRate
        // Re-sync to the playhead once the read position is this far from it.
        let resync = 0.08
        let crossfadeLength = Int(sampleRate * 0.01)
        // Fade out once the playhead has been still for this long.
        let idleLimit = Int(sampleRate * 0.12)
        let envelope = Float(1 - exp(-1 / (sampleRate * 0.01)))

        @inline(__always)
        func read(_ sources: [ScrubSource], at time: Double) -> (Float, Float) {
            var l: Float = 0, r: Float = 0
            for source in sources where time >= source.timelineStart && time < source.timelineEnd {
                let sourceTime = source.sourceStart + (time - source.timelineStart) * source.speed
                let position = (sourceTime - source.bufferStart) * source.sampleRate
                let index = Int(position)
                let first = source.channels[0]
                guard index >= 0, index + 1 < first.count else { continue }
                let fraction = Float(position - Double(index))
                let a = first[index] + (first[index + 1] - first[index]) * fraction
                var b = a
                if source.channels.count > 1 {
                    let second = source.channels[1]
                    b = second[index] + (second[index + 1] - second[index]) * fraction
                }
                l += a * source.gainLeft
                r += b * source.gainRight
            }
            return (l, r)
        }

        return { isSilence, _, frameCount, bufferList in
            let output = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let leftData = output[0].mData else { return noErr }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = output.count > 1 ? output[1].mData!.assumingMemoryBound(to: Float.self) : left
            let frames = Int(frameCount)

            // The output pointers belong to this render call; the unchecked variant lets
            // the closure use them (it runs synchronously, on this thread).
            let rendered = shared.lock.withLockIfAvailableUnchecked { s -> Bool in
                guard s.isActive || s.gain > 1e-4 else { return false }
                for i in 0..<frames {
                    s.idleSamples += 1
                    if s.crossfadeRemaining == 0 && abs(s.target - s.head) > resync {
                        s.fadingHead = s.head
                        s.head = s.target
                        s.crossfadeRemaining = crossfadeLength
                    }
                    let wanted: Float = s.isActive && s.idleSamples < idleLimit ? 1 : 0
                    s.gain += (wanted - s.gain) * envelope

                    var (l, r) = s.gain > 1e-4 ? read(s.sources, at: s.head) : (0, 0)
                    if s.crossfadeRemaining > 0 {
                        // Equal-gain crossfade from the old read position to the new one.
                        let w = Float(s.crossfadeRemaining) / Float(crossfadeLength)
                        let (ol, or) = read(s.sources, at: s.fadingHead)
                        l = l * (1 - w) + ol * w
                        r = r * (1 - w) + or * w
                        s.fadingHead += step
                        s.crossfadeRemaining -= 1
                    }
                    s.head += step
                    left[i] = l * s.gain
                    right[i] = r * s.gain
                }
                return true
            } ?? false

            if !rendered {
                for buffer in output { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                isSilence.pointee = true
            }
            return noErr
        }
    }
}
