import AVFoundation

/// One clip's contribution to a frame. Animated values are evaluated per frame
/// from the clip with `Clip.parameters(at:)`.
nonisolated struct CompositorLayer: Sendable, Equatable {
    /// Source track for media clips; nil for text clips, which are drawn instead.
    var trackID: CMPersistentTrackID?
    var clip: Clip
    /// The source track's preferred transform (rotation metadata from cameras).
    var sourceTransform: CGAffineTransform
    /// Set while this layer's clip is in a transition.
    var transition: TransitionBlend?
    /// The clip's media file is missing; a "Media Offline" slate is drawn instead.
    var isOffline = false
    /// Frame Blend for retimed clips: where the next source frame comes from.
    var retime: RetimedVideo?

    var text: TextStyle? { clip.text }
}

/// A retimed clip's frame-blend source: a second composition track that always shows
/// the source frame after the one on the main track, and the source's frame length, so
/// the compositor can mix them by how far between the two frames the moment is.
nonisolated struct RetimedVideo: Sendable, Equatable {
    var nextFrameTrackID: CMPersistentTrackID
    /// Seconds per source frame.
    var sourceFrameDuration: Double
    /// The straight pieces the clip's timing was built from (see `RetimeSegment`).
    var segments: [RetimeSegment]

    /// How far from the frame on the main track toward the next one (0…1) a timeline
    /// moment is, from the same pieces the composition plays, so picture and mix agree.
    func fraction(at time: Time) -> Double {
        guard let segment = segments.last(where: { $0.timelineStart <= time }) ?? segments.first else { return 0 }
        let p = segment.source(at: time) / sourceFrameDuration
        return min(max(p - p.rounded(.down), 0), 1)
    }
}

/// One straight piece of a clip's timing in the composition: timeline `timelineStart…
/// timelineEnd` plays source seconds `sourceStart…sourceEnd` at an even rate. A constant
/// speed is one piece (exactly as before speed ramps); a ramp is a few pieces that join
/// end to end in the source and stay within a fraction of a frame of the exact curve.
/// Long pieces let the player decode straight through (no restart per frame).
nonisolated struct RetimeSegment: Sendable, Equatable {
    var timelineStart: Time
    var timelineEnd: Time
    var sourceStart: Double
    var sourceEnd: Double

    func source(at time: Time) -> Double {
        let length = (timelineEnd - timelineStart).seconds
        guard length > 0 else { return sourceStart }
        return sourceStart + (time - timelineStart).seconds / length * (sourceEnd - sourceStart)
    }

    /// Straight pieces for `clip` over timeline `from…to`, each a whole number of output
    /// frames, split until every point is within `tolerance` source seconds of the curve.
    static func pieces(for clip: Clip, from: Time, to: Time, frame: Time, tolerance: Double) -> [RetimeSegment] {
        func make(_ a: Time, _ b: Time) -> RetimeSegment {
            RetimeSegment(timelineStart: a, timelineEnd: b, sourceStart: clip.sourceTime(at: a).seconds,
                          sourceEnd: clip.sourceTime(at: b).seconds)
        }
        guard clip.hasSpeedRamp, to > from else { return [make(from, to)] }
        var result: [RetimeSegment] = []
        func refine(_ a: Time, _ b: Time) {
            let piece = make(a, b)
            let frames = (b - a).ticks / max(frame.ticks, 1)
            var worst = 0.0
            for k in 1...7 {
                let t = a + Time(ticks: (b - a).ticks * Int64(k) / 8)
                worst = max(worst, abs(piece.source(at: t) - clip.sourceTime(at: t).seconds))
            }
            if worst <= tolerance || frames < 2 {
                result.append(piece)
                return
            }
            let middle = a + Time(ticks: frame.ticks * (frames / 2))
            refine(a, middle)
            refine(middle, b)
        }
        refine(from, to)
        return result
    }
}

/// A transition from the layer's clip (outgoing) to `incoming`, or, on an open
/// clip edge, between the layer's clip and nothing.
nonisolated struct TransitionBlend: Sendable, Equatable {
    var kind: TransitionKind
    var range: TimeRange
    /// The other clip on a cut; nil on an open edge.
    var incomingTrackID: CMPersistentTrackID?
    var incomingClip: Clip?
    var incomingSourceTransform: CGAffineTransform = .identity
    var incomingIsOffline = false
    var incomingRetime: RetimedVideo?
    /// On an open start the layer's clip is the one coming in (from nothing).
    var layerIsIncoming = false

    var incomingLayer: CompositorLayer? {
        incomingClip.map {
            CompositorLayer(trackID: incomingTrackID, clip: $0, sourceTransform: incomingSourceTransform,
                            isOffline: incomingIsOffline, retime: incomingRetime)
        }
    }

    func progress(at time: Time) -> Double {
        guard range.duration > .zero else { return 1 }
        return (Double((time - range.start).ticks) / Double(range.duration.ticks)).clamped(to: 0...1)
    }
}

/// A time span during which the same set of clips is visible.
/// Layers are ordered bottom (V1) to top.
nonisolated final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let layers: [CompositorLayer]
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?

    init(timeRange: CMTimeRange, layers: [CompositorLayer]) {
        self.timeRange = timeRange
        self.layers = layers
        let sources = layers.compactMap(\.trackID) + layers.compactMap { $0.transition?.incomingTrackID }
            + layers.compactMap { $0.retime?.nextFrameTrackID } + layers.compactMap { $0.transition?.incomingRetime?.nextFrameTrackID }
        self.requiredSourceTrackIDs = sources.isEmpty ? nil : sources.map { NSNumber(value: $0) }
        super.init()
    }
}
