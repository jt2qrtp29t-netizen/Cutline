import AVFoundation

/// One clip's contribution to a frame. Animated values are evaluated per frame
/// from the clip with `Clip.parameters(at:)`.
nonisolated struct CompositorLayer: Sendable, Equatable {
    /// Source track for media clips; nil for text clips, which are drawn instead.
    var trackID: CMPersistentTrackID?
    var clip: Clip
    /// The source track's preferred transform (rotation metadata from cameras).
    var sourceTransform: CGAffineTransform

    var text: TextStyle? { clip.text }
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
        let sources = layers.compactMap(\.trackID)
        self.requiredSourceTrackIDs = sources.isEmpty ? nil : sources.map { NSNumber(value: $0) }
        super.init()
    }
}
