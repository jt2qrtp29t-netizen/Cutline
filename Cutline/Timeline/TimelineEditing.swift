import Foundation

/// Pure editing operations on `ProjectState`. Every function here is
/// non-destructive: clips only change which part of their media they show.
///
/// Locked clips and clips on locked tracks are never changed, and nothing may
/// be placed over a locked clip.
nonisolated enum TimelineEditing {
    static let minimumClipTicks: Int64 = Time.ticksPerSecond / 60

    // MARK: Overwrite

    /// Removes, trims or splits clips on a track so that `range` becomes empty.
    static func clear(_ range: TimeRange, onTrack trackIndex: Int, in state: inout ProjectState, excluding excluded: Set<UUID> = []) {
        guard state.tracks.indices.contains(trackIndex), range.duration > .zero else { return }
        var result: [Clip] = []
        for clip in state.tracks[trackIndex].clips {
            guard !excluded.contains(clip.id), clip.range.overlaps(range) else {
                result.append(clip)
                continue
            }
            let coversStart = clip.start >= range.start
            let coversEnd = clip.end <= range.end
            switch (coversStart, coversEnd) {
            case (true, true):
                continue
            case (false, false):
                result.append(trimmedEnd(clip, to: range.start))
                var right = trimmedStart(clip, to: range.end)
                right.id = UUID()
                result.append(right)
            case (false, true):
                result.append(trimmedEnd(clip, to: range.start))
            case (true, false):
                result.append(trimmedStart(clip, to: range.end))
            }
        }
        state.tracks[trackIndex].clips = result
        state.tracks[trackIndex].sortClips()
    }

    /// Whether a clip could be placed on a track without overwriting anything locked.
    static func canPlace(_ range: TimeRange, onTrack trackIndex: Int, in state: ProjectState, excluding excluded: Set<UUID> = []) -> Bool {
        guard state.tracks.indices.contains(trackIndex), !state.tracks[trackIndex].isLocked else { return false }
        return !state.tracks[trackIndex].clips.contains {
            $0.isLocked && !excluded.contains($0.id) && $0.range.overlaps(range)
        }
    }

    /// Places a clip on a track, overwriting whatever it covers.
    /// Refused (returns false) on locked tracks or over locked clips.
    @discardableResult
    static func insert(_ clip: Clip, onTrack trackIndex: Int, in state: inout ProjectState) -> Bool {
        guard canPlace(clip.range, onTrack: trackIndex, in: state, excluding: [clip.id]) else { return false }
        clear(clip.range, onTrack: trackIndex, in: &state, excluding: [clip.id])
        state.tracks[trackIndex].clips.append(clip)
        state.tracks[trackIndex].sortClips()
        return true
    }

    static func makeClip(for media: MediaItem, at start: Time, fps: Int) -> Clip {
        // Floor to a whole frame so the clip never asks for media past the end of the file.
        let frame = Time.frame(fps: fps).ticks
        let frames = max(media.duration.ticks / frame, 1)
        return Clip(
            id: UUID(),
            mediaID: media.id,
            name: media.name,
            start: max(start, .zero),
            duration: Time(ticks: frames * frame),
            sourceStart: .zero
        )
    }

    /// Where a placement or move should go.
    enum TrackTarget: Equatable, Sendable {
        case track(Int)
        /// A new track of this kind, added after the existing ones.
        case newTrack(TrackKind)
    }

    /// Places media at `time`, putting its picture on a video track and its sound on
    /// an audio track as two independent (unlinked) clips. The targeted track receives
    /// the matching part; the other part goes to the paired track of the same number
    /// (V2 ↔ A2), which is created if missing. Returns the new clip IDs.
    @discardableResult
    static func place(_ media: MediaItem, at time: Time, on target: TrackTarget, in state: inout ProjectState) -> [UUID] {
        let targetIndex: Int
        switch target {
        case .track(let index):
            // Media goes on video and audio tracks; text tracks only hold text clips.
            guard state.tracks.indices.contains(index), !state.tracks[index].isLocked,
                  state.tracks[index].kind != .text else { return [] }
            targetIndex = index
        case .newTrack(let kind):
            guard kind != .text else { return [] }
            // A sound-only file dropped on "new video track" still belongs on audio.
            let fits = kind == .video ? media.hasVideo : media.hasAudio
            targetIndex = state.appendTrack(fits ? kind : (kind == .video ? .audio : .video))
        }

        let template = makeClip(for: media, at: time, fps: state.settings.frameRate)
        let targetKind = state.tracks[targetIndex].kind
        let ordinal = state.ordinal(ofTrack: targetIndex)
        var created: [UUID] = []

        for kind in [TrackKind.video, .audio] {
            let wanted = kind == .video ? media.hasVideo : media.hasAudio
            guard wanted else { continue }
            let trackIndex = kind == targetKind ? targetIndex : pairedTrack(kind, ordinal: ordinal, in: &state)
            var clip = template
            clip.id = UUID()
            if insert(clip, onTrack: trackIndex, in: &state) { created.append(clip.id) }
        }
        return created
    }

    @discardableResult
    static func place(_ media: MediaItem, at time: Time, onTrack target: Int, in state: inout ProjectState) -> [UUID] {
        place(media, at: time, on: .track(target), in: &state)
    }

    /// The unlocked track of `kind` with the given number, creating tracks as needed.
    static func pairedTrack(_ kind: TrackKind, ordinal: Int, in state: inout ProjectState) -> Int {
        var list = state.trackIndices(of: kind)
        while list.count <= ordinal {
            state.appendTrack(kind)
            list = state.trackIndices(of: kind)
        }
        if !state.tracks[list[ordinal]].isLocked { return list[ordinal] }
        if let free = list.first(where: { !state.tracks[$0].isLocked }) { return free }
        return state.appendTrack(kind)
    }

    // MARK: Trimming helpers

    /// The clip with its in-point moved so that it starts at `time` (end unchanged).
    static func trimmedStart(_ clip: Clip, to time: Time) -> Clip {
        var c = clip
        c.sourceStart = clip.sourceTime(at: time)
        c.duration = clip.end - time
        c.start = time
        // Keyframes are relative to the clip start; keep them where they were on the timeline.
        c.animation = clip.animation.shifted(by: clip.start - time)
        c.labs = clip.labs.map { $0.shifted(by: clip.start - time) }
        c.generator = clip.generator?.shifted(by: clip.start - time)
        c.fitFades()
        return c
    }

    /// The clip with its out-point moved so that it ends at `time` (start unchanged).
    static func trimmedEnd(_ clip: Clip, to time: Time) -> Clip {
        var c = clip
        c.duration = time - clip.start
        c.fitFades()
        return c
    }

    // MARK: Move

    enum TrackChange: Equatable, Sendable {
        case none
        /// Move by this many tracks of the same kind (V1 → V2 is +1).
        case ordinalDelta(Int)
        /// Move onto a newly created track.
        case newTrack
    }

    /// Moves clips by a time offset, overwriting at the destination. `trackChange`
    /// applies to the clips of `kind` (the kind of clip being dragged); clips of the
    /// other kind (e.g. a linked audio clip) keep their track.
    ///
    /// Locked clips don't move. If the result would overwrite a locked clip or land
    /// on a locked track, nothing changes and false is returned.
    @discardableResult
    static func move(_ ids: Set<UUID>, by delta: Time, trackChange: TrackChange = .none,
                     kind: TrackKind? = nil, in state: inout ProjectState) -> Bool {
        var next = state
        var moving: [(clip: Clip, track: Int)] = []
        for (t, track) in next.tracks.enumerated() where !track.isLocked {
            for clip in track.clips where ids.contains(clip.id) && !clip.isLocked {
                moving.append((clip, t))
            }
        }
        guard !moving.isEmpty else { return false }

        let kinds = Set(moving.map { next.tracks[$0.track].kind })
        let changingKind = kind ?? (kinds.count == 1 ? kinds.first : nil)
        var destinations = moving.map(\.track)

        if let changingKind {
            let changing = moving.indices.filter { next.tracks[moving[$0].track].kind == changingKind }
            switch trackChange {
            case .none:
                break
            case .ordinalDelta(let requested):
                let list = next.trackIndices(of: changingKind)
                let ordinals = changing.map { next.ordinal(ofTrack: moving[$0].track) }
                if let low = ordinals.min(), let high = ordinals.max() {
                    let d = requested.clamped(to: -low...(list.count - 1 - high))
                    for (i, ordinal) in zip(changing, ordinals) { destinations[i] = list[ordinal + d] }
                }
            case .newTrack:
                let newIndex = next.appendTrack(changingKind)
                for i in changing { destinations[i] = newIndex }
            }
        }

        let earliest = moving.map(\.clip.start).min()!
        let clampedDelta = max(delta, -earliest)

        for t in next.tracks.indices {
            next.tracks[t].clips.removeAll { clip in moving.contains { $0.clip.id == clip.id } }
        }
        for (item, destination) in zip(moving, destinations) {
            var clip = item.clip
            clip.start += clampedDelta
            guard insert(clip, onTrack: destination, in: &next) else { return false }
        }
        state = next
        return true
    }

    // MARK: Trim

    /// Bounds for trimming a clip edge: limited by the media and by neighbouring clips.
    static func trimBounds(for clip: Clip, edge: ClipEdge, in state: ProjectState) -> ClosedRange<Time> {
        let minDuration = Time(ticks: minimumClipTicks)
        let neighbours = state.trackIndex(ofClip: clip.id).map { state.tracks[$0].clips } ?? []
        // Text clips have no media, so only their neighbours limit them.
        if clip.isText {
            switch edge {
            case .leading:
                let lower = neighbours.filter { $0.end <= clip.start }.map(\.end).max() ?? .zero
                return lower...(clip.end - minDuration)
            case .trailing:
                let upper = neighbours.filter { $0.start >= clip.end }.map(\.start).min() ?? Time(seconds: 24 * 3600)
                return (clip.start + minDuration)...max(upper, clip.start + minDuration)
            }
        }
        switch edge {
        case .leading:
            let mediaLimit = clip.start - clip.sourceStart.scaled(by: 1 / clip.speed)
            let neighbourLimit = neighbours.filter { $0.end <= clip.start }.map(\.end).max() ?? .zero
            let lower = max(mediaLimit, neighbourLimit, .zero)
            return lower...(clip.end - minDuration)
        case .trailing:
            let mediaDuration = state.mediaItem(clip.mediaID)?.duration ?? clip.sourceEnd
            let mediaLimit = clip.start + (mediaDuration - clip.sourceStart).scaled(by: 1 / clip.speed)
            let neighbourLimit = neighbours.filter { $0.start >= clip.end }.map(\.start).min()
            let upper = min(mediaLimit, neighbourLimit ?? mediaLimit)
            return (clip.start + minDuration)...max(upper, clip.start + minDuration)
        }
    }

    static func trim(_ id: UUID, edge: ClipEdge, to time: Time, in state: inout ProjectState) {
        guard let clip = state.clip(id), !state.isClipLocked(id) else { return }
        let target = time.clamped(to: trimBounds(for: clip, edge: edge, in: state))
        state.updateClip(id) { c in
            c = edge == .leading ? trimmedStart(clip, to: target) : trimmedEnd(clip, to: target)
        }
    }

    /// Sets a clip's length by moving its out-point (limited by media and the next clip).
    static func setDuration(_ duration: Time, for id: UUID, in state: inout ProjectState) {
        guard let clip = state.clip(id) else { return }
        trim(id, edge: .trailing, to: clip.start + duration, in: &state)
    }

    // MARK: Blade

    /// Cuts the given clips (or every clip under the playhead when `ids` is empty)
    /// at `time`. Right-hand pieces of linked clips are linked to each other.
    /// Returns the ids of the newly created right-hand clips.
    @discardableResult
    static func blade(at time: Time, clips ids: Set<UUID>, in state: inout ProjectState) -> [UUID] {
        let minDuration = Time(ticks: minimumClipTicks)
        var created: [UUID] = []
        var relinked: [UUID: UUID] = [:]
        for t in state.tracks.indices where !state.tracks[t].isLocked {
            var result: [Clip] = []
            for clip in state.tracks[t].clips {
                let targeted = ids.isEmpty || ids.contains(clip.id)
                guard targeted, !clip.isLocked,
                      time - clip.start >= minDuration,
                      clip.end - time >= minDuration
                else {
                    result.append(clip)
                    continue
                }
                // Split the animation exactly at the cut so neither half jumps.
                let (leftAnimation, rightAnimation) = clip.animation.split(at: time - clip.start)
                // Fades stay on the outer edges: none at the cut, so the sound runs on through it.
                var whole = clip
                whole.fadeIn = .none
                whole.fadeOut = .none
                var left = trimmedEnd(whole, to: time)
                left.animation = leftAnimation
                left.fadeIn = clip.fadeIn
                left.fitFades()
                var right = trimmedStart(whole, to: time)
                right.animation = rightAnimation
                right.fadeOut = clip.fadeOut
                right.fitFades()
                // Labs parameters split the same way.
                let labs = clip.labs.map { $0.split(at: time - clip.start) }
                left.labs = labs.map(\.left)
                right.labs = labs.map(\.right)
                if let generator = clip.generator?.split(at: time - clip.start) {
                    left.generator = generator.left
                    right.generator = generator.right
                }
                result.append(left)
                right.id = UUID()
                if let link = clip.linkID {
                    if relinked[link] == nil { relinked[link] = UUID() }
                    right.linkID = relinked[link]
                }
                created.append(right.id)
                result.append(right)
                // A transition after this clip now belongs to its right-hand piece.
                for i in state.tracks[t].transitions.indices where state.tracks[t].transitions[i].outgoingClipID == clip.id {
                    state.tracks[t].transitions[i].outgoingClipID = right.id
                }
            }
            state.tracks[t].clips = result
        }
        return created
    }

    // MARK: Delete

    static func delete(_ ids: Set<UUID>, in state: inout ProjectState) {
        for t in state.tracks.indices where !state.tracks[t].isLocked {
            state.tracks[t].clips.removeAll { ids.contains($0.id) && !$0.isLocked }
        }
    }

    /// Removes media items and every clip that uses them.
    static func removeMedia(_ ids: Set<UUID>, in state: inout ProjectState) {
        state.media.removeAll { ids.contains($0.id) }
        for t in state.tracks.indices {
            state.tracks[t].clips.removeAll { ids.contains($0.mediaID) }
        }
    }

    // MARK: Links and locks

    /// Links clips so they select, move, trim, cut and delete together.
    static func link(_ ids: Set<UUID>, in state: inout ProjectState) {
        guard ids.count > 1 else { return }
        let linkID = UUID()
        for id in ids { state.updateClip(id) { $0.linkID = linkID } }
    }

    /// Unlinks every link group touched by `ids`.
    static func unlink(_ ids: Set<UUID>, in state: inout ProjectState) {
        let groups = Set(ids.compactMap { state.clip($0)?.linkID })
        for t in state.tracks.indices {
            for c in state.tracks[t].clips.indices where groups.contains(state.tracks[t].clips[c].linkID ?? UUID()) {
                state.tracks[t].clips[c].linkID = nil
            }
        }
    }

    static func setLocked(_ locked: Bool, clips ids: Set<UUID>, in state: inout ProjectState) {
        for id in ids { state.updateClip(id) { $0.isLocked = locked } }
    }

    // MARK: Speed

    /// Changes playback speed, keeping the start and source in-point fixed.
    /// The duration follows, limited by the media length and the next clip.
    static func setSpeed(_ speed: Double, for id: UUID, in state: inout ProjectState) {
        guard let clip = state.clip(id), !clip.isText, let t = state.trackIndex(ofClip: id), !state.isClipLocked(id) else { return }
        let newSpeed = speed.clamped(to: 0.1...10)
        let source = clip.sourceDuration
        var duration = source.scaled(by: 1 / newSpeed)
        if let next = state.tracks[t].clips.filter({ $0.start >= clip.end }).map(\.start).min() {
            duration = min(duration, next - clip.start)
        }
        if let media = state.mediaItem(clip.mediaID) {
            let maxDuration = (media.duration - clip.sourceStart).scaled(by: 1 / newSpeed)
            duration = min(duration, maxDuration)
        }
        state.updateClip(id) { c in
            c.speed = newSpeed
            c.duration = max(duration, Time(ticks: minimumClipTicks))
        }
    }
}

nonisolated enum ClipEdge: Sendable {
    case leading, trailing
}
