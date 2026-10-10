import AppKit

/// Copying clips between the project and its Playground. Copies are snapshots of the
/// clips' values with new IDs: nothing links a copy to its original afterwards.
nonisolated enum ClipTransfer {
    /// Copies `clipIDs` (and their linked partners) from `source` into `target`,
    /// starting at `start` and keeping their relative timing and track order. Each
    /// clip goes on a track of its kind with the same number as in `source` when that
    /// range is free there, otherwise on a new track. Media entries are copied as needed.
    /// Returns the new IDs keyed by the originals.
    @discardableResult
    static func copy(_ clipIDs: Set<UUID>, from source: ProjectState, to target: inout ProjectState,
                     at start: Time, alwaysNewTracks: Bool = false) -> [UUID: UUID] {
        let ids = clipIDs.reduce(into: Set<UUID>()) { $0.formUnion(source.linkedGroup(of: $1)) }
        var items: [(clip: Clip, kind: TrackKind, ordinal: Int)] = []
        for (index, track) in source.tracks.enumerated() {
            for clip in track.clips where ids.contains(clip.id) {
                items.append((clip, track.kind, source.ordinal(ofTrack: index)))
            }
        }
        guard let earliest = items.map(\.clip.start).min() else { return [:] }

        // Media the copies need.
        let mediaIDs = Set(items.map(\.clip.mediaID))
        for media in source.media where mediaIDs.contains(media.id) && !target.media.contains(where: { $0.id == media.id }) {
            target.media.append(media)
        }

        var newIDs: [UUID: UUID] = [:]
        var newLinks: [UUID: UUID] = [:]
        // Clips from one source track stay together on one target track.
        let groups = Dictionary(grouping: items) { "\($0.kind.rawValue)#\($0.ordinal)" }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let kind = group[0].kind, ordinal = group[0].ordinal
            let copies: [Clip] = group.map { item in
                var copy = item.clip
                copy.id = UUID()
                copy.start = start + (item.clip.start - earliest)
                if let link = item.clip.linkID {
                    copy.linkID = newLinks[link] ?? { let new = UUID(); newLinks[link] = new; return new }()
                }
                newIDs[item.clip.id] = copy.id
                return copy
            }
            let candidates = target.trackIndices(of: kind)
            let preferred = alwaysNewTracks ? nil : (ordinal < candidates.count ? candidates[ordinal] : nil)
            let index: Int
            if let preferred, isFree(target.tracks[preferred], for: copies) {
                index = preferred
            } else if !alwaysNewTracks, let free = candidates.first(where: { isFree(target.tracks[$0], for: copies) }) {
                index = free
            } else {
                index = target.appendTrack(kind)
            }
            target.tracks[index].clips.append(contentsOf: copies)
            target.tracks[index].clips.sort { $0.start < $1.start }
        }
        return newIDs
    }

    private static func isFree(_ track: Track, for clips: [Clip]) -> Bool {
        !track.isLocked && !clips.contains { clip in track.clips.contains { $0.range.overlaps(clip.range) } }
    }

    /// The look of a clip — transform, crop, opacity, grade, keyframes and Labs effects —
    /// put onto another clip, keeping that clip's media, timing and name. Keyframes past
    /// its end are dropped.
    static func applySettings(of source: Clip, to target: inout Clip) {
        target.transform = source.transform
        target.crop = source.crop
        target.opacity = source.opacity
        target.color = source.color
        var animation = source.animation
        for (property, frames) in animation.keyframes {
            animation.keyframes[property] = frames.filter { $0.time <= target.duration }
        }
        target.animation = animation
        target.labs = source.labs
    }
}

extension EditorController {
    // MARK: Send to Playground (main editor)

    /// Copies clips (with their grade, effects and keyframes) into the Playground and
    /// shows them there. The project is not changed.
    func sendToPlayground(_ clipIDs: Set<UUID>) {
        guard !isSandbox, !clipIDs.isEmpty else { NSSound.beep(); return }
        let playground = ensurePlayground()
        let sandbox = playground.editor
        let end = sandbox.state.allClips.map(\.end).max() ?? .zero
        let start = end > .zero ? end + Time(seconds: 1) : .zero
        var newIDs: [UUID: UUID] = [:]
        let source = state
        sandbox.store.edit(clipIDs.count == 1 ? "Send Clip to Playground" : "Send Clips to Playground") { scratch in
            newIDs = ClipTransfer.copy(clipIDs, from: source, to: &scratch, at: start)
        }
        for (original, copy) in newIDs { playground.origins[copy] = original }
        workspace = .playground
        sandbox.selection = Set(newIDs.values)
        sandbox.playback.seek(to: start)
    }

    // MARK: Promote to Edit (Playground editor)

    /// The project editor this Playground belongs to.
    var projectEditor: EditorController? { owner }

    /// Adds Playground clips to the project as new clips at its playhead, as one undo
    /// step there, and shows them in Edit.
    func promoteToEdit(_ clipIDs: Set<UUID>) {
        guard isSandbox, let project = owner, !clipIDs.isEmpty else { NSSound.beep(); return }
        let scratch = state
        let at = project.playback.currentTime
        var newIDs: [UUID: UUID] = [:]
        project.store.edit(clipIDs.count == 1 ? "Promote Clip from Playground" : "Promote Clips from Playground") { state in
            newIDs = ClipTransfer.copy(clipIDs, from: scratch, to: &state, at: at)
        }
        project.workspace = .edit
        project.selection = Set(newIDs.values)
    }

    /// The Edit clip a Playground clip was sent from, if it still exists.
    func originalInProject(of clipID: UUID) -> Clip? {
        guard isSandbox, let project = owner, let original = project.playground?.origins[clipID] else { return nil }
        return project.state.clip(original)
    }

    /// The single clip selected in Edit, as a target for applying settings.
    var selectedClipInProject: Clip? {
        guard let project = owner, project.selection.count == 1, let id = project.selection.first,
              let clip = project.state.clip(id), project.state.track(ofClip: id)?.kind.isVisual == true else { return nil }
        return clip
    }

    /// Puts a Playground clip's look onto a project clip, as one undo step in Edit.
    func applySettingsToProject(from clipID: UUID, onto targetID: UUID) {
        guard isSandbox, let project = owner, let source = state.clip(clipID),
              project.state.clip(targetID) != nil, !project.state.isClipLocked(targetID) else { NSSound.beep(); return }
        project.store.edit("Apply Playground Settings") { state in
            state.updateClip(targetID) { ClipTransfer.applySettings(of: source, to: &$0) }
        }
        project.workspace = .edit
        project.selection = [targetID]
    }
}
