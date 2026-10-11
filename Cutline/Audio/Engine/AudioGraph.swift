import AVFoundation
import Synchronization

/// Cutline's audio graph, the same for playback, scrubbing and export:
///
///     clip player → [time-pitch] → clip node ─┐
///     clip player → [time-pitch] → clip node ─┼→ track sum → track node ─┐
///                                              …                        ├→ master sum → master node → output
///                                   (other tracks) → track node ────────┘
///
/// Clip nodes apply clip gain, volume, pan and fades; track nodes the fader, pan and
/// effects; the master node the master fader, start/stop fades and metering. Every
/// node evaluates its settings with the same functions (`ClipEnvelope`,
/// `TrackEnvelope`, `MasterEnvelope`) at the timeline sample it's rendering, so real
/// time and offline rendering produce the same sound.
nonisolated final class AudioGraph {
    let engine: AVAudioEngine
    let transport = AudioTransport()

    private let masterSum = AVAudioMixerNode()
    private let master: (node: AVAudioUnitEffect, unit: MasterAudioUnit)
    private var tracks: [UUID: TrackNodes] = [:]
    private var voices: [UUID: Voice] = [:]
    private var masterSettings = MasterAudio()
    /// The game track's ducking curve (the latest one handed in).
    private var ducking: DuckingCurve?
    var isMuted = false {
        didSet { postMaster() }
    }

    private struct TrackNodes {
        let sum: AVAudioMixerNode
        let node: AVAudioUnitEffect
        let unit: TrackAudioUnit
    }

    private struct Voice {
        let clipID: UUID
        let trackID: UUID
        let player: AVAudioPlayerNode?
        /// While scrubbing there's no player; a silent source keeps the clip node live.
        let silence: AVAudioSourceNode?
        let timePitch: AVAudioUnitTimePitch?
        let node: AVAudioUnitEffect
        let unit: ClipAudioUnit
        var isMono: Bool
        var nodes: [AVAudioNode] { [player, silence, timePitch].compactMap { $0 } + [node] }
    }

    init(engine: AVAudioEngine) {
        self.engine = engine
        master = CutlineAudioUnit.makeNode(MasterAudioUnit.self, MasterAudioUnit.componentDescription)
        master.unit.transport.attach(transport)
        let format = AudioGraphFormat.format
        engine.attach(masterSum)
        engine.attach(master.node)
        Self.keepAlive(masterSum, in: engine)
        try? engine.connectNode(masterSum, to: master.node, format: format)
        try? engine.connectNode(master.node, to: engine.mainMixerNode, format: format)
        postMaster()
    }

    /// The engine only renders mixer branches that have an input when they're wired
    /// in; a silent source keeps each of the graph's mixers live, so clips and tracks
    /// can join and leave while the engine runs.
    private static func keepAlive(_ mixer: AVAudioMixerNode, in engine: AVAudioEngine) {
        let silence = silentSource()
        engine.attach(silence)
        try? engine.connectNode(silence, to: mixer, fromBus: 0, toBus: mixer.nextAvailableInputBus, format: AudioGraphFormat.format)
    }

    private static func silentSource() -> AVAudioSourceNode {
        AVAudioSourceNode(format: AudioGraphFormat.format) { isSilence, _, _, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            isSilence.pointee = true
            return noErr
        }
    }

    var masterMeter: PeakMeter { master.unit.meter }
    func meter(forTrack id: UUID) -> PeakMeter? { tracks[id]?.unit.meter }
    /// The audio tracks the graph has nodes for.
    var trackIDs: Set<UUID> { Set(tracks.keys) }
    var hasVoices: Bool { voices.values.contains { $0.player != nil } }

    // MARK: Settings

    /// Brings the graph's tracks in line with the project and hands every node its
    /// current settings (fader moves, mute and solo, keyframes…). Changes glide in.
    func update(_ state: ProjectState, ducking: DuckingCurve? = nil) {
        if let ducking { self.ducking = ducking }
        if state.audio.ducking?.isEnabled != true { self.ducking = nil }
        syncTracks(state)
        for index in state.trackIndices(of: .audio) {
            let track = state.tracks[index]
            tracks[track.id]?.unit.programs.post(TrackProgram(track: track, isActive: state.isTrackActive(index), ducking: self.ducking))
        }
        for index in state.trackIndices(of: .audio) {
            for clip in state.tracks[index].clips {
                guard let voice = voices[clip.id] else { continue }
                let envelope = ClipEnvelope(clip, track: state.tracks[index], isActive: state.isClipActive(clip, onTrack: index),
                                            monoSource: voice.isMono)
                voice.unit.programs.post(ClipProgram(envelope: envelope, scrub: scrubSources[clip.id]))
            }
        }
        masterSettings = state.audio.master
        postMaster()
    }

    private func postMaster() {
        master.unit.programs.post(MasterProgram(envelope: MasterEnvelope(masterSettings), isMuted: isMuted,
                                                limiterEnabled: masterSettings.limiterEnabled, ceilingDB: masterSettings.ceilingDB))
    }

    /// The live loudness of the master.
    var loudness: LoudnessPublisher { master.unit.loudness }

    /// Whether the master measures loudness while playing (real-time playback).
    var measuresLoudness: Bool {
        get { master.unit.runControl.measuresLoudness.load(ordering: .relaxed) }
        set { master.unit.runControl.measuresLoudness.store(newValue, ordering: .relaxed) }
    }

    /// One track node per audio track; nodes of deleted tracks are removed.
    private func syncTracks(_ state: ProjectState) {
        let ids = Set(state.trackIndices(of: .audio).map { state.tracks[$0].id })
        for (id, nodes) in tracks where !ids.contains(id) {
            for voice in voices.values where voice.trackID == id { remove(voice) }
            engine.detach(nodes.sum)
            engine.detach(nodes.node)
            tracks[id] = nil
        }
        let format = AudioGraphFormat.format
        for id in ids where tracks[id] == nil {
            let sum = AVAudioMixerNode()
            let (node, unit) = CutlineAudioUnit.makeNode(TrackAudioUnit.self, TrackAudioUnit.componentDescription)
            unit.transport.attach(transport)
            engine.attach(sum)
            engine.attach(node)
            Self.keepAlive(sum, in: engine)
            try? engine.connectNode(sum, to: node, format: format)
            try? engine.connectNode(node, to: masterSum, fromBus: 0, toBus: masterSum.nextAvailableInputBus, format: format)
            tracks[id] = TrackNodes(sum: sum, node: node, unit: unit)
        }
    }

    // MARK: Playing

    /// Builds and schedules a voice for every clip that still sounds after `time`.
    /// - Parameter sources: each media item's prepared 48 kHz stereo sound.
    /// - Parameter retimed: the clip's sound rendered at its speed curve (for ramps and
    ///   tape-style speed), or nil if it isn't ready (the clip is silent until it is).
    func prepareVoices(_ state: ProjectState, from time: Time, ducking: DuckingCurve? = nil, sources: (MediaItem) -> PreparedAudio?,
                       retimed: (Clip, PreparedAudio) -> PreparedAudio? = { try? RetimedAudio.prepare($0, source: $1) }) {
        if let ducking { self.ducking = ducking }
        removeVoices()
        syncTracks(state)
        for index in state.trackIndices(of: .audio) {
            let track = state.tracks[index]
            for clip in track.clips {
                guard let media = state.mediaItem(clip.mediaID), let prepared = sources(media) else { continue }
                let envelope = ClipEnvelope(clip, track: track, isActive: state.isClipActive(clip, onTrack: index),
                                            monoSource: prepared.isMono)
                // The clip as it sounds, widened across its crossfades.
                var playing = envelope.playbackClip(clip)
                guard playing.end > time else { continue }
                var url = prepared.url
                var rate = clip.speed
                if RetimedAudio.needsRendering(clip) {
                    // Rendered in timeline time: play it as is, from the clip's start.
                    guard let rendered = retimed(playing, prepared) else { continue }
                    url = rendered.url
                    rate = 1
                    playing.sourceStart = .zero
                    playing.speed = 1
                    playing.animation.keyframes[.speed] = nil
                }
                guard let file = try? AVAudioFile(forReading: url),  // Each voice reads through its own file object.
                      let plan = AudioVoicePlan.make(for: playing, from: time, sampleRate: AudioGraphFormat.sampleRate,
                                                     fileLength: file.length) else { continue }
                let player = AVAudioPlayerNode()
                // Speed and pitch need the time-pitch unit; without them the sound passes untouched.
                let timePitch = rate != 1 || clip.pitchShiftCents != 0 ? AVAudioUnitTimePitch() : nil
                timePitch?.rate = Float(rate)
                timePitch?.pitch = Float(clip.pitchShiftCents)
                let voice = makeVoice(clip: clip, trackID: track.id, player: player, timePitch: timePitch, isMono: prepared.isMono)
                voice.unit.programs.post(ClipProgram(envelope: envelope))
                let when = plan.delayFrames > 0 ? AVAudioTime(sampleTime: plan.delayFrames, atRate: AudioGraphFormat.sampleRate) : nil
                player.scheduleSegment(file, startingFrame: plan.startFrame, frameCount: plan.frameCount, at: when, completionHandler: nil)
                // Read the first audio now, so the voice is ready on its very first sample.
                player.prepare(withFrameCount: 8192)
            }
        }
        update(state)
    }

    private func makeVoice(clip: Clip, trackID: UUID, player: AVAudioPlayerNode?, timePitch: AVAudioUnitTimePitch?,
                           isMono: Bool) -> Voice {
        let (node, unit) = CutlineAudioUnit.makeNode(ClipAudioUnit.self, ClipAudioUnit.componentDescription)
        unit.transport.attach(transport)
        let voice = Voice(clipID: clip.id, trackID: trackID, player: player, silence: player == nil ? Self.silentSource() : nil,
                          timePitch: timePitch, node: node, unit: unit, isMono: isMono)
        let format = AudioGraphFormat.format
        voice.nodes.forEach(engine.attach)
        let chain = voice.nodes
        for (from, to) in zip(chain, chain.dropFirst()) {
            try? engine.connectNode(from, to: to, format: format)
        }
        if let sum = tracks[trackID]?.sum {
            try? engine.connectNode(node, to: sum, fromBus: 0, toBus: sum.nextAvailableInputBus, format: format)
        }
        voices[clip.id] = voice
        return voice
    }

    /// Starts every voice: at `hostTime` in real time (the sample at timeline `time`
    /// reaches the output then), or immediately when rendering offline.
    func start(at time: Time, hostTime: UInt64?) {
        let sample = AudioGraphFormat.sample(of: time)
        let start: AVAudioTime
        if let hostTime {
            transport.set(.realtime(hostTime: hostTime, timelineSample: sample))
            master.unit.runControl.fadesIn.store(true, ordering: .relaxed)
            start = AVAudioTime(hostTime: hostTime)
        } else {
            // Offline: the players and every node agree on the engine sample that plays
            // the first timeline sample (the next one to be rendered).
            let engineSample = engine.isInManualRenderingMode ? engine.manualRenderingSampleTime : 0
            transport.set(.offline(timelineSample: sample, engineSample: engineSample))
            start = AVAudioTime(sampleTime: engineSample, atRate: AudioGraphFormat.sampleRate)
        }
        master.unit.runControl.run.store(true, ordering: .relaxed)
        for voice in voices.values {
            try? voice.player?.playAudio(at: start)
        }
    }

    /// Fades the master out (real time) before `removeVoices` stops the sound.
    func fadeOut() {
        master.unit.runControl.run.store(false, ordering: .relaxed)
    }

    func removeVoices() {
        for voice in voices.values { remove(voice) }
        scrubSources = [:]
    }

    private func remove(_ voice: Voice) {
        voice.player?.stop()
        voice.nodes.forEach(engine.detach)
        voices[voice.clipID] = nil
    }

    // MARK: Scrubbing

    private var scrubSources: [UUID: ScrubSource] = [:]
    private var scrubPlan: ScrubPlan?

    /// Plays the sound under the playhead while it's dragged: clip nodes for the clips
    /// near it read their decoded source at the scrub head, through the same tracks
    /// and master as playback.
    func scrub(_ state: ProjectState, to time: Time, sources: [ScrubSource], monoSources: Set<UUID>) {
        if voices.values.contains(where: { $0.player != nil }) { removeVoices() }
        syncTracks(state)
        let wanted = Dictionary(uniqueKeysWithValues: sources.map { ($0.clipID, $0) })
        for voice in voices.values where wanted[voice.clipID] == nil { remove(voice) }
        scrubSources = wanted
        for index in state.trackIndices(of: .audio) {
            let track = state.tracks[index]
            for clip in track.clips where wanted[clip.id] != nil && voices[clip.id] == nil {
                _ = makeVoice(clip: clip, trackID: track.id, player: nil, timePitch: nil, isMono: monoSources.contains(clip.mediaID))
            }
        }
        update(state)

        // Move the read head: keep reading on if the playhead is close, otherwise jump
        // to it with a short crossfade from where it was.
        let now = currentEngineSample
        let target = AudioGraphFormat.sample(of: time)
        let resync = Int64(0.08 * AudioGraphFormat.sampleRate)
        let idle = Int64(0.12 * AudioGraphFormat.sampleRate)
        var plan: ScrubPlan
        if let previous = scrubPlan, !previous.isSilent(at: now) {
            let head = previous.read(at: now).current
            if abs(head - target) > resync {
                let aligned = Self.alignedJump(to: target, continuing: head, sources: sources)
                plan = ScrubPlan(head: aligned, engineSample: now, previousHead: head, idleAt: now + idle)
            } else {
                plan = previous
                plan.idleAt = now + idle
            }
        } else {
            plan = ScrubPlan(head: target, engineSample: now, previousHead: nil, idleAt: now + idle)
        }
        scrubPlan = plan
        transport.set(.scrub(plan))
        master.unit.runControl.run.store(true, ordering: .relaxed)
    }

    /// Where to land a jump of the scrub head: within ±10 ms of `target`, the spot whose
    /// sound best matches the continuation of the current read position, so the jump's
    /// crossfade joins two in-step waveforms. (Crossfading two unrelated spots makes them
    /// partly cancel, which sounds muffled and fluttery while dragging.)
    static func alignedJump(to target: Int64, continuing head: Int64, sources: [ScrubSource]) -> Int64 {
        guard !sources.isEmpty else { return target }
        let length = 480, reach = 480
        func mix(_ s: Int64) -> Double {
            var sum: Float = 0
            for source in sources {
                let (l, r) = source.sample(atTimeline: s)
                sum += l + r
            }
            return Double(sum)
        }
        let current = (0..<length).map { mix(head + Int64($0)) }
        let currentEnergy = current.reduce(0) { $0 + $1 * $1 }
        guard currentEnergy > 1e-9 else { return target }
        let base = target - Int64(reach)
        let candidates = (0..<(2 * reach + length)).map { mix(base + Int64($0)) }
        // Normalized correlation, coarse (every 2nd offset and sample) then refined.
        func score(_ offset: Int, stride step: Int) -> Double {
            var dot = 0.0, energy = 0.0
            var k = 0
            while k < length {
                let y = candidates[offset + k]
                dot += current[k] * y
                energy += y * y
                k += step
            }
            return energy > 1e-12 ? dot / energy.squareRoot() : -.infinity
        }
        var best = reach, bestScore = -Double.infinity
        for offset in stride(from: 0, through: 2 * reach, by: 2) {
            let value = score(offset, stride: 2)
            if value > bestScore { bestScore = value; best = offset }
        }
        let coarse = best
        bestScore = -.infinity
        for offset in max(0, coarse - 2)...min(2 * reach, coarse + 2) {
            let value = score(offset, stride: 1)
            if value > bestScore { bestScore = value; best = offset }
        }
        return base + Int64(best)
    }

    /// Lets the scrub head come to rest; it fades out.
    func stopScrubbing() {
        guard var plan = scrubPlan else { return }
        plan.idleAt = min(plan.idleAt, currentEngineSample)
        scrubPlan = plan
        transport.set(.scrub(plan))
    }

    /// The engine's sample clock now: the next sample to render offline, or (in real
    /// time) a little after the last rendered cycle.
    private var currentEngineSample: Int64 {
        if engine.isInManualRenderingMode { return engine.manualRenderingSampleTime }
        return Int64(engine.outputNode.lastRenderTime?.sampleTime ?? 0) + 256
    }

    func stopTransport(at time: Time) {
        scrubPlan = nil
        transport.set(.stopped(at: AudioGraphFormat.sample(of: time)))
    }
}

// MARK: - Offline rendering

nonisolated extension AudioGraph {
    /// Renders `range` of the project offline (no speakers) through the same graph as
    /// playback, handing each block of 48 kHz stereo audio to `consume`.
    static func render(_ state: ProjectState, range: TimeRange, sources: [UUID: PreparedAudio], ducking: DuckingCurve? = nil,
                       isCancelled: () -> Bool = { false }, progress: (Double) -> Void = { _ in },
                       consume: (AVAudioPCMBuffer) throws -> Void) throws {
        let engine = AVAudioEngine()
        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: AudioGraphFormat.format, maximumFrameCount: chunk)
        let graph = AudioGraph(engine: engine)
        graph.prepareVoices(state, from: range.start, ducking: ducking) { sources[$0.id] }
        try engine.start()
        defer {
            graph.removeVoices()
            engine.stop()
        }
        graph.start(at: range.start, hostTime: nil)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw ExportError.setupFailed("the audio couldn’t be prepared.")
        }
        let total = AVAudioFramePosition((range.duration.seconds * AudioGraphFormat.sampleRate).rounded())
        var done: AVAudioFramePosition = 0
        while done < total {
            if isCancelled() { throw ExportError.cancelled }
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - done))
            // When busy, the players may not have read ahead yet: that's "try again".
            var status = try engine.renderOffline(frames, to: buffer)
            var retries = 0
            while status == .cannotDoInCurrentContext && retries < 2_000 {
                if isCancelled() { throw ExportError.cancelled }
                Thread.sleep(forTimeInterval: 0.002)
                status = try engine.renderOffline(frames, to: buffer)
                retries += 1
            }
            guard status == .success else { throw ExportError.writingFailed("the audio mix stopped early.") }
            try consume(buffer)
            done += AVAudioFramePosition(buffer.frameLength)
            progress(Double(done) / Double(max(total, 1)))
        }
    }
}
