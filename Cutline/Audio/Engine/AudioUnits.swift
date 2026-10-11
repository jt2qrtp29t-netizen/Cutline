import AVFoundation
import AudioToolbox
import os
import Synchronization

/// Hands a new program (immutable settings) to the render thread without ever making
/// it wait: the render thread takes it on its next cycle if the lock is free.
nonisolated final class ProgramMailbox<Program: Sendable>: @unchecked Sendable {
    private let pending = OSAllocatedUnfairLock<Program?>(initialState: nil)

    func post(_ program: Program) {
        pending.withLock { $0 = program }
    }

    /// Render thread: the newest posted program, if any arrived since the last call.
    func take() -> Program? {
        pending.withLockIfAvailable { value -> Program? in
            let taken = value
            value = nil
            return taken
        } ?? nil
    }
}

/// Peak levels measured on the render thread and read by the meters. The render
/// thread keeps the highest value since the last read; reading resets it.
nonisolated final class PeakMeter: @unchecked Sendable {
    private let left = Atomic<UInt32>(0)
    private let right = Atomic<UInt32>(0)
    private let clipped = Atomic<Bool>(false)

    /// Full scale: samples at or above this count as clipping.
    static let clipLevel: Float = 1

    func record(left l: Float, right r: Float) {
        raise(left, l)
        raise(right, r)
        if l >= Self.clipLevel || r >= Self.clipLevel { clipped.store(true, ordering: .relaxed) }
    }

    private func raise(_ atom: borrowing Atomic<UInt32>, _ value: Float) {
        var current = atom.load(ordering: .relaxed)
        while value > Float(bitPattern: current) {
            let (exchanged, original) = atom.compareExchange(expected: current, desired: value.bitPattern, ordering: .relaxed)
            if exchanged { break }
            current = original
        }
    }

    /// Peaks since the last read (linear), and whether anything clipped.
    func read() -> (left: Float, right: Float, clipped: Bool) {
        (Float(bitPattern: left.exchange(0, ordering: .relaxed)),
         Float(bitPattern: right.exchange(0, ordering: .relaxed)),
         clipped.exchange(false, ordering: .relaxed))
    }
}

/// Left/right gains evaluated at fixed timeline positions every `controlInterval`
/// samples and interpolated in between, so the result for a given timeline sample is
/// the same however the audio was cut into render cycles.
nonisolated struct ControlRateGains {
    private var index: Int64 = .min
    private var a: (Float, Float) = (0, 0)
    private var b: (Float, Float) = (0, 0)

    mutating func reset() { index = .min }

    mutating func gains(at sample: Int64, _ evaluate: (Int64) -> (left: Double, right: Double)) -> (Float, Float) {
        let interval = AudioGraphFormat.controlInterval
        let k = sample >= 0 ? sample / interval : (sample - interval + 1) / interval
        if k != index {
            if k == index + 1 {
                a = b
            } else {
                let g = evaluate(k * interval)
                a = (Float(g.left), Float(g.right))
            }
            let g = evaluate((k + 1) * interval)
            b = (Float(g.left), Float(g.right))
            index = k
        }
        let f = Float(sample - k * interval) / Float(interval)
        return (a.0 + (b.0 - a.0) * f, a.1 + (b.1 - a.1) * f)
    }
}

/// Gains from a program that can change at any moment: after a change it glides from
/// the old program's gains to the new one's over `rampLength` samples.
nonisolated struct ProgramGains<Program> {
    private(set) var program: Program?
    private var previous: Program?
    private var current = ControlRateGains()
    private var old = ControlRateGains()
    private var rampLeft = 0

    mutating func install(_ new: Program, glide: Bool) {
        if glide, program != nil {
            previous = program
            old = current
            rampLeft = AudioGraphFormat.rampLength
        } else {
            previous = nil
            rampLeft = 0
        }
        program = new
        current.reset()
    }

    mutating func gains(at sample: Int64, _ evaluate: (Program, Int64) -> (left: Double, right: Double)) -> (Float, Float) {
        guard let program else { return (0, 0) }
        let now = current.gains(at: sample) { evaluate(program, $0) }
        guard rampLeft > 0, let previous else { return now }
        let before = old.gains(at: sample) { evaluate(previous, $0) }
        let w = Float(rampLeft) / Float(AudioGraphFormat.rampLength)
        rampLeft -= 1
        if rampLeft == 0 { self.previous = nil }
        return (now.0 + (before.0 - now.0) * w, now.1 + (before.1 - now.1) * w)
    }
}

// MARK: - Units

/// Base for Cutline's audio nodes: one stereo 48 kHz input and output, and a render
/// block that pulls the input and hands it, in place, to `processor`.
nonisolated class CutlineAudioUnit: AUAudioUnit, @unchecked Sendable {
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = AudioGraphFormat.format
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    /// Processes one cycle in place: two channels of `frames` samples.
    var render: (_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int,
                 _ timestamp: AudioTimeStamp, _ hasInput: Bool) -> Void { { _, _, _, _, _ in } }

    override var internalRenderBlock: AUInternalRenderBlock {
        let process = render
        return { _, timestamp, frameCount, _, output, _, pullInput in
            let frames = Int(frameCount)
            var hasInput = false
            if let pullInput {
                var flags = AudioUnitRenderActionFlags()
                hasInput = pullInput(&flags, timestamp, frameCount, 0, output) == noErr
            }
            let buffers = UnsafeMutableAudioBufferListPointer(output)
            guard buffers.count >= 2, let l = buffers[0].mData, let r = buffers[1].mData else { return noErr }
            let left = l.assumingMemoryBound(to: Float.self), right = r.assumingMemoryBound(to: Float.self)
            if !hasInput {
                left.update(repeating: 0, count: frames)
                right.update(repeating: 0, count: frames)
            }
            process(left, right, frames, timestamp.pointee, hasInput)
            buffers[0].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            buffers[1].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            return noErr
        }
    }

    static func description(_ subType: String) -> AudioComponentDescription {
        func code(_ s: String) -> OSType { s.utf8.reduce(0) { $0 << 8 | OSType($1) } }
        return AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: code(subType),
                                         componentManufacturer: code("Ctln"), componentFlags: 0, componentFlagsMask: 0)
    }

    /// Registers Cutline's units with the system, once per process.
    static let registered: Bool = {
        AUAudioUnit.registerSubclass(ClipAudioUnit.self, as: ClipAudioUnit.componentDescription, name: "Cutline: Clip", version: 1)
        AUAudioUnit.registerSubclass(TrackAudioUnit.self, as: TrackAudioUnit.componentDescription, name: "Cutline: Track", version: 1)
        AUAudioUnit.registerSubclass(MasterAudioUnit.self, as: MasterAudioUnit.componentDescription, name: "Cutline: Master", version: 1)
        return true
    }()

    /// A node for engine graphs, created synchronously.
    static func makeNode<Unit: CutlineAudioUnit>(_ type: Unit.Type, _ description: AudioComponentDescription) -> (AVAudioUnitEffect, Unit) {
        _ = registered
        let node = AVAudioUnitEffect(audioComponentDescription: description)
        // Registered in-process, so the node's unit is an instance of `Unit`.
        let unit = node.withAUAudioUnit { $0 as! Unit }
        return (node, unit)
    }
}

/// What a clip node plays: its envelope, and for scrubbing the decoded source near the head.
nonisolated final class ClipProgram: Sendable {
    let envelope: ClipEnvelope
    let scrub: ScrubSource?

    init(envelope: ClipEnvelope, scrub: ScrubSource? = nil) {
        self.envelope = envelope
        self.scrub = scrub
    }

    func gains(at sample: Int64) -> (left: Double, right: Double) {
        envelope.gains(at: Time(seconds: AudioGraphFormat.seconds(ofSample: sample)))
    }
}

/// One clip: applies clip gain, volume, pan and fades to its player's sound (or, while
/// scrubbing, reads its source around the scrub head).
nonisolated final class ClipAudioUnit: CutlineAudioUnit, @unchecked Sendable {
    static let componentDescription = description("ctlc")

    let transport = TransportBox()
    let programs = ProgramMailbox<ClipProgram>()

    override var render: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int, AudioTimeStamp, Bool) -> Void {
        let programs = self.programs, transportBox = self.transport
        var gains = ProgramGains<ClipProgram>()
        var clock = TransportClock()
        return { left, right, frames, timestamp, _ in
            if let new = programs.take() { gains.install(new, glide: true) }
            guard let transport = transportBox.transport, let program = gains.program else {
                left.update(repeating: 0, count: frames); right.update(repeating: 0, count: frames)
                return
            }
            switch clock.position(transport, timestamp) {
            case .running(let first):
                for i in 0..<frames {
                    let (gl, gr) = gains.gains(at: first + Int64(i)) { $0.gains(at: $1) }
                    left[i] *= gl
                    right[i] *= gr
                }
            case .stopped(let at):
                for i in 0..<frames {
                    let (gl, gr) = gains.gains(at: at) { $0.gains(at: $1) }
                    left[i] *= gl
                    right[i] *= gr
                }
            case let .scrubbing(plan, engineSample):
                guard let source = program.scrub else {
                    left.update(repeating: 0, count: frames); right.update(repeating: 0, count: frames)
                    return
                }
                for i in 0..<frames {
                    let s = engineSample + Int64(i)
                    let read = plan.read(at: s)
                    var (l, r) = source.sample(atTimeline: read.current)
                    let (gl, gr) = program.gains(at: read.current)
                    l *= Float(gl); r *= Float(gr)
                    if let previous = read.previous {
                        var (pl, pr) = source.sample(atTimeline: previous)
                        let (pgl, pgr) = program.gains(at: previous)
                        pl *= Float(pgl); pr *= Float(pgr)
                        l = pl + (l - pl) * read.mix
                        r = pr + (r - pr) * read.mix
                    }
                    let g = plan.gain(at: s)
                    left[i] = l * g
                    right[i] = r * g
                }
            }
        }
    }
}

/// The settings a track node applies.
nonisolated final class TrackProgram: Sendable {
    let envelope: TrackEnvelope

    init(envelope: TrackEnvelope) {
        self.envelope = envelope
    }

    func gains(at sample: Int64) -> (left: Double, right: Double) {
        envelope.gains(at: Time(seconds: AudioGraphFormat.seconds(ofSample: sample)))
    }
}

/// One track: its clips' sum goes through the fader and pan (and, later, its effects),
/// and its peak level is measured for the mixer.
nonisolated final class TrackAudioUnit: CutlineAudioUnit, @unchecked Sendable {
    static let componentDescription = description("ctlt")

    let transport = TransportBox()
    let programs = ProgramMailbox<TrackProgram>()
    let meter = PeakMeter()

    override var render: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int, AudioTimeStamp, Bool) -> Void {
        let programs = self.programs, transportBox = self.transport, meter = self.meter
        var gains = ProgramGains<TrackProgram>()
        var clock = TransportClock()
        return { left, right, frames, timestamp, _ in
            if let new = programs.take() { gains.install(new, glide: true) }
            guard let transport = transportBox.transport else { return }
            let position = clock.position(transport, timestamp)
            var peakL: Float = 0, peakR: Float = 0
            for i in 0..<frames {
                let sample: Int64
                switch position {
                case .running(let first): sample = first + Int64(i)
                case .stopped(let at): sample = at
                case let .scrubbing(plan, engineSample): sample = plan.read(at: engineSample + Int64(i)).current
                }
                let (gl, gr) = gains.gains(at: sample) { $0.gains(at: $1) }
                left[i] *= gl
                right[i] *= gr
                peakL = max(peakL, abs(left[i]))
                peakR = max(peakR, abs(right[i]))
            }
            meter.record(left: peakL, right: peakR)
        }
    }
}

/// What the master node applies.
nonisolated final class MasterProgram: Sendable {
    let envelope: MasterEnvelope
    /// Universal mute.
    let isMuted: Bool

    init(envelope: MasterEnvelope, isMuted: Bool) {
        self.envelope = envelope
        self.isMuted = isMuted
    }

    func gains(at sample: Int64) -> (left: Double, right: Double) {
        guard !isMuted else { return (0, 0) }
        let g = envelope.gain(at: Time(seconds: AudioGraphFormat.seconds(ofSample: sample)))
        return (g, g)
    }
}

/// The master bus: fader, mute, the fade in and out when playback starts and stops,
/// and the master meter.
nonisolated final class MasterAudioUnit: CutlineAudioUnit, @unchecked Sendable {
    static let componentDescription = description("ctlm")

    let transport = TransportBox()
    let programs = ProgramMailbox<MasterProgram>()
    let meter = PeakMeter()
    let runControl = RunControl()

    override var render: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int, AudioTimeStamp, Bool) -> Void {
        let programs = self.programs, transportBox = self.transport, meter = self.meter
        let control = self.runControl
        var gains = ProgramGains<MasterProgram>()
        var clock = TransportClock()
        var runGain: Float = 1
        let step = 1 / Float(AudioGraphFormat.rampLength)
        return { left, right, frames, timestamp, _ in
            if let new = programs.take() { gains.install(new, glide: true) }
            guard let transport = transportBox.transport else { return }
            let position = clock.position(transport, timestamp)
            if control.fadesIn.exchange(false, ordering: .relaxed) { runGain = 0 }
            let target: Float = control.run.load(ordering: .relaxed) ? 1 : 0
            var peakL: Float = 0, peakR: Float = 0
            for i in 0..<frames {
                let sample: Int64
                switch position {
                case .running(let first): sample = first + Int64(i)
                case .stopped(let at): sample = at
                case let .scrubbing(plan, engineSample): sample = plan.read(at: engineSample + Int64(i)).current
                }
                if runGain < target { runGain = min(target, runGain + step) } else if runGain > target { runGain = max(target, runGain - step) }
                let (gl, gr) = gains.gains(at: sample) { $0.gains(at: $1) }
                left[i] *= gl * runGain
                right[i] *= gr * runGain
                peakL = max(peakL, abs(left[i]))
                peakR = max(peakR, abs(right[i]))
            }
            meter.record(left: peakL, right: peakR)
        }
    }
}

/// Starts and stops the master's output smoothly.
nonisolated final class RunControl: Sendable {
    /// On while sound should play; off fades the output out (about 5 ms).
    let run = Atomic<Bool>(true)
    /// Set when real-time playback starts, to fade in instead of starting abruptly.
    let fadesIn = Atomic<Bool>(false)
}

/// The transport a unit follows, set once when the unit joins a graph.
nonisolated final class TransportBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<AudioTransport?>(initialState: nil)
    private var cached: AudioTransport?

    var transport: AudioTransport? {
        if let cached { return cached }
        cached = lock.withLockIfAvailable { $0 } ?? nil
        return cached
    }

    func attach(_ transport: AudioTransport) {
        lock.withLock { $0 = transport }
    }
}

