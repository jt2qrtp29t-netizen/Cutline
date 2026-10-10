import AVFoundation

/// One clip's contribution to a frame.
nonisolated struct CompositorLayer: Sendable, Equatable {
    /// Source track for media clips; nil for text clips, which are drawn instead.
    var trackID: CMPersistentTrackID?
    var text: TextStyle?
    var transform: ClipTransform
    var crop: CropInsets
    var opacity: Double
    var color: ColorAdjustments
    /// The source track's preferred transform (rotation metadata from cameras).
    var sourceTransform: CGAffineTransform
    /// Clip timing on the timeline in seconds, for position animation.
    var clipStart: Double
    var clipDuration: Double

    /// 0 at the clip's first frame, 1 at its end.
    func progress(at seconds: Double) -> Double {
        clipDuration > 0 ? ((seconds - clipStart) / clipDuration).clamped(to: 0...1) : 0
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
        let sources = layers.compactMap(\.trackID)
        self.requiredSourceTrackIDs = sources.isEmpty ? nil : sources.map { NSNumber(value: $0) }
        super.init()
    }
}
