import Foundation

/// The effects a track's chain can hold.
nonisolated enum AudioEffectKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case equalizer, compressor, gate, deEsser, limiter, noiseReduction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equalizer: "Equalizer"
        case .compressor: "Compressor"
        case .gate: "Noise Gate"
        case .deEsser: "De-esser"
        case .limiter: "Limiter"
        case .noiseReduction: "Noise Reduction (basic)"
        }
    }

    var symbolName: String {
        switch self {
        case .equalizer: "slider.vertical.3"
        case .compressor: "arrow.down.right.and.arrow.up.left"
        case .gate: "door.left.hand.closed"
        case .deEsser: "mouth"
        case .limiter: "rectangle.compress.vertical"
        case .noiseReduction: "waveform.badge.minus"
        }
    }

    var summary: String {
        switch self {
        case .equalizer: "Low and high cut, a low shelf, two bell bands and a high shelf."
        case .compressor: "Evens out the level: turns down what goes over the threshold."
        case .gate: "Turns the track down while it's quiet, between words or sounds."
        case .deEsser: "Softens harsh “s” and “sh” sounds by turning down only the high end when it's loud."
        case .limiter: "Keeps peaks under the ceiling."
        case .noiseReduction: "A simple multiband gate: each of four bands is turned down while it's below the threshold. It helps with steady hiss or hum between words; it can't remove noise under speech."
        }
    }

    /// The effect's parameters, in the order shown.
    var parameters: [AudioParameter] {
        switch self {
        case .equalizer:
            [AudioParameter(id: "lowCut", title: "Low Cut", range: 20...1000, defaultValue: 20, unit: "Hz", scale: .logarithmic),
             AudioParameter(id: "highCut", title: "High Cut", range: 1000...20_000, defaultValue: 20_000, unit: "Hz", scale: .logarithmic),
             AudioParameter(id: "lowFreq", title: "Low Shelf", range: 30...1000, defaultValue: 120, unit: "Hz", scale: .logarithmic),
             AudioParameter(id: "lowGain", title: "Low Gain", range: -18...18, defaultValue: 0, unit: "dB"),
             AudioParameter(id: "mid1Freq", title: "Mid 1", range: 60...8000, defaultValue: 400, unit: "Hz", scale: .logarithmic),
             AudioParameter(id: "mid1Gain", title: "Mid 1 Gain", range: -18...18, defaultValue: 0, unit: "dB"),
             AudioParameter(id: "mid1Q", title: "Mid 1 Q", range: 0.3...10, defaultValue: 1, unit: "", scale: .logarithmic),
             AudioParameter(id: "mid2Freq", title: "Mid 2", range: 200...16_000, defaultValue: 3000, unit: "Hz", scale: .logarithmic),
             AudioParameter(id: "mid2Gain", title: "Mid 2 Gain", range: -18...18, defaultValue: 0, unit: "dB"),
             AudioParameter(id: "mid2Q", title: "Mid 2 Q", range: 0.3...10, defaultValue: 1, unit: "", scale: .logarithmic),
             AudioParameter(id: "highFreq", title: "High Shelf", range: 1000...18_000, defaultValue: 8000, unit: "Hz", scale: .logarithmic),
             AudioParameter(id: "highGain", title: "High Gain", range: -18...18, defaultValue: 0, unit: "dB")]
        case .compressor:
            [AudioParameter(id: "threshold", title: "Threshold", range: -60...0, defaultValue: -18, unit: "dB"),
             AudioParameter(id: "ratio", title: "Ratio", range: 1...20, defaultValue: 3, unit: ":1", scale: .logarithmic),
             AudioParameter(id: "attack", title: "Attack", range: 0.1...200, defaultValue: 10, unit: "ms", scale: .logarithmic),
             AudioParameter(id: "release", title: "Release", range: 10...2000, defaultValue: 150, unit: "ms", scale: .logarithmic),
             AudioParameter(id: "knee", title: "Knee", range: 0...24, defaultValue: 6, unit: "dB"),
             AudioParameter(id: "makeup", title: "Makeup", range: 0...24, defaultValue: 0, unit: "dB")]
        case .gate:
            [AudioParameter(id: "threshold", title: "Threshold", range: -80...0, defaultValue: -50, unit: "dB"),
             AudioParameter(id: "range", title: "Range", range: -80...0, defaultValue: -40, unit: "dB"),
             AudioParameter(id: "attack", title: "Attack", range: 0.1...50, defaultValue: 1, unit: "ms", scale: .logarithmic),
             AudioParameter(id: "hold", title: "Hold", range: 0...500, defaultValue: 60, unit: "ms"),
             AudioParameter(id: "release", title: "Release", range: 5...1000, defaultValue: 120, unit: "ms", scale: .logarithmic)]
        case .deEsser:
            [AudioParameter(id: "frequency", title: "Frequency", range: 3000...12_000, defaultValue: 6000, unit: "Hz", scale: .logarithmic),
             AudioParameter(id: "threshold", title: "Threshold", range: -60...0, defaultValue: -30, unit: "dB"),
             AudioParameter(id: "amount", title: "Max Reduction", range: 0...24, defaultValue: 8, unit: "dB")]
        case .limiter:
            [AudioParameter(id: "ceiling", title: "Ceiling", range: -24...0, defaultValue: -1, unit: "dB"),
             AudioParameter(id: "release", title: "Release", range: 5...1000, defaultValue: 80, unit: "ms", scale: .logarithmic)]
        case .noiseReduction:
            [AudioParameter(id: "threshold", title: "Threshold", range: -90...(-20), defaultValue: -55, unit: "dB"),
             AudioParameter(id: "amount", title: "Reduction", range: 0...30, defaultValue: 12, unit: "dB"),
             AudioParameter(id: "release", title: "Release", range: 10...1000, defaultValue: 150, unit: "ms", scale: .logarithmic)]
        }
    }

    func parameter(_ id: String) -> AudioParameter? { parameters.first { $0.id == id } }
}

/// One effect in a track's chain.
nonisolated struct AudioEffect: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: AudioEffectKind
    /// Bypassed effects pass the sound through untouched.
    var isBypassed = false
    /// Plain (not keyframed) values by parameter ID; missing ones use the default.
    var values: [String: Double] = [:]

    init(kind: AudioEffectKind, values: [String: Double] = [:]) {
        self.kind = kind
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decode(AudioEffectKind.self, forKey: .kind)
        isBypassed = try c.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
        values = try c.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
    }

    func value(_ parameter: AudioParameter) -> Double {
        parameter.clamped(values[parameter.id] ?? parameter.defaultValue)
    }

    /// The key under which a parameter's keyframes are stored on the track.
    func keyframeKey(_ parameter: AudioParameter) -> String { "\(id.uuidString)/\(parameter.id)" }
}

/// A starting point for a track's chain. Presets write ordinary effects and values,
/// which stay editable afterwards.
nonisolated struct AudioPreset: Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let effects: [AudioEffect]

    static let voice = AudioPreset(
        id: "voice", name: "Voice (commentary)",
        summary: "Cleans up and evens out a voice: low cut, gate, de-mud and presence, compression, de-essing and a limiter.",
        effects: [
            AudioEffect(kind: .noiseReduction, values: ["threshold": -58, "amount": 10, "release": 150]),
            AudioEffect(kind: .gate, values: ["threshold": -48, "range": -24, "attack": 1, "hold": 80, "release": 150]),
            AudioEffect(kind: .equalizer, values: ["lowCut": 90, "mid1Freq": 300, "mid1Gain": -3, "mid1Q": 1.2,
                                                   "mid2Freq": 3500, "mid2Gain": 3, "mid2Q": 1, "highFreq": 10_000, "highGain": 2]),
            AudioEffect(kind: .compressor, values: ["threshold": -22, "ratio": 3, "attack": 8, "release": 120, "knee": 6, "makeup": 6]),
            AudioEffect(kind: .deEsser, values: ["frequency": 6500, "threshold": -30, "amount": 6]),
            AudioEffect(kind: .limiter, values: ["ceiling": -1, "release": 60]),
        ])

    static let game = AudioPreset(
        id: "game", name: "Game audio",
        summary: "Tames the low rumble and the loudest moments, and leaves a little room in the voice range.",
        effects: [
            AudioEffect(kind: .equalizer, values: ["lowCut": 30, "mid2Freq": 2500, "mid2Gain": -2, "mid2Q": 0.8]),
            AudioEffect(kind: .compressor, values: ["threshold": -18, "ratio": 2, "attack": 20, "release": 200, "knee": 8, "makeup": 2]),
            AudioEffect(kind: .limiter, values: ["ceiling": -1, "release": 100]),
        ])

    static let music = AudioPreset(
        id: "music", name: "Music bed",
        summary: "Sits music under speech: a dip in the voice range, gentle compression and a softer top.",
        effects: [
            AudioEffect(kind: .equalizer, values: ["lowCut": 40, "mid2Freq": 2500, "mid2Gain": -4, "mid2Q": 0.7, "highFreq": 8000, "highGain": -1.5]),
            AudioEffect(kind: .compressor, values: ["threshold": -24, "ratio": 2, "attack": 30, "release": 300, "knee": 10, "makeup": 2]),
        ])

    static let radio = AudioPreset(
        id: "radio", name: "Radio / telephone",
        summary: "A narrow, squashed sound: only 300–3400 Hz, with a mid-range push and heavy compression.",
        effects: [
            AudioEffect(kind: .equalizer, values: ["lowCut": 300, "highCut": 3400, "mid1Freq": 1500, "mid1Gain": 5, "mid1Q": 0.8]),
            AudioEffect(kind: .compressor, values: ["threshold": -26, "ratio": 6, "attack": 2, "release": 80, "knee": 3, "makeup": 8]),
            AudioEffect(kind: .limiter, values: ["ceiling": -2, "release": 50]),
        ])

    static let all = [voice, game, music, radio]

    /// The preset's effects with fresh IDs, so every track's chain is its own.
    func makeEffects() -> [AudioEffect] {
        effects.map { var effect = $0; effect.id = UUID(); return effect }
    }
}
