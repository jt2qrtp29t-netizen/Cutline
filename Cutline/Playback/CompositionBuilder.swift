import AVFoundation

/// The parts of the project that change the structure of the composition.
/// When only clip appearance or volume changes, the composition is reused and just
/// the video composition and audio mix are regenerated.
nonisolated struct TimingSignature: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let clipID: UUID
        let mediaID: UUID
        let track: Int
        let kind: TrackKind
        let start: Time
        let duration: Time
        let sourceStart: Time
        let speed: Double
    }

    let entries: [Entry]
    let transitions: [Transition]
    let mediaPaths: [UUID: String]
    let frameRate: Int
    let width: Int
    let height: Int

    init(_ state: ProjectState) {
        entries = state.tracks.enumerated().flatMap { index, track in
            track.clips.map {
                Entry(clipID: $0.id, mediaID: $0.mediaID, track: index, kind: track.kind, start: $0.start,
                      duration: $0.duration, sourceStart: $0.sourceStart, speed: $0.speed)
            }
        }
        transitions = state.tracks.flatMap(\.transitions)
        mediaPaths = Dictionary(uniqueKeysWithValues: state.media.map { ($0.id, $0.path) })
        frameRate = state.settings.frameRate
        width = state.settings.width
        height = state.settings.height
    }
}

/// Builds the video side of playback: an `AVComposition` of the video tracks plus
/// the compositor instructions. Sound is rendered separately by `AudioRenderer`
/// from the audio tracks, so pitch, pan and per-track mute/solo can be applied.
nonisolated enum CompositionBuilder {
    struct Output: @unchecked Sendable {
        let composition: AVComposition
        /// Nil when there is nothing on any video track.
        let videoComposition: AVVideoComposition?
        let duration: Time
        /// Composition track ID for each timeline track index (video and audio).
        let trackIDs: [Int: CMPersistentTrackID]
        /// Preferred transform of each media item's video track.
        let sourceTransforms: [UUID: CGAffineTransform]
    }

    enum BuildError: LocalizedError {
        case insertFailed(clip: String, kind: String, range: TimeRange, at: Time, underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .insertFailed(clip, kind, range, at, underlying):
                "Couldn’t add \(kind) of “\(clip)” (\(range.start.seconds)–\(range.end.seconds)s at \(at.seconds)s): \(underlying.localizedDescription)"
            }
        }
    }

    private struct Source {
        /// Tracks only weakly reference their asset, so the asset must be kept alive.
        let asset: AVURLAsset
        let video: AVAssetTrack?
        let transform: CGAffineTransform
    }

    /// - Parameter urls: resolved file URLs for each media item.
    static func build(_ state: ProjectState, urls: [UUID: URL]) async throws -> Output {
        let usedMedia = Set(state.allClips.map(\.mediaID))
        var sources: [UUID: Source] = [:]
        for media in state.media where usedMedia.contains(media.id) {
            guard let url = urls[media.id] else { continue }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let video = try? await asset.loadTracks(withMediaType: .video).first
            var transform = CGAffineTransform.identity
            if let video, let loaded = try? await video.load(.preferredTransform) { transform = loaded }
            sources[media.id] = Source(asset: asset, video: video, transform: transform)
        }

        let composition = AVMutableComposition()
        var trackIDs: [Int: CMPersistentTrackID] = [:]

        for (index, track) in state.tracks.enumerated() where track.kind == .video && !track.clips.isEmpty {
            guard let compositionTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            var cursor = Time.zero
            var inserted = false

            for clip in track.clips.sorted(by: { $0.start < $1.start }) {
                guard let source = sources[clip.mediaID], let sourceTrack = source.video else { continue }
                let sourceRange = try await availableRange(for: clip, in: sourceTrack)
                guard sourceRange.duration > .zero else { continue }

                if clip.start > cursor {
                    compositionTrack.insertEmptyTimeRange(TimeRange(start: cursor, end: clip.start).cmTimeRange)
                }
                do {
                    try compositionTrack.insertTimeRange(sourceRange.cmTimeRange, of: sourceTrack, at: clip.start.cmTime)
                } catch {
                    throw BuildError.insertFailed(clip: clip.name, kind: track.kind.rawValue, range: sourceRange,
                                                  at: clip.start, underlying: error)
                }
                if sourceRange.duration != clip.duration {
                    compositionTrack.scaleTimeRange(CMTimeRange(start: clip.start.cmTime, duration: sourceRange.duration.cmTime),
                                                    toDuration: clip.duration.cmTime)
                }
                cursor = clip.end
                inserted = true
            }

            if inserted {
                trackIDs[index] = compositionTrack.trackID
            } else {
                composition.removeTrack(compositionTrack)
            }
        }

        // The player's clock must run for the whole timeline, including audio that
        // extends past the last video clip, so stretch a black frame across it.
        // The compositor never draws this track; gaps still render black.
        let duration = state.duration
        var filler: (asset: AVURLAsset, track: AVAssetTrack)?
        if duration > .zero, Time(composition.duration) < duration,
           let black = try? await BlackFrameSource.videoTrack(),
           let fillerTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            filler = black
            let range = try await black.track.load(.timeRange)
            try fillerTrack.insertTimeRange(range, of: black.track, at: .zero)
            fillerTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration), toDuration: duration.cmTime)
        }
        withExtendedLifetime(filler) {}

        let transforms = sources.compactMapValues { $0.video == nil ? nil : $0.transform }
        let videoComposition = duration > .zero
            ? makeVideoComposition(for: state, duration: duration, trackIDs: trackIDs, sourceTransforms: transforms)
            : nil
        return Output(composition: composition, videoComposition: videoComposition, duration: duration,
                      trackIDs: trackIDs, sourceTransforms: transforms)
    }

    /// Source range of a clip, clipped to what the media track actually contains.
    private static func availableRange(for clip: Clip, in track: AVAssetTrack) async throws -> TimeRange {
        let trackRange = try await track.load(.timeRange)
        let available = TimeRange(start: Time(trackRange.start), end: Time(trackRange.end))
        let start = max(clip.sourceStart, available.start)
        let end = min(clip.sourceEnd, available.end)
        return TimeRange(start: start, end: max(start, end))
    }

    /// Splits the timeline at every video clip boundary and describes which clips
    /// are visible in each span. Spans are contiguous from zero to `duration`, as
    /// AVFoundation requires.
    static func makeVideoComposition(
        for state: ProjectState,
        duration: Time,
        trackIDs: [Int: CMPersistentTrackID],
        sourceTransforms: [UUID: CGAffineTransform]
    ) -> AVVideoComposition {
        // Video tracks bottom to top, then text tracks above them (T1, then T2 on top).
        let videoTracks = state.trackIndices(of: .video) + state.trackIndices(of: .text)
        var boundaries = Set<Time>([.zero, duration])
        for index in videoTracks {
            for clip in state.tracks[index].clips {
                boundaries.insert(clip.start)
                boundaries.insert(clip.end)
            }
        }
        let sorted = boundaries.filter { $0 <= duration }.sorted()

        var instructions: [CompositorInstruction] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            let span = TimeRange(start: start, end: end)
            var layers: [CompositorLayer] = []
            for index in videoTracks {
                guard let clip = state.tracks[index].clips.first(where: { $0.range.overlaps(span) }),
                      state.isClipActive(clip, onTrack: index)
                else { continue }
                if clip.isText {
                    layers.append(CompositorLayer(trackID: nil, clip: clip, sourceTransform: .identity))
                    continue
                }
                guard let trackID = trackIDs[index], let transform = sourceTransforms[clip.mediaID] else { continue }
                layers.append(CompositorLayer(trackID: trackID, clip: clip, sourceTransform: transform))
            }
            instructions.append(CompositorInstruction(timeRange: span.cmTimeRange, layers: layers))
        }

        let configuration = AVVideoComposition.Configuration(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: LayerCompositor.self,
            frameDuration: state.settings.frameDuration.cmTime,
            instructions: instructions,
            renderSize: state.settings.renderSize
        )
        return AVVideoComposition(configuration: configuration)
    }
}
