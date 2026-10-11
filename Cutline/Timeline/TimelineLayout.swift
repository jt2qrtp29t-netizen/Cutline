import CoreGraphics
import Foundation

/// Maps between timeline time and content coordinates, and between tracks and rows.
///
/// Tracks stack downwards in the order they were added: V1, V2, …, then A1, A2, …,
/// then T1, T2, …. Below each section is a "new track" zone; dragging a clip there
/// creates a track of that kind.
nonisolated struct TimelineLayout: Sendable {
    struct Row: Sendable {
        let trackIndex: Int
        /// Stable identity of the track (indices shift when tracks are deleted).
        let trackID: UUID
        let kind: TrackKind
        let y: CGFloat
        let height: CGFloat
    }

    /// Drop area that creates a new track of `kind`.
    struct NewTrackZone: Sendable {
        let kind: TrackKind
        let y: CGFloat
        let height: CGFloat
    }

    var pixelsPerSecond: Double
    private(set) var rows: [Row] = []
    private(set) var zones: [NewTrackZone] = []
    private(set) var lanesHeight: CGFloat = 0
    private let metrics: (video: CGFloat, audio: CGFloat, text: CGFloat, caption: CGFloat, spacing: CGFloat, zone: CGFloat)

    init(pixelsPerSecond: Double, tracks: [Track],
         videoHeight: CGFloat = 64, audioHeight: CGFloat = 48, textHeight: CGFloat = 40, captionHeight: CGFloat = 34,
         spacing: CGFloat = 2, zoneHeight: CGFloat = 22) {
        self.pixelsPerSecond = pixelsPerSecond
        metrics = (videoHeight, audioHeight, textHeight, captionHeight, spacing, zoneHeight)
        var y: CGFloat = 0
        for kind in TrackKind.allCases {
            let defaultHeight = switch kind {
            case .video: videoHeight
            case .audio: audioHeight
            case .text: textHeight
            case .caption: captionHeight
            }
            for index in tracks.indices where tracks[index].kind == kind {
                let height = tracks[index].height.map { CGFloat($0) } ?? defaultHeight
                rows.append(Row(trackIndex: index, trackID: tracks[index].id, kind: kind, y: y, height: height))
                y += height + spacing
            }
            // Caption tracks are added from the Captions tab, not by dropping clips.
            guard kind.holdsClips else { continue }
            zones.append(NewTrackZone(kind: kind, y: y, height: zoneHeight))
            y += zoneHeight + spacing
        }
        lanesHeight = max(y - spacing, 0)
    }

    /// The same geometry for a different set of tracks (used to resolve drags
    /// against the state at the start of a gesture).
    func with(tracks: [Track]) -> TimelineLayout {
        TimelineLayout(pixelsPerSecond: pixelsPerSecond, tracks: tracks, videoHeight: metrics.video,
                       audioHeight: metrics.audio, textHeight: metrics.text, captionHeight: metrics.caption,
                       spacing: metrics.spacing, zoneHeight: metrics.zone)
    }

    func x(for time: Time) -> CGFloat {
        CGFloat(time.seconds * pixelsPerSecond)
    }

    func width(for duration: Time) -> CGFloat {
        CGFloat(duration.seconds * pixelsPerSecond)
    }

    func time(forX x: CGFloat) -> Time {
        Time(seconds: Double(x) / pixelsPerSecond)
    }

    func duration(forWidth width: CGFloat) -> Time {
        Time(seconds: Double(width) / pixelsPerSecond)
    }

    func row(forTrack index: Int) -> Row? {
        rows.first { $0.trackIndex == index }
    }

    func zone(for kind: TrackKind) -> NewTrackZone? {
        zones.first { $0.kind == kind }
    }

    func laneY(forTrack index: Int) -> CGFloat { row(forTrack: index)?.y ?? 0 }
    func laneHeight(forTrack index: Int) -> CGFloat { row(forTrack: index)?.height ?? 0 }

    /// The row under (or nearest to) a y coordinate in lane space.
    func row(forY y: CGFloat, kind: TrackKind? = nil) -> Row? {
        let candidates = kind.map { k in rows.filter { $0.kind == k } } ?? rows
        if let hit = candidates.first(where: { y >= $0.y && y < $0.y + $0.height }) { return hit }
        return candidates.min { abs($0.y + $0.height / 2 - y) < abs($1.y + $1.height / 2 - y) }
    }

    func trackIndex(forY y: CGFloat, kind: TrackKind? = nil) -> Int? {
        row(forY: y, kind: kind)?.trackIndex
    }

    /// Where a clip of `kind` dragged to `y` should go: the nearest track of that kind,
    /// or a new track once it's dragged past the last one into the zone below.
    func target(forY y: CGFloat, kind: TrackKind) -> TimelineEditing.TrackTarget {
        guard let zone = zone(for: kind) else { return .newTrack(kind) }
        if y >= zone.y || !rows.contains(where: { $0.kind == kind }) { return .newTrack(kind) }
        return row(forY: y, kind: kind).map { .track($0.trackIndex) } ?? .newTrack(kind)
    }

    /// Where a dropped file should go: the row or new-track zone under the pointer.
    func dropTarget(forY y: CGFloat) -> TimelineEditing.TrackTarget? {
        if let zone = zones.first(where: { y >= $0.y && y < $0.y + $0.height }) {
            return .newTrack(zone.kind)
        }
        if let last = zones.last, y >= last.y { return .newTrack(last.kind) }
        return row(forY: y).map { .track($0.trackIndex) }
    }
}

/// Tick spacing for the ruler at a given zoom level.
nonisolated struct RulerScale: Sendable {
    /// Seconds between labelled ticks.
    let major: Double
    /// Seconds between unlabelled ticks; 0 hides them.
    let minor: Double
    let showsFrames: Bool

    init(pixelsPerSecond pps: Double, fps: Int, minimumLabelSpacing: Double = 90) {
        let frame = 1 / Double(fps)
        let frameSteps = [1, 2, 5, 10].map { Double($0) * frame }.filter { $0 < 1 }
        let secondSteps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let candidates = frameSteps + secondSteps
        let major = candidates.first { $0 * pps >= minimumLabelSpacing } ?? secondSteps.last!
        self.major = major
        self.showsFrames = major < 1

        // Subdivide into frames when zoomed in, otherwise into 5 or 2 parts.
        let subdivisions: [Double] = major < 1 ? [major / frame] : [5, 4, 2]
        var minor = 0.0
        for parts in subdivisions where parts > 1 {
            let candidate = major / parts
            if candidate * pps >= 7 { minor = candidate; break }
        }
        self.minor = minor
    }
}
