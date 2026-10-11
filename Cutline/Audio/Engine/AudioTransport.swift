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
        /// Scrubbing while paused: the read head, advanced on the render thread.
        case scrub(ScrubHead)
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
        case .scrub(let head):
            let cycle = Int64(timestamp.mSampleTime)
            return .scrubbing(head.plan(forCycle: cycle), engineSample: cycle)
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
    /// Starting from silence: fades in from this engine sample.
    var fadeInAt: Int64?

    /// Plays nothing.
    static let silent = ScrubPlan(head: 0, engineSample: 0, previousHead: nil, idleAt: .min)

    /// Timeline sample read at engine sample `s`, and the previous read position while crossfading.
    func read(at s: Int64) -> (current: Int64, previous: Int64?, mix: Float) {
        let elapsed = s - engineSample
        let current = head + elapsed
        guard let previousHead, elapsed < crossfadeLength, elapsed >= 0 else { return (current, nil, 1) }
        return (current, previousHead + elapsed, Float(elapsed) / Float(crossfadeLength))
    }

    /// Overall scrub gain at engine sample `s`: fades in from the move, out when idle.
    func gain(at s: Int64) -> Float {
        // In Double: a silent plan's fade-out started at Int64.min, too far back to subtract in Int64.
        var g: Float = 1
        if let fadeInAt { g = Float(min(1, max(0, (Double(s) - Double(fadeInAt)) / Double(fadeLength)))) }
        if s >= idleAt { g *= Float(max(0, 1 - (Double(s) - Double(idleAt)) / Double(fadeLength))) }
        return g
    }

    func isSilent(at s: Int64) -> Bool { s >= idleAt + fadeLength }
}

/// The scrub read head, as in Cutline 1.8: it lives on the audio thread and moves at the
/// exact sample being played. The main thread only reports where the playhead is
/// (`move`); once per render cycle (the first node to render asks, every other node of
/// the cycle gets the same answer) the head keeps reading at normal speed, or, when the
/// playhead has pulled more than 80 ms away, jumps to it with a 10 ms crossfade, never
/// starting a jump during another. Jumps land where the waveform matches what was just
/// playing, so the crossfade never cancels. (Deciding jumps on the main thread from an
/// estimate of the audio clock made the swap a hard cut whenever the estimate was off:
/// a rough, low sound under the audio while dragging.)
///
/// The audio thread never waits and never frees memory here: the main thread leaves
/// each update in an inbox the audio thread picks up only when it's free (otherwise a
/// cycle later), and the main thread keeps recent source lists alive so the audio
/// thread is never the last owner.
nonisolated final class ScrubHead: @unchecked Sendable, Equatable {
    private struct Inbox {
        var sources: [ScrubSource]?
        var target: Int64?
        var stopping = false
        var reset = false
    }

    static let resync = Int64(0.08 * AudioGraphFormat.sampleRate)
    static let idle = Int64(0.12 * AudioGraphFormat.sampleRate)
    static let matchLength = 480
    static let reach = 480

    private let inbox = OSAllocatedUnfairLock(initialState: Inbox())
    /// Main thread only: recent source lists, so the audio thread never releases the last one.
    private var recent: [[ScrubSource]] = []

    // Render thread only.
    private var sources: [ScrubSource] = []
    private var target: Int64 = 0
    private var plan = ScrubPlan.silent
    private var cycle: Int64 = .min
    private var current = [Double](repeating: 0, count: ScrubHead.matchLength)
    private var candidates = [Double](repeating: 0, count: 2 * ScrubHead.reach + ScrubHead.matchLength)

    static func == (a: ScrubHead, b: ScrubHead) -> Bool { a === b }

    /// The playhead moved to timeline sample `target` (main thread).
    func move(to target: Int64, sources: [ScrubSource]) {
        keep(sources)
        inbox.withLock { i in
            i.sources = sources
            i.target = target
            i.stopping = false
        }
    }

    /// The playhead was let go: the head fades out.
    func stop() { inbox.withLock { $0.stopping = true } }

    /// Back to silence (playback starts or the transport stops).
    func reset() {
        keep([])
        inbox.withLock { i in
            i = Inbox()
            i.reset = true
        }
    }

    private func keep(_ list: [ScrubSource]) {
        recent.append(list)
        if recent.count > 64 { recent.removeFirst(recent.count - 64) }
    }

    /// The read plan for the render cycle starting at engine sample `cycle` (render thread).
    func plan(forCycle cycle: Int64) -> ScrubPlan {
        guard cycle != self.cycle else { return plan }
        self.cycle = cycle
        var moved = false, stopping = false
        // Never wait: if the main thread is posting right now, pick it up next cycle.
        if let input = inbox.withLockIfAvailable({ i -> Inbox in
            let taken = i
            i = Inbox()
            return taken
        }) {
            if input.reset {
                plan = .silent
                sources = []
            }
            if let list = input.sources { sources = list }
            if let wanted = input.target {
                target = wanted
                moved = true
            }
            stopping = input.stopping
        }
        advance(at: cycle, moved: moved, stopping: stopping)
        return plan
    }

    private func advance(at now: Int64, moved: Bool, stopping: Bool) {
        var next = plan
        if stopping { next.idleAt = min(next.idleAt, now) }
        if !next.isSilent(at: now) {
            if moved { next.idleAt = now + Self.idle }
            let read = next.read(at: now)
            // One crossfade at a time; the next jump waits for it to finish.
            if read.previous == nil && abs(read.current - target) > Self.resync {
                var jump = ScrubPlan(head: aligned(to: target, continuing: read.current), engineSample: now,
                                     previousHead: read.current, idleAt: next.idleAt)
                jump.fadeInAt = next.fadeInAt
                next = jump
            }
        } else if moved {
            // From silence: start at the playhead, fading in.
            next = ScrubPlan(head: target, engineSample: now, previousHead: nil, idleAt: now + Self.idle)
            next.fadeInAt = now
        }
        // The level never jumps: moving again partway through the fade-out (a pause just
        // over 120 ms) fades back up from where the level had got to, not straight to full.
        let before = plan.gain(at: now), after = next.gain(at: now)
        if after > before + 1e-6 {
            next.fadeInAt = now - Int64((before * Float(next.fadeLength)).rounded(.down))
        }
        plan = next
    }

    /// Within ±10 ms of `target`, the spot whose sound best matches the continuation of
    /// `head` (normalized correlation, coarse then refined).
    private func aligned(to target: Int64, continuing head: Int64) -> Int64 {
        guard !sources.isEmpty else { return target }
        let length = Self.matchLength, reach = Self.reach
        func mix(_ t: Int64) -> Double {
            var sum: Float = 0
            for source in sources {
                let (l, r) = source.sample(atTimeline: t)
                sum += l + r
            }
            return Double(sum)
        }
        var energy = 0.0
        for k in 0..<length {
            let v = mix(head + Int64(k))
            current[k] = v
            energy += v * v
        }
        guard energy > 1e-9 else { return target }
        let base = target - Int64(reach)
        for k in candidates.indices { candidates[k] = mix(base + Int64(k)) }
        func score(_ offset: Int, _ step: Int) -> Double {
            var dot = 0.0, e = 0.0
            var k = 0
            while k < length {
                let y = candidates[offset + k]
                dot += current[k] * y
                e += y * y
                k += step
            }
            return e > 1e-12 ? dot / e.squareRoot() : -.infinity
        }
        var best = reach, bestScore = -Double.infinity
        for offset in stride(from: 0, through: 2 * reach, by: 4) {
            let value = score(offset, 4)
            if value > bestScore { bestScore = value; best = offset }
        }
        let coarse = best
        bestScore = -.infinity
        for offset in max(0, coarse - 3)...min(2 * reach, coarse + 3) {
            let value = score(offset, 1)
            if value > bestScore { bestScore = value; best = offset }
        }
        return base + Int64(best)
    }
}
