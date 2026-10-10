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
