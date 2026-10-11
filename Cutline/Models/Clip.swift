import Foundation

nonisolated struct ClipTransform: Codable, Hashable, Sendable {
    /// Offset from the canvas center in project pixels. +y moves the image down.
    var positionX: Double = 0
    var positionY: Double = 0
    /// Zoom; 1.0 = fit to canvas.
    var scale: Double = 1
    /// Rotation in degrees, clockwise.
    var rotation: Double = 0
    var flipHorizontal = false
    var flipVertical = false
    /// 3D rotation in degrees around the vertical (yaw) and horizontal (pitch) axes,
    /// with perspective, like Resolve's Yaw / Pitch.
    var yaw: Double = 0
    var pitch: Double = 0

    static let identity = ClipTransform()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positionX = try c.decodeIfPresent(Double.self, forKey: .positionX) ?? 0
        positionY = try c.decodeIfPresent(Double.self, forKey: .positionY) ?? 0
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        yaw = try c.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
    }
}

/// The start/end position animation from v1.3–v2.0 files, read only for conversion.
nonisolated private struct LegacyPositionEnds: Decodable {
    var endPositionX: Double?
    var endPositionY: Double?
}

/// Fraction of the source image removed from each edge (0...1).
nonisolated struct CropInsets: Codable, Hashable, Sendable {
    var top: Double = 0
    var bottom: Double = 0
    var left: Double = 0
    var right: Double = 0

    static let none = CropInsets()
    var isEmpty: Bool { self == .none }
    /// Each pair of opposite edges keeps at least this much of the image.
    static let minimumVisible = 0.05
}

/// A non-destructive window onto a media item, placed on a track. A clip on a
/// video track shows the media's picture; a clip on an audio track plays its sound.
///
/// `duration` is the length on the timeline; the source range consumed is
/// `duration * speed`, starting at `sourceStart`.
nonisolated struct Clip: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var mediaID: UUID
    var name: String
    var start: Time
    var duration: Time
    var sourceStart: Time
    /// Constant speed; with speed keyframes (`animation[.speed]`) the speed follows them.
    var speed: Double = 1
    /// How slowed or sped video shows in-between frames. Clips from before v4.0 keep
    /// Nearest, so they look exactly as they did.
    var retiming = RetimeQuality.frameBlend
    /// Audio keeps its pitch when the speed changes (off: tape-style, pitch follows speed).
    var preservesPitch = true
    var transform: ClipTransform = .identity
    var crop: CropInsets = .none
    /// Feathers the crop edges (0…1): the share of half the visible frame's smaller side
    /// over which the edges fade out.
    var cropSoftness: Double = 0
    var opacity: Double = 1
    /// The clip's color grade (Color tab). Stored as "color" so older projects load.
    var color: ColorGrade = .neutral
    /// Linear gain for audio clips; 1 = unchanged.
    var volume: Double = 1
    /// Stereo position for audio clips: -1 = left, 0 = center, 1 = right.
    var pan: Double = 0
    /// Pitch shift for audio clips, independent of speed.
    var pitchSemitones: Double = 0
    var pitchCents: Double = 0
    /// Clip gain for audio clips, in dB, applied before volume (Normalize sets it).
    var gainDB: Double = 0
    /// Fades at the start and end of audio clips.
    var fadeIn = AudioFade.off
    var fadeOut = AudioFade.off
    /// Clips sharing a link ID select, move, trim, cut and delete together.
    var linkID: UUID?
    /// A locked clip can't be moved, trimmed, cut, deleted, adjusted or overwritten.
    var isLocked = false
    /// Muted clips are silent (audio) or hidden (video).
    var isMuted = false
    /// While any clip of a kind is soloed, only soloed clips of that kind play.
    var isSoloed = false
    /// Set for text clips, which draw text instead of showing a media file.
    var text: TextStyle?
    /// Keyframes for animated parameters.
    var animation = ClipAnimation()
    /// Labs experiments applied to the clip, in order.
    var labs: [LabEffect] = []
    /// Set for generator clips, which draw a Labs generator instead of a media file.
    var generator: LabEffect?

    init(id: UUID, mediaID: UUID, name: String, start: Time, duration: Time, sourceStart: Time) {
        self.id = id
        self.mediaID = mediaID
        self.name = name
        self.start = start
        self.duration = duration
        self.sourceStart = sourceStart
    }

    // Fields added after the first file format are optional when reading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        mediaID = try c.decode(UUID.self, forKey: .mediaID)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(Time.self, forKey: .start)
        duration = try c.decode(Time.self, forKey: .duration)
        sourceStart = try c.decode(Time.self, forKey: .sourceStart)
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        retiming = try c.decodeIfPresent(RetimeQuality.self, forKey: .retiming) ?? .nearest
        preservesPitch = try c.decodeIfPresent(Bool.self, forKey: .preservesPitch) ?? true
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? .identity
        crop = try c.decodeIfPresent(CropInsets.self, forKey: .crop) ?? .none
        cropSoftness = try c.decodeIfPresent(Double.self, forKey: .cropSoftness) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        color = try c.decodeIfPresent(ColorGrade.self, forKey: .color) ?? .neutral
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        pitchSemitones = try c.decodeIfPresent(Double.self, forKey: .pitchSemitones) ?? 0
        pitchCents = try c.decodeIfPresent(Double.self, forKey: .pitchCents) ?? 0
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        fadeIn = try c.decodeIfPresent(AudioFade.self, forKey: .fadeIn) ?? .off
        fadeOut = try c.decodeIfPresent(AudioFade.self, forKey: .fadeOut) ?? .off
        linkID = try c.decodeIfPresent(UUID.self, forKey: .linkID)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        text = try c.decodeIfPresent(TextStyle.self, forKey: .text)
        animation = try c.decodeIfPresent(ClipAnimation.self, forKey: .animation) ?? ClipAnimation()
        labs = try c.decodeIfPresent([LabEffect].self, forKey: .labs) ?? []
        generator = try c.decodeIfPresent(LabEffect.self, forKey: .generator)

        // Older files stored one end position per axis: load it as a two-keyframe
        // animation from the clip's first frame to its last.
        if animation.isEmpty, let legacy = try c.decodeIfPresent(LegacyPositionEnds.self, forKey: .transform) {
            let last = max(duration - Time(ticks: 1), .zero)
            if let end = legacy.endPositionX {
                animation.keyframes[.positionX] = [Keyframe(time: .zero, value: transform.positionX),
                                                   Keyframe(time: last, value: end)]
            }
            if let end = legacy.endPositionY {
                animation.keyframes[.positionY] = [Keyframe(time: .zero, value: transform.positionY),
                                                   Keyframe(time: last, value: end)]
            }
        }
    }

    /// Media ID used by clips that don't come from a file (text).
    static let generatedMediaID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    var isText: Bool { text != nil }

    static func text(at start: Time, duration: Time) -> Clip {
        var clip = Clip(id: UUID(), mediaID: generatedMediaID, name: "Text", start: start,
                        duration: duration, sourceStart: .zero)
        clip.text = TextStyle()
        return clip
    }

    var end: Time { start + duration }
    var range: TimeRange { TimeRange(start: start, end: end) }
    /// Total pitch shift in cents (100 per semitone).
    var pitchShiftCents: Double { pitchSemitones * 100 + pitchCents }
    // Source time, source span and speed over time: Speed.swift (one time-remap function).
}
