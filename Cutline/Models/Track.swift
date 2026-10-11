import Foundation

nonisolated enum TrackKind: String, Codable, Sendable, CaseIterable {
    case video, audio, text
    /// Captions worked out from transcripts (the track holds settings, not clips).
    case caption

    var prefix: String {
        switch self {
        case .video: "V"
        case .audio: "A"
        case .text: "T"
        case .caption: "CC"
        }
    }

    var title: String { self == .caption ? "Captions" : rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .text: "textformat"
        case .caption: "captions.bubble"
        }
    }

    /// Video and text tracks hold clips that draw into the picture; muting them hides them.
    /// (Caption tracks draw too, but have no clips of their own.)
    var isVisual: Bool { self == .video || self == .text }

    /// Clips can be placed on the track (caption tracks are worked out, not edited clip by clip).
    var holdsClips: Bool { self != .caption }
}

/// A video or audio track. Clips on one track never overlap and are kept sorted by start time.
/// Among video tracks, array order is layer order: the first video track is the bottom layer.
nonisolated struct Track: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kind: TrackKind = .video
    /// Locked tracks ignore selection, moves, trims, cuts, deletions and drops.
    var isLocked = false
    /// Muted audio tracks are silent; muted video tracks are hidden.
    var isMuted = false
    /// When any track of a kind is soloed, only soloed tracks of that kind play.
    var isSoloed = false
    /// Lane height in points; nil uses the default for the track kind.
    var height: Double?
    var clips: [Clip] = []
    /// Transitions on cuts between this track's clips.
    var transitions: [Transition] = []
    /// Audio tracks: fader, pan and effects.
    var audio = TrackAudio.neutral
    /// Caption tracks: what they caption, how words are grouped, and their style.
    var captions: CaptionSettings?

    static let heightRange: ClosedRange<Double> = 32...220

    init(id: UUID, name: String, kind: TrackKind = .video, isLocked: Bool = false, clips: [Clip] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isLocked = isLocked
        self.clips = clips
    }

    // Older project files have no `kind` / `isLocked`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(TrackKind.self, forKey: .kind) ?? .video
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        height = try c.decodeIfPresent(Double.self, forKey: .height)
        clips = try c.decodeIfPresent([Clip].self, forKey: .clips) ?? []
        transitions = try c.decodeIfPresent([Transition].self, forKey: .transitions) ?? []
        audio = try c.decodeIfPresent(TrackAudio.self, forKey: .audio) ?? .neutral
        captions = try c.decodeIfPresent(CaptionSettings.self, forKey: .captions)
        if kind == .caption && captions == nil { captions = CaptionSettings() }
    }

    mutating func sortClips() {
        clips.sort { $0.start < $1.start }
    }

    func clip(at time: Time) -> Clip? {
        clips.first { $0.range.contains(time) }
    }
}
