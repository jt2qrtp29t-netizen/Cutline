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
    /// Keyframes by parameter ID, at timeline times.
    var keyframes: [String: [Keyframe]] = [:]

    static let neutral = TrackAudio()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeDB = try c.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        keyframes = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .keyframes) ?? [:]
    }
}

/// The master bus.
nonisolated struct MasterAudio: Codable, Hashable, Sendable {
    /// Fader level in dB.
    var volumeDB: Double = 0
    /// Keyframes by parameter ID, at timeline times.
    var keyframes: [String: [Keyframe]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeDB = try c.decodeIfPresent(Double.self, forKey: .volumeDB) ?? 0
        keyframes = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .keyframes) ?? [:]
    }
}

/// Project-wide sound settings.
nonisolated struct ProjectAudio: Codable, Hashable, Sendable {
    var master = MasterAudio()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent(MasterAudio.self, forKey: .master) ?? MasterAudio()
    }
}

/// A track or master parameter that can be keyframed: its ID (the keyframes' key),
/// name, range, default and unit, like the clip parameters of Effects and Color.
nonisolated struct AudioParameter: Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let range: ClosedRange<Double>
    let defaultValue: Double
    let unit: String

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
