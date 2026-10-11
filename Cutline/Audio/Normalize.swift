import AVFoundation

/// What Normalize adjusts.
nonisolated enum NormalizeTarget: Hashable, Sendable {
    /// A clip's own loudness, set with its clip gain.
    case clip(UUID)
    /// A track as it sounds (effects included), set with its fader.
    case track(UUID)
    /// The whole mix, set with the master fader.
    case project

    var title: String {
        switch self {
        case .clip: "Clip"
        case .track: "Track"
        case .project: "Project"
        }
    }
}

/// Measures loudness offline, through the same graph as playback and export.
nonisolated enum LoudnessAnalyzer {
    struct Measurement: Sendable {
        let integrated: Double
        /// dBTP.
        let truePeak: Double
    }

    static func measure(_ state: ProjectState, range: TimeRange, sources: [UUID: PreparedAudio],
                        ducking: DuckingCurve?) throws -> Measurement {
        let meter = LoudnessMeter()
        try AudioGraph.render(state, range: range, sources: sources, ducking: ducking) { buffer in
            let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
            for i in 0..<Int(buffer.frameLength) { meter.process(Double(l[i]), Double(r[i])) }
        }
        return Measurement(integrated: meter.integrated, truePeak: AudioLevel.db(fromLinear: meter.truePeak))
    }

    /// The project as it's measured for a target: only the clip (dry, through a neutral
    /// track) or only the track; the master neutral except for the whole project.
    static func measurementState(_ state: ProjectState, for target: NormalizeTarget) -> (ProjectState, TimeRange)? {
        var measured = state
        switch target {
        case .project:
            return (measured, TimeRange(start: .zero, end: state.duration))
        case .clip(let id):
            guard let index = state.trackIndex(ofClip: id), let clip = state.clip(id) else { return nil }
            let track = state.tracks[index]
            for t in measured.trackIndices(of: .audio) { measured.tracks[t].clips = t == index ? [clip] : [] }
            measured.tracks[index].transitions = []
            measured.tracks[index].audio = .neutral
            measured.tracks[index].isMuted = false
            measured.tracks[index].isSoloed = true
            measured.tracks[index].clips[0].isMuted = false
            measured.audio.master = MasterAudio()
            measured.audio.ducking = nil
            let span = ClipEnvelope(clip, track: track, isActive: true, monoSource: false).span
            return (measured, span)
        case .track(let id):
            guard let index = state.tracks.firstIndex(where: { $0.id == id }) else { return nil }
            for t in measured.trackIndices(of: .audio) where t != index { measured.tracks[t].clips = [] }
            measured.tracks[index].isMuted = false
            measured.tracks[index].isSoloed = true
            measured.audio.master = MasterAudio()
            return (measured, TimeRange(start: .zero, end: state.duration))
        }
    }
}

nonisolated extension ProjectState {
    /// Adds `delta` dB where Normalize puts its gain: the clip gain, the track fader or
    /// the master fader (shifting their keyframes too, so animation is kept).
    mutating func applyNormalizeGain(_ delta: Double, to target: NormalizeTarget) {
        switch target {
        case .clip(let id):
            updateClip(id) { $0.gainDB = min(max($0.gainDB + delta, -60), 40) }
        case .track(let id):
            guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
            tracks[index].audio.volumeDB = AudioParameter.volume.clamped(tracks[index].audio.volumeDB + delta)
            if let frames = tracks[index].audio.keyframes[AudioParameter.volume.id] {
                tracks[index].audio.keyframes[AudioParameter.volume.id] = frames.map {
                    var f = $0
                    f.value = AudioParameter.volume.clamped(f.value + delta)
                    return f
                }
            }
        case .project:
            audio.master.volumeDB = AudioParameter.volume.clamped(audio.master.volumeDB + delta)
            if let frames = audio.master.keyframes[AudioParameter.volume.id] {
                audio.master.keyframes[AudioParameter.volume.id] = frames.map {
                    var f = $0
                    f.value = AudioParameter.volume.clamped(f.value + delta)
                    return f
                }
            }
        }
    }
}

nonisolated enum NormalizeError: LocalizedError {
    case nothingToMeasure
    case tooQuiet

    var errorDescription: String? {
        switch self {
        case .nothingToMeasure: "There's no sound there to measure."
        case .tooQuiet: "It's too quiet to measure (below −70 LUFS)."
        }
    }
}

/// Normalize: measure, adjust the gain, and measure again (effects like compressors
/// aren't linear) until the result is within 0.2 LU of the target.
nonisolated enum Normalizer {
    struct Result: Sendable {
        /// The total gain change, in dB.
        let gainChange: Double
        /// Loudness after normalizing.
        let loudness: Double
        let truePeak: Double
    }

    static func normalize(_ state: ProjectState, _ target: NormalizeTarget, to lufs: Double,
                          sources: [UUID: PreparedAudio]) throws -> Result {
        var working = state
        var total = 0.0
        var last: LoudnessAnalyzer.Measurement?
        for _ in 0..<4 {
            guard let (measured, range) = LoudnessAnalyzer.measurementState(working, for: target), range.duration > .zero else {
                throw NormalizeError.nothingToMeasure
            }
            let ducking = try DuckingAnalyzer.curve(for: working, sources: sources)
            let measurement = try LoudnessAnalyzer.measure(measured, range: range, sources: sources, ducking: ducking)
            guard measurement.integrated > -70 else { throw NormalizeError.tooQuiet }
            last = measurement
            let delta = lufs - measurement.integrated
            if abs(delta) < 0.2 { break }
            working.applyNormalizeGain(delta, to: target)
            total += delta
            // A clip is measured dry, so one step is exact.
            if case .clip = target {
                return Result(gainChange: total, loudness: lufs, truePeak: measurement.truePeak + delta)
            }
        }
        return Result(gainChange: total, loudness: last?.integrated ?? lufs, truePeak: last?.truePeak ?? 0)
    }
}
