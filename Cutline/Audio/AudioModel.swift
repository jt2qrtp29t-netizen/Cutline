import Foundation

/// Decibels ↔ linear gain, in one place.
nonisolated enum AudioLevel {
    /// Gains at or below this are treated as silence (−∞ dB).
    static let silenceDB = -96.0

    static func linear(fromDB db: Double) -> Double {
        db <= silenceDB ? 0 : pow(10, db / 20)
    }

    static func db(fromLinear gain: Double) -> Double {
        gain <= linear(fromDB: silenceDB) ? silenceDB : 20 * log10(gain)
    }
}

/// The shape of a fade.
nonisolated enum FadeCurve: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Gain rises in a straight line.
    case linear
    /// Constant power through a crossfade (a quarter sine): the usual choice.
    case equalPower
    /// Rises fast and settles gently (log curve).
    case logarithmic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: "Linear"
        case .equalPower: "Equal Power"
        case .logarithmic: "Logarithmic"
        }
    }

    /// Gain of a fade-in at progress `u` (0…1). A fade-out uses `gain(1 - u)`.
    func gain(_ u: Double) -> Double {
        let u = min(max(u, 0), 1)
        switch self {
        case .linear: return u
        case .equalPower: return sin(u * .pi / 2)
        case .logarithmic: return log10(1 + 9 * u)
        }
    }
}

/// A fade at one end of an audio clip.
nonisolated struct AudioFade: Codable, Hashable, Sendable {
    var duration: Time = .zero
    var curve: FadeCurve = .equalPower

    static let off = AudioFade()
    var isActive: Bool { duration > .zero }
}

/// Mixer settings of an audio track: the fader, pan and (later) its effect chain.
nonisolated struct TrackAudio: Codable, Hashable, Sendable {
    /// Fader level in dB (0 = unchanged).
    var volumeDB: Double = 0
    /// −1 = left, 0 = center, 1 = right.
    var pan: Double = 0
    /// The effect chain, in processing order (before the fader).
    var effects: [AudioEffect] = []
    /// The preset the chain was last set from, if any (it may have been edited since).
    var presetName: String?
    /// Keyframes by parameter ID ("volume", "pan", or "<effect ID>/<parameter>"), at timeline times.
    var keyframes: [String: [Keyframe]] = [:]

    static let neutral = TrackAudio()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeDB = try c.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        effects = try c.decodeIfPresent([AudioEffect].self, forKey: .effects) ?? []
        presetName = try c.decodeIfPresent(String.self, forKey: .presetName)
        keyframes = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .keyframes) ?? [:]
    }

    /// An effect parameter's value at a timeline time: its keyframes there, or its plain value.
    func value(of parameter: AudioParameter, in effect: AudioEffect, at time: Time) -> Double {
        if let frames = keyframes[effect.keyframeKey(parameter)], !frames.isEmpty {
            return parameter.clamped(ClipAnimation.interpolate(frames, atOffset: time))
        }
        return effect.value(parameter)
    }
}

/// The master bus.
nonisolated struct MasterAudio: Codable, Hashable, Sendable {
    /// Fader level in dB.
    var volumeDB: Double = 0
    /// A limiter at the end of the mix, keeping peaks under `ceilingDB`.
    var limiterEnabled = false
    var ceilingDB: Double = -1
    /// Keyframes by parameter ID, at timeline times.
    var keyframes: [String: [Keyframe]] = [:]

    static let ceilingRange = -12.0...0.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeDB = try c.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        limiterEnabled = try c.decodeIfPresent(Bool.self, forKey: .limiterEnabled) ?? false
        ceilingDB = try c.decodeIfPresent(Double.self, forKey: .ceilingDB) ?? -1
        keyframes = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .keyframes) ?? [:]
    }
}

/// Lowers a "game" track while a "voice" track is talking. The game track's gain is
/// worked out ahead of time from the voice track's sound, so every playback and every
/// export ducks exactly the same way.
nonisolated struct DuckingSettings: Codable, Hashable, Sendable {
    var isEnabled = true
    var voiceTrackID: UUID
    var gameTrackID: UUID
    /// The voice counts as present above this level.
    var thresholdDB: Double = -40
    /// How far the game track goes down.
    var amountDB: Double = -12
    /// How fast it goes down (it starts this early, so it's down when the voice begins)…
    var attackMS: Double = 80
    /// …and how slowly it comes back after the voice stops.
    var releaseMS: Double = 500

    static let thresholdRange = -70.0...(-10.0)
    static let amountRange = -40.0...0.0
    static let attackRange = 5.0...1000.0
    static let releaseRange = 20.0...4000.0
    /// The voice must be quiet this long before the game comes back up (no pumping between words).
    static let holdMS = 150.0

    init(voiceTrackID: UUID, gameTrackID: UUID) {
        self.voiceTrackID = voiceTrackID
        self.gameTrackID = gameTrackID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        voiceTrackID = try c.decode(UUID.self, forKey: .voiceTrackID)
        gameTrackID = try c.decode(UUID.self, forKey: .gameTrackID)
        thresholdDB = try c.decodeIfPresent(Double.self, forKey: .thresholdDB) ?? -40
        amountDB = try c.decodeIfPresent(Double.self, forKey: .amountDB) ?? -12
        attackMS = try c.decodeIfPresent(Double.self, forKey: .attackMS) ?? 80
        releaseMS = try c.decodeIfPresent(Double.self, forKey: .releaseMS) ?? 500
    }
}

/// Project-wide sound settings.
nonisolated struct ProjectAudio: Codable, Hashable, Sendable {
    var master = MasterAudio()
    /// Normalize's target, in LUFS (−14 suits YouTube).
    var loudnessTarget: Double = -14
    var ducking: DuckingSettings?

    static let loudnessTargets: [(value: Double, title: String)] = [(-14, "−14 LUFS (YouTube)"), (-16, "−16 LUFS")]
    static let loudnessRange = -40.0...(-5.0)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent(MasterAudio.self, forKey: .master) ?? MasterAudio()
        loudnessTarget = try c.decodeIfPresent(Double.self, forKey: .loudnessTarget) ?? -14
        ducking = try c.decodeIfPresent(DuckingSettings.self, forKey: .ducking)
    }
}

nonisolated extension ProjectState {
    /// Clears a ducking setup whose voice or game track no longer exists (or is no longer
    /// an audio track, or both are the same track). Called after every edit.
    mutating func pruneDucking() {
        guard let ducking = audio.ducking else { return }
        let audioIDs = Set(trackIndices(of: .audio).map { tracks[$0].id })
        if !audioIDs.contains(ducking.voiceTrackID) || !audioIDs.contains(ducking.gameTrackID)
            || ducking.voiceTrackID == ducking.gameTrackID {
            audio.ducking = nil
        }
    }
}

/// A track or master parameter that can be keyframed: its ID (the keyframes' key),
/// name, range, default and unit, like the clip parameters of Effects and Color.
nonisolated struct AudioParameter: Hashable, Sendable, Identifiable {
    /// How the value moves along its slider.
    enum Scale: Hashable, Sendable {
        case linear
        /// Frequencies, times and ratios: equal steps are equal ratios.
        case logarithmic
    }

    let id: String
    let title: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let unit: String
    var scale: Scale = .linear

    /// Position along the slider (0…1) and back.
    func position(of value: Double) -> Double {
        let v = clamped(value)
        switch scale {
        case .linear: return (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        case .logarithmic: return log(v / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
    }

    func value(atPosition position: Double) -> Double {
        let p = min(max(position, 0), 1)
        switch scale {
        case .linear: return range.lowerBound + p * (range.upperBound - range.lowerBound)
        case .logarithmic: return range.lowerBound * pow(range.upperBound / range.lowerBound, p)
        }
    }

    /// The value as shown: "4.2 kHz", "−6.0 dB", "120 ms", "3.0:1".
    func label(_ value: Double) -> String {
        switch unit {
        case "Hz": return value >= 1000 ? String(format: "%.1f kHz", value / 1000) : String(format: "%.0f Hz", value)
        case "dB": return String(format: "%.1f dB", value)
        case "ms": return value < 10 ? String(format: "%.1f ms", value) : String(format: "%.0f ms", value)
        case ":1": return String(format: "%.1f:1", value)
        default: return String(format: "%.2f", value)
        }
    }

    static let volume = AudioParameter(id: "volume", title: "Volume", range: -60...12, defaultValue: 0, unit: "dB")
    static let pan = AudioParameter(id: "pan", title: "Pan", range: -1...1, defaultValue: 0, unit: "")

    func clamped(_ value: Double) -> Double { min(max(value, range.lowerBound), range.upperBound) }
}

nonisolated extension Track {
    /// The value of a track parameter at a timeline time: its keyframes there, or the plain value.
    func audioValue(_ parameter: AudioParameter, at time: Time) -> Double {
        if let frames = audio.keyframes[parameter.id], !frames.isEmpty {
            return ClipAnimation.interpolate(frames, atOffset: time)
        }
        switch parameter.id {
        case AudioParameter.volume.id: return audio.volumeDB
        case AudioParameter.pan.id: return audio.pan
        default: return parameter.defaultValue
        }
    }
}

nonisolated extension Clip {
    /// Shortens the fades if they no longer fit the clip (after a trim or cut): together
    /// they never take more than the whole clip.
    mutating func fitFades() {
        let total = fadeIn.duration + fadeOut.duration
        guard total > duration, total > .zero else { return }
        let scale = duration.seconds / total.seconds
        fadeIn.duration = fadeIn.duration.scaled(by: scale)
        fadeOut.duration = duration - fadeIn.duration
        if fadeOut.duration < .zero { fadeOut.duration = .zero }
    }
}
