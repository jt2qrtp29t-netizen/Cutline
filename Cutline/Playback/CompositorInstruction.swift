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

    /// The source frame shown on the main track at a timeline time, and how far toward
    /// the next frame the moment is (0…1). The composition is built from the same numbers.
    static func position(of clip: Clip, at time: Time, frameDuration: Double) -> (frame: Int, fraction: Double) {
        let p = clip.sourceTime(at: time).seconds / frameDuration
        let frame = Int((p + 1e-6).rounded(.down))
        return (frame, min(max(p - Double(frame), 0), 1))
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
