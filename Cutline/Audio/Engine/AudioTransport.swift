import AVFoundation
import os

/// Where the timeline is, for every node of one audio graph: it maps each render
/// cycle's timestamp to a timeline sample (48 kHz), so clip fades, keyframes and
/// faders are evaluated at exactly the sample they belong to.
nonisolated final class AudioTransport: @unchecked Sendable {
    enum Mode: Sendable, Equatable {
        /// Not playing; values are evaluated at this timeline sample.
        case stopped(at: Int64)
        /// Real-time playback: the sample at `timelineSample` reaches the output at `hostTime`.
        case realtime(hostTime: UInt64, timelineSample: Int64)
        /// Offline rendering (export, analysis): engine sample `engineSample` plays timeline sample `timelineSample`.
        case offline(timelineSample: Int64, engineSample: Int64)
        /// Scrubbing while paused: the read head follows `ScrubPlan`.
        case scrub(ScrubPlan)
    }

    private let state = OSAllocatedUnfairLock(initialState: (mode: Mode.stopped(at: 0), generation: 0))

    func set(_ mode: Mode) {
        state.withLock { s in
            s.mode = mode
            s.generation += 1
        }
    }

    var mode: Mode { state.withLock { $0.mode } }

    /// For the render thread: the current mode, without ever waiting for the lock.
    func peek() -> (mode: Mode, generation: Int)? {
        state.withLockIfAvailable { $0 }
    }

    nonisolated static let hostTicksPerSecond: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }()
}

/// How one node turns its render timestamps into timeline samples. Kept by each node
/// on the render thread.
nonisolated struct TransportClock {
    private var mode = AudioTransport.Mode.stopped(at: 0)
    private var generation = -1

    enum Position {
        /// Playing: the timeline sample of the first frame in this cycle.
        case running(Int64)
        /// Stopped at a timeline sample.
        case stopped(Int64)
        case scrubbing(ScrubPlan, engineSample: Int64)
    }

    mutating func position(_ transport: AudioTransport, _ timestamp: AudioTimeStamp) -> Position {
        if let current = transport.peek(), current.generation != generation {
            mode = current.mode
            generation = current.generation
        }
        switch mode {
        case .stopped(let at):
            return .stopped(at)
        case let .realtime(hostTime, timelineSample):
            if timestamp.mFlags.contains(.hostTimeValid) {
                let seconds = (Double(timestamp.mHostTime) - Double(hostTime)) / AudioTransport.hostTicksPerSecond
                return .running(timelineSample + Int64((seconds * AudioGraphFormat.sampleRate).rounded()))
            }
            return .stopped(timelineSample)
        case let .offline(timelineSample, engineSample):
            return .running(timelineSample + Int64(timestamp.mSampleTime) - engineSample)
        case .scrub(let plan):
            return .scrubbing(plan, engineSample: Int64(timestamp.mSampleTime))
        }
    }
}

/// The scrub read head as a function of the engine's sample clock, so every node in
/// the graph agrees on where it is reading: it plays at normal speed from `head` (the
/// timeline sample) starting at `engineSample`, crossfading from the previous head
/// over `crossfadeLength`, and fades out once the playhead has been still until `idleAt`.
nonisolated struct ScrubPlan: Sendable, Equatable {
    var head: Int64
    var engineSample: Int64
    var previousHead: Int64?
    var crossfadeLength: Int64 = 480
    var idleAt: Int64
    var fadeLength: Int64 = 480

    /// Timeline sample read at engine sample `s`, and the previous read position while crossfading.
    func read(at s: Int64) -> (current: Int64, previous: Int64?, mix: Float) {
        let elapsed = s - engineSample
        let current = head + elapsed
        guard let previousHead, elapsed < crossfadeLength, elapsed >= 0 else { return (current, nil, 1) }
        return (current, previousHead + elapsed, Float(elapsed) / Float(crossfadeLength))
    }

    /// Overall scrub gain at engine sample `s`: fades in from the move, out when idle.
    func gain(at s: Int64) -> Float {
        if s >= idleAt { return max(0, 1 - Float(s - idleAt) / Float(fadeLength)) }
        return 1
    }

    func isSilent(at s: Int64) -> Bool { s >= idleAt + fadeLength }
}
