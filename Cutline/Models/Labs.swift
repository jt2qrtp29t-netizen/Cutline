import Foundation

/// One use of a Labs experiment: as an effect on a clip, or as the source of a
/// generator clip. Its parameters use the same keyframes and easing as everything else.
nonisolated struct LabEffect: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    /// The `Experiment.id` this uses.
    var experimentID: String
    var isEnabled = true
    /// Plain parameter values by parameter ID (missing ones use the parameter's default).
    var values: [String: Double] = [:]
    /// Keyframes by parameter ID, timed from the clip's start.
    var keyframes: [String: [Keyframe]] = [:]
    /// Code for experiments that take it (the custom shader).
    var source: String?

    init(experimentID: String, values: [String: Double] = [:]) {
        self.experimentID = experimentID
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        experimentID = try c.decode(String.self, forKey: .experimentID)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        values = try c.decodeIfPresent([String: Double].self, forKey: .values) ?? [:]
        keyframes = try c.decodeIfPresent([String: [Keyframe]].self, forKey: .keyframes) ?? [:]
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    /// A parameter's value `offset` after the clip's start.
    func value(of parameter: String, default fallback: Double, atOffset offset: Time) -> Double {
        if let frames = keyframes[parameter], !frames.isEmpty {
            return ClipAnimation.interpolate(frames, atOffset: offset)
        }
        return values[parameter] ?? fallback
    }

    func isAnimated(_ parameter: String) -> Bool { !(keyframes[parameter]?.isEmpty ?? true) }
}

nonisolated extension LabEffect {
    /// The effect split for blading at `offset` into the clip (see `ClipAnimation.split`).
    func split(at offset: Time) -> (left: LabEffect, right: LabEffect) {
        var left = self, right = self
        right.id = UUID()
        for (parameter, frames) in keyframes where !frames.isEmpty {
            let (l, r) = ClipAnimation.split(frames, at: offset)
            left.keyframes[parameter] = l
            right.keyframes[parameter] = r
        }
        return (left, right)
    }

    /// Keyframes moved by `delta` (when the clip's start is trimmed).
    func shifted(by delta: Time) -> LabEffect {
        var result = self
        for (parameter, frames) in keyframes {
            result.keyframes[parameter] = frames.map { var f = $0; f.time = f.time + delta; return f }
        }
        return result
    }

    mutating func setKeyframe(_ parameter: String, at time: Time, value: Double) {
        keyframes[parameter] = ClipAnimation.setting(keyframes[parameter] ?? [], at: time, value: value)
    }
}
