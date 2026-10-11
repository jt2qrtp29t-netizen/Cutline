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

/// One effect as the track node runs it: its settings over time, plus a ready-made
/// processor for when the effect is new (built here, off the render thread).
nonisolated final class EffectProgram: @unchecked Sendable {
    let id: UUID
    let kind: AudioEffectKind
    let isBypassed: Bool
    private let parameters: [AudioParameter]
    private let statics: [Double]
    private let frames: [[Keyframe]]
    let prototype: EffectDSP

    init(_ effect: AudioEffect, track: TrackAudio) {
        id = effect.id
        kind = effect.kind
        isBypassed = effect.isBypassed
        parameters = effect.kind.parameters
        statics = parameters.map { effect.value($0) }
        frames = parameters.map { track.keyframes[effect.keyframeKey($0)] ?? [] }
        prototype = EffectDSPFactory.make(effect.kind)
    }

    /// Parameter values at a timeline sample.
    func values(at sample: Int64) -> [Double] {
        let time = Time(seconds: AudioGraphFormat.seconds(ofSample: sample))
        return parameters.indices.map { i in
            frames[i].isEmpty ? statics[i] : parameters[i].clamped(ClipAnimation.interpolate(frames[i], atOffset: time))
        }
    }
}

/// The settings a track node applies.
nonisolated final class TrackProgram: Sendable {
    let envelope: TrackEnvelope
    let effects: [EffectProgram]
    /// For the ducked (game) track: its gain over the timeline.
    let ducking: DuckingCurve?

    init(envelope: TrackEnvelope, effects: [EffectProgram] = [], ducking: DuckingCurve? = nil) {
        self.envelope = envelope
        self.effects = effects
        self.ducking = ducking
    }

    convenience init(track: Track, isActive: Bool, ducking: DuckingCurve? = nil) {
        self.init(envelope: TrackEnvelope(track, isActive: isActive),
                  effects: track.audio.effects.map { EffectProgram($0, track: track.audio) },
                  ducking: ducking?.gameTrackID == track.id ? ducking : nil)
    }

    func gains(at sample: Int64) -> (left: Double, right: Double) {
        envelope.gains(at: Time(seconds: AudioGraphFormat.seconds(ofSample: sample)))
    }
}

/// A running effect in a track's chain: its processor, its smoothed parameters, and
/// how much of its output is heard (gliding to 0 when bypassed, so it never clicks).
nonisolated final class EffectSlot {
    let id: UUID
    let kind: AudioEffectKind
    let dsp: EffectDSP
    var program: EffectProgram
    var mix: Double
    var smoothed: [Double] = []

    init(_ program: EffectProgram) {
        id = program.id
        kind = program.kind
        dsp = program.prototype
        self.program = program
        mix = program.isBypassed ? 0 : 1
    }

    /// Moves the parameters toward their values at `sample` (a few milliseconds' glide).
    func updateParameters(at sample: Int64) {
        let target = program.values(at: sample)
        if smoothed.count != target.count {
            smoothed = target
        } else {
            for i in target.indices { smoothed[i] += (target[i] - smoothed[i]) * 0.5 }
        }
        dsp.update(smoothed)
    }

    @inline(__always) func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let wanted = program.isBypassed ? 0.0 : 1.0
        let step = 1 / Double(AudioGraphFormat.rampLength)
        if mix != wanted { mix = wanted > mix ? min(wanted, mix + step) : max(wanted, mix - step) }
        if mix == 0 { return (l, r) }
        let (wl, wr) = dsp.process(l, r)
        if mix == 1 { return (wl, wr) }
        return (l + (wl - l) * mix, r + (wr - r) * mix)
    }

    /// The chain for a new program, keeping the running effects (and their state) by ID.
    static func chain(_ old: [EffectSlot], for program: TrackProgram) -> [EffectSlot] {
        program.effects.map { effect in
            if let slot = old.first(where: { $0.id == effect.id && $0.kind == effect.kind }) {
                slot.program = effect
                return slot
            }
            return EffectSlot(effect)
        }
    }
}

/// One track: its clips' sum goes through the effect chain, then the fader and pan,
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
        var chain: [EffectSlot] = []
        var sinceUpdate = Int.max
        return { left, right, frames, timestamp, _ in
            if let new = programs.take() {
                gains.install(new, glide: true)
                chain = EffectSlot.chain(chain, for: new)
                sinceUpdate = .max
            }
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
                // The effect chain (before the fader); parameters follow the timeline
                // every control interval, at fixed timeline positions.
                if !chain.isEmpty {
                    if sinceUpdate >= Int(AudioGraphFormat.controlInterval) || sample % AudioGraphFormat.controlInterval == 0 {
                        for slot in chain { slot.updateParameters(at: sample) }
                        sinceUpdate = 0
                    }
                    sinceUpdate &+= 1
                    var l = Double(left[i]), r = Double(right[i])
                    for slot in chain { (l, r) = slot.process(l, r) }
                    left[i] = Float(l)
                    right[i] = Float(r)
                }
                // Ducking (after the effects, before the fader).
                if let curve = gains.program?.ducking {
                    let duck = Float(DSP.linear(curve.gainDB(at: sample)))
                    left[i] *= duck
                    right[i] *= duck
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
    let limiterEnabled: Bool
    let ceilingDB: Double

    init(envelope: MasterEnvelope, isMuted: Bool, limiterEnabled: Bool = false, ceilingDB: Double = -1) {
        self.envelope = envelope
        self.isMuted = isMuted
        self.limiterEnabled = limiterEnabled
        self.ceilingDB = ceilingDB
    }

    func gains(at sample: Int64) -> (left: Double, right: Double) {
        guard !isMuted else { return (0, 0) }
        let g = envelope.gain(at: Time(seconds: AudioGraphFormat.seconds(ofSample: sample)))
        return (g, g)
    }
}

/// Live loudness of the master, published by the render thread for the meter.
nonisolated final class LoudnessPublisher: @unchecked Sendable {
    private let momentary = Atomic<UInt64>(LoudnessMeter.silence.bitPattern)
    private let shortTerm = Atomic<UInt64>(LoudnessMeter.silence.bitPattern)
    private let integrated = Atomic<UInt64>(LoudnessMeter.silence.bitPattern)
    private let truePeak = Atomic<UInt64>(0.0.bitPattern)
    /// Set by the meter's reset button; the render thread clears the integrated value.
    let resetRequested = Atomic<Bool>(false)

    func publish(_ meter: LoudnessMeter) {
        momentary.store(meter.momentary.bitPattern, ordering: .relaxed)
        shortTerm.store(meter.shortTerm.bitPattern, ordering: .relaxed)
        integrated.store(meter.integrated.bitPattern, ordering: .relaxed)
        truePeak.store(meter.truePeak.bitPattern, ordering: .relaxed)
    }

    func read() -> LoudnessReading {
        let peak = Double(bitPattern: truePeak.load(ordering: .relaxed))
        return LoudnessReading(momentary: Double(bitPattern: momentary.load(ordering: .relaxed)),
                               shortTerm: Double(bitPattern: shortTerm.load(ordering: .relaxed)),
                               integrated: Double(bitPattern: integrated.load(ordering: .relaxed)),
                               truePeak: peak > 0 ? AudioLevel.db(fromLinear: peak) : LoudnessMeter.silence)
    }
}

/// The master bus: fader, mute, the optional limiter, the fade in and out when playback
/// starts and stops, the master meter and the loudness meter.
nonisolated final class MasterAudioUnit: CutlineAudioUnit, @unchecked Sendable {
    static let componentDescription = description("ctlm")

    let transport = TransportBox()
    let programs = ProgramMailbox<MasterProgram>()
    let meter = PeakMeter()
    let runControl = RunControl()
    let loudness = LoudnessPublisher()
    /// Measures only while playing (not scrubbing or stopped).
    private let loudnessMeter = LoudnessMeter()

    override var render: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int, AudioTimeStamp, Bool) -> Void {
        let programs = self.programs, transportBox = self.transport, meter = self.meter
        let control = self.runControl, publisher = self.loudness, loudnessMeter = self.loudnessMeter
        var gains = ProgramGains<MasterProgram>()
        var clock = TransportClock()
        var runGain: Float = 1
        let limiter = LimiterDSP()
        var limiterMix = 0.0
        var ceiling = -1.0
        let step = 1 / Float(AudioGraphFormat.rampLength)
        return { left, right, frames, timestamp, _ in
            if let new = programs.take() {
                // The first settings apply at once (an export starts fully limited); later
                // switches glide so they never click.
                if gains.program == nil { limiterMix = new.limiterEnabled ? 1 : 0 }
                gains.install(new, glide: true)
                if new.ceilingDB != ceiling || limiterMix == 0 {
                    ceiling = new.ceilingDB
                    limiter.update([ceiling, 80])
                }
            }
            if publisher.resetRequested.exchange(false, ordering: .relaxed) { loudnessMeter.resetIntegrated() }
            guard let transport = transportBox.transport else { return }
            let position = clock.position(transport, timestamp)
            if control.fadesIn.exchange(false, ordering: .relaxed) { runGain = 0 }
            let target: Float = control.run.load(ordering: .relaxed) ? 1 : 0
            let limiterTarget = gains.program?.limiterEnabled == true ? 1.0 : 0.0
            var isRunning = false
            if case .running = position { isRunning = control.measuresLoudness.load(ordering: .relaxed) }
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
                var l = Double(left[i] * gl), r = Double(right[i] * gr)
                // The limiter fades in and out when switched, so switching never clicks.
                if limiterMix != limiterTarget {
                    limiterMix = limiterTarget > limiterMix ? min(1, limiterMix + Double(step)) : max(0, limiterMix - Double(step))
                }
                if limiterMix > 0 {
                    let (ll, lr) = limiter.process(l, r)
                    l += (ll - l) * limiterMix
                    r += (lr - r) * limiterMix
                }
                if isRunning { loudnessMeter.process(l, r) }
                left[i] = Float(l) * runGain
                right[i] = Float(r) * runGain
                peakL = max(peakL, abs(left[i]))
                peakR = max(peakR, abs(right[i]))
            }
            meter.record(left: peakL, right: peakR)
            if isRunning { publisher.publish(loudnessMeter) }
        }
    }
}

/// Starts and stops the master's output smoothly.
nonisolated final class RunControl: Sendable {
    /// On while sound should play; off fades the output out (about 5 ms).
    let run = Atomic<Bool>(true)
    /// Set when real-time playback starts, to fade in instead of starting abruptly.
    let fadesIn = Atomic<Bool>(false)
    /// Live loudness metering (real-time playback only; offline renders measure on their own).
    let measuresLoudness = Atomic<Bool>(false)
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

