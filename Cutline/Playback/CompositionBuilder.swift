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
        /// Composition track holding each video clip. Clips on a track with transitions
        /// alternate between two composition tracks (A/B roll) so they can overlap.
        let clipTrackIDs: [UUID: CMPersistentTrackID]
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
        var clipTrackIDs: [UUID: CMPersistentTrackID] = [:]
        let frame = state.settings.frameDuration

        for track in state.tracks where track.kind == .video && !track.clips.isEmpty {
            // Transitions need the outgoing and incoming clips at the same time, so a
            // track with transitions alternates its clips between two composition tracks.
            let rolls = track.placedTransitions().isEmpty ? 1 : 2
            var lanes: [(track: AVMutableCompositionTrack, cursor: Time, used: Bool)] = []
            for _ in 0..<rolls {
                guard let added = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { continue }
                lanes.append((added, .zero, false))
            }
            guard !lanes.isEmpty else { continue }

            for (position, clip) in track.clips.sorted(by: { $0.start < $1.start }).enumerated() {
                guard let source = sources[clip.mediaID], let sourceTrack = source.video else { continue }
                let lane = position % lanes.count
                let handles = track.transitionHandles(for: clip.id)
                var cursor = lanes[lane].cursor
                let inserted = try await insert(clip, lead: handles.lead, tail: handles.tail, from: sourceTrack,
                                                into: lanes[lane].track, cursor: &cursor, frame: frame)
                lanes[lane].cursor = cursor
                if inserted {
                    lanes[lane].used = true
                    clipTrackIDs[clip.id] = lanes[lane].track.trackID
                }
            }
            for lane in lanes where !lane.used { composition.removeTrack(lane.track) }
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
            ? makeVideoComposition(for: state, duration: duration, clipTrackIDs: clipTrackIDs, sourceTransforms: transforms)
            : nil
        return Output(composition: composition, videoComposition: videoComposition, duration: duration,
                      clipTrackIDs: clipTrackIDs, sourceTransforms: transforms)
    }

    /// Inserts a clip's media at its place on the timeline, extended by `lead` before
    /// its start and `tail` after its end (transition handles). Media the file doesn't
    /// have is filled by holding its first or last frame. Returns false if nothing
    /// could be inserted.
    private static func insert(_ clip: Clip, lead: Time, tail: Time, from sourceTrack: AVAssetTrack,
                               into track: AVMutableCompositionTrack, cursor: inout Time, frame: Time) async throws -> Bool {
        let trackRange = try await sourceTrack.load(.timeRange)
        let available = TimeRange(start: Time(trackRange.start), end: Time(trackRange.end))
        guard available.duration > .zero else { return false }

        let timelineStart = clip.start - lead
        let timelineEnd = clip.end + tail
        let wantedStart = clip.sourceStart - lead.scaled(by: clip.speed)
        let wantedEnd = clip.sourceEnd + tail.scaled(by: clip.speed)
        let mainStart = max(wantedStart, available.start)
        let mainEnd = min(wantedEnd, available.end)
        guard mainEnd > mainStart else { return false }
        // Timeline time covered by held frames before and after the real media.
        let headHold = (mainStart - wantedStart).scaled(by: 1 / clip.speed)
        let tailHold = (wantedEnd - mainEnd).scaled(by: 1 / clip.speed)

        if timelineStart > cursor {
            track.insertEmptyTimeRange(TimeRange(start: cursor, end: timelineStart).cmTimeRange)
        }
        var at = timelineStart
        func place(_ range: TimeRange, lasting length: Time) throws {
            guard length > .zero, range.duration > .zero else { return }
            do {
                try track.insertTimeRange(range.cmTimeRange, of: sourceTrack, at: at.cmTime)
            } catch {
                throw BuildError.insertFailed(clip: clip.name, kind: "video", range: range, at: at, underlying: error)
            }
            if range.duration != length {
                track.scaleTimeRange(CMTimeRange(start: at.cmTime, duration: range.duration.cmTime), toDuration: length.cmTime)
            }
            at += length
        }
        let holdFrame = min(frame, available.duration)
        try place(TimeRange(start: available.start, end: available.start + holdFrame), lasting: headHold)
        let mainLength = (timelineEnd - tailHold) - at
        try place(TimeRange(start: mainStart, end: mainEnd), lasting: mainLength)
        try place(TimeRange(start: available.end - holdFrame, end: available.end), lasting: timelineEnd - at)
        cursor = timelineEnd
        return true
    }

    /// Splits the timeline at every video clip boundary and describes which clips
    /// are visible in each span. Spans are contiguous from zero to `duration`, as
    /// AVFoundation requires.
    static func makeVideoComposition(
        for state: ProjectState,
        duration: Time,
        clipTrackIDs: [UUID: CMPersistentTrackID],
        sourceTransforms: [UUID: CGAffineTransform]
    ) -> AVVideoComposition {
        // Video tracks bottom to top, then text tracks above them (T1, then T2 on top).
        let visualTracks = state.trackIndices(of: .video) + state.trackIndices(of: .text)
        let transitions = Dictionary(uniqueKeysWithValues: visualTracks.map { ($0, state.tracks[$0].placedTransitions()) })
        var boundaries = Set<Time>([.zero, duration])
        for index in visualTracks {
            for clip in state.tracks[index].clips {
                boundaries.insert(clip.start)
                boundaries.insert(clip.end)
            }
            for placed in transitions[index] ?? [] {
                boundaries.insert(placed.range.start)
                boundaries.insert(placed.range.end)
            }
        }
        let sorted = boundaries.filter { $0 >= .zero && $0 <= duration }.sorted()

        /// The layer for a clip, or nil if it has nothing to show. Video clips that
        /// didn't make it into the composition (their file is missing) show a slate.
        func layer(for clip: Clip, onTrack index: Int) -> CompositorLayer? {
            guard state.isClipActive(clip, onTrack: index) else { return nil }
            if clip.isText || clip.generator != nil {
                return CompositorLayer(trackID: nil, clip: clip, sourceTransform: .identity)
            }
            guard let trackID = clipTrackIDs[clip.id], let transform = sourceTransforms[clip.mediaID] else {
                return CompositorLayer(trackID: nil, clip: clip, sourceTransform: .identity, isOffline: true)
            }
            return CompositorLayer(trackID: trackID, clip: clip, sourceTransform: transform)
        }

        var instructions: [CompositorInstruction] = []
        for (start, end) in zip(sorted, sorted.dropFirst()) where end > start {
            let span = TimeRange(start: start, end: end)
            var layers: [CompositorLayer] = []
            for index in visualTracks {
                if let placed = transitions[index]?.first(where: { span.start >= $0.range.start && span.end <= $0.range.end }) {
                    let outgoing = placed.outgoing.flatMap { layer(for: $0, onTrack: index) }
                    let incoming = placed.incoming.flatMap { layer(for: $0, onTrack: index) }
                    switch (outgoing, incoming) {
                    case let (outgoing?, incoming?):
                        var mixed = outgoing
                        mixed.transition = TransitionBlend(kind: placed.transition.kind, range: placed.range,
                                                           incomingTrackID: incoming.trackID, incomingClip: incoming.clip,
                                                           incomingSourceTransform: incoming.sourceTransform,
                                                           incomingIsOffline: incoming.isOffline)
                        layers.append(mixed)
                    case let (single?, nil), let (nil, single?):
                        if placed.isEdge {
                            // From or to nothing on an open edge.
                            var mixed = single
                            mixed.transition = TransitionBlend(kind: placed.transition.kind, range: placed.range,
                                                               layerIsIncoming: placed.outgoing == nil)
                            layers.append(mixed)
                        } else if single.clip.range.overlaps(span) {
                            // One side of a cut is muted: show the other on its own side.
                            layers.append(single)
                        }
                    case (nil, nil):
                        break
                    }
                    continue
                }
                guard let clip = state.tracks[index].clips.first(where: { $0.range.overlaps(span) }),
                      let single = layer(for: clip, onTrack: index) else { continue }
                layers.append(single)
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
