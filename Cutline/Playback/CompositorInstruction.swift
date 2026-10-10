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

    var text: TextStyle? { clip.text }
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
    /// On an open start the layer's clip is the one coming in (from nothing).
    var layerIsIncoming = false

    var incomingLayer: CompositorLayer? {
        incomingClip.map {
            CompositorLayer(trackID: incomingTrackID, clip: $0, sourceTransform: incomingSourceTransform,
                            isOffline: incomingIsOffline)
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
        self.requiredSourceTrackIDs = sources.isEmpty ? nil : sources.map { NSNumber(value: $0) }
        super.init()
    }
}
