import Foundation

nonisolated struct ClipTransform: Codable, Hashable, Sendable {
    /// Offset from the canvas center in project pixels. +y moves the image down.
    var positionX: Double = 0
    var positionY: Double = 0
    /// When set, the position moves linearly from `positionX/Y` at the clip's
    /// first frame to these values at its last frame. Nil = no movement on that axis.
    var endPositionX: Double?
    var endPositionY: Double?
    /// Zoom; 1.0 = fit to canvas.
    var scale: Double = 1
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
        endPositionX = try c.decodeIfPresent(Double.self, forKey: .endPositionX)
        endPositionY = try c.decodeIfPresent(Double.self, forKey: .endPositionY)
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
        yaw = try c.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
    }

    /// Position at a point in the clip, `progress` running from 0 (first frame) to 1 (last).
    func position(at progress: Double) -> (x: Double, y: Double) {
        let p = progress.clamped(to: 0...1)
        let x = endPositionX.map { positionX + ($0 - positionX) * p } ?? positionX
        let y = endPositionY.map { positionY + ($0 - positionY) * p } ?? positionY
        return (x, y)
    }

    var isAnimated: Bool { endPositionX != nil || endPositionY != nil }
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

nonisolated struct ColorAdjustments: Codable, Hashable, Sendable {
    /// Exposure in stops, -3...3.
    var exposure: Double = 0
    /// -1...1, 0 = unchanged.
    var brightness: Double = 0
    /// 0...2, 1 = unchanged.
    var contrast: Double = 1
    /// 0...2, 1 = unchanged.
    var saturation: Double = 1

    static let neutral = ColorAdjustments()
    var isNeutral: Bool { self == .neutral }
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
    var speed: Double = 1
    var transform: ClipTransform = .identity
    var crop: CropInsets = .none
    var opacity: Double = 1
    var color: ColorAdjustments = .neutral
    /// Linear gain for audio clips; 1 = unchanged.
    var volume: Double = 1
    /// Stereo position for audio clips: -1 = left, 0 = center, 1 = right.
    var pan: Double = 0
    /// Pitch shift for audio clips, independent of speed.
    var pitchSemitones: Double = 0
    var pitchCents: Double = 0
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
        transform = try c.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? .identity
        crop = try c.decodeIfPresent(CropInsets.self, forKey: .crop) ?? .none
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        color = try c.decodeIfPresent(ColorAdjustments.self, forKey: .color) ?? .neutral
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        pan = try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        pitchSemitones = try c.decodeIfPresent(Double.self, forKey: .pitchSemitones) ?? 0
        pitchCents = try c.decodeIfPresent(Double.self, forKey: .pitchCents) ?? 0
        linkID = try c.decodeIfPresent(UUID.self, forKey: .linkID)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try c.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        text = try c.decodeIfPresent(TextStyle.self, forKey: .text)
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
    var sourceDuration: Time { duration.scaled(by: speed) }
    var sourceEnd: Time { sourceStart + sourceDuration }
    /// Total pitch shift in cents (100 per semitone).
    var pitchShiftCents: Double { pitchSemitones * 100 + pitchCents }

    /// Source media time shown at a given timeline time.
    func sourceTime(at timelineTime: Time) -> Time {
        sourceStart + (timelineTime - start).scaled(by: speed)
    }
}
