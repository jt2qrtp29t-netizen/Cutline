import SwiftUI

/// Identifies one keyframe of one parameter of one clip.
struct KeyframeRef: Hashable {
    let clipID: UUID
    let property: AnimatableProperty
    let keyframeID: UUID
}

/// The workspaces in the tab bar under the title bar.
enum Workspace: String, CaseIterable, Identifiable {
    case edit, effects, color, playground, export

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .edit: "scissors"
        case .effects: "sparkles"
        case .color: "paintpalette"
        case .playground: "gamecontroller"
        case .export: "square.and.arrow.up"
        }
    }
}

/// Keyframe editing. Every change goes through the store, so all of it is undoable.
extension EditorController {
    /// The clip the Effects tab works on: exactly one selected video or text clip.
    var effectsClip: Clip? {
        let selected = selectedClips
        guard selected.count == 1, let clip = selected.first,
              let track = state.track(ofClip: clip.id), track.kind.isVisual else { return nil }
        return clip
    }

    /// The playhead's position inside a clip, or nil if the playhead is outside it.
    func playheadOffset(in clip: Clip) -> Time? {
        let offset = playback.currentTime - clip.start
        return offset >= .zero && offset <= clip.duration ? offset.snappedToFrame(fps: fps) : nil
    }

    /// The keyframe of `property` under the playhead, if any.
    func keyframeAtPlayhead(_ property: AnimatableProperty, in clip: Clip) -> Keyframe? {
        guard let offset = playheadOffset(in: clip) else { return nil }
        let half = Time(ticks: Time.frame(fps: fps).ticks / 2)
        return clip.animation.keyframes(for: property).first { abs(($0.time - offset).ticks) <= half.ticks }
    }

    /// Adds a keyframe with the current value at the playhead, or removes the one there.
    func toggleKeyframe(_ property: AnimatableProperty, in clip: Clip) {
        guard let offset = playheadOffset(in: clip) else { NSSound.beep(); return }
        if let existing = keyframeAtPlayhead(property, in: clip) {
            store.edit("Remove Keyframe") { state in
                state.updateClip(clip.id) { $0.animation.removeKeyframe(property, id: existing.id) }
            }
            selectedKeyframes.remove(KeyframeRef(clipID: clip.id, property: property, keyframeID: existing.id))
        } else {
            let value = clip.value(of: property, at: playback.currentTime)
            store.edit("Add Keyframe") { state in
                state.updateClip(clip.id) { $0.animation.setKeyframe(property, at: offset, value: value) }
            }
        }
        effectsProperty = property
    }

    /// Sets a parameter from the Effects panel. An animated parameter gets a keyframe
    /// at the playhead (added if there isn't one); otherwise the plain value changes.
    func setEffectValue(_ property: AnimatableProperty, of clipID: UUID, to value: Double) {
        guard let clip = state.clip(clipID), !state.isClipLocked(clipID) else { NSSound.beep(); return }
        let offset = playheadOffset(in: clip)
        let apply: (inout ProjectState) -> Void = { state in
            state.updateClip(clipID) { clip in
                if clip.isAnimated(property), let offset {
                    clip.animation.setKeyframe(property, at: offset, value: value)
                } else if !clip.isAnimated(property) {
                    clip[keyPath: property.keyPath] = value
                }
            }
        }
        if store.isLiveEditing {
            store.liveEdit(apply)
        } else {
            store.edit("Change \(property.title)", apply)
        }
    }

    /// Moves the playhead to the previous or next keyframe of `property`.
    func jumpToKeyframe(_ property: AnimatableProperty, in clip: Clip, next: Bool) {
        let now = playback.currentTime
        let times = clip.animation.keyframes(for: property).map { clip.start + $0.time }
        let target = next ? times.first { $0 > now + Time(ticks: 1) } : times.last { $0 < now - Time(ticks: 1) }
        guard let target else { NSSound.beep(); return }
        playback.pause()
        playback.seek(to: target, audible: false)
        effectsProperty = property
    }

    func keyframe(_ ref: KeyframeRef) -> Keyframe? {
        state.clip(ref.clipID)?.animation.keyframes(for: ref.property).first { $0.id == ref.keyframeID }
    }

    /// Live-moves keyframes in time while a diamond is dragged (one undo step per drag).
    func dragKeyframes(_ refs: Set<KeyframeRef>, by delta: Time) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        guard let base = store.liveBase else { return }
        let step = delta.snappedToFrame(fps: fps)
        store.liveEdit { state in
            for ref in refs {
                guard let clip = base.clip(ref.clipID),
                      let frame = clip.animation.keyframes(for: ref.property).first(where: { $0.id == ref.keyframeID })
                else { continue }
                let time = (frame.time + step).clamped(.zero, clip.duration)
                state.updateClip(ref.clipID) { clip in
                    guard var frames = clip.animation.keyframes[ref.property],
                          let index = frames.firstIndex(where: { $0.id == ref.keyframeID }) else { return }
                    frames[index].time = time
                    clip.animation.keyframes[ref.property] = frames.sorted { $0.time < $1.time }
                }
            }
        }
    }

    /// Live-sets a keyframe's time and value while it's dragged in the curve editor.
    func dragKeyframe(_ ref: KeyframeRef, toTime time: Time, value: Double) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        store.liveEdit { state in
            state.updateClip(ref.clipID) { clip in
                guard var frames = clip.animation.keyframes[ref.property],
                      let index = frames.firstIndex(where: { $0.id == ref.keyframeID }) else { return }
                frames[index].time = time.snappedToFrame(fps: self.fps).clamped(.zero, clip.duration)
                frames[index].value = value.clamped(to: ref.property.range)
                clip.animation.keyframes[ref.property] = frames.sorted { $0.time < $1.time }
            }
        }
    }

    /// Sets the easing of the segment that starts at a keyframe. `live` is for
    /// dragging Bézier handles (committed with `endGesture`).
    func setEasing(_ easing: Easing, for ref: KeyframeRef, live: Bool = false) {
        let apply: (inout ProjectState) -> Void = { state in
            state.updateClip(ref.clipID) { clip in
                guard var frames = clip.animation.keyframes[ref.property],
                      let index = frames.firstIndex(where: { $0.id == ref.keyframeID }) else { return }
                frames[index].easing = easing
                clip.animation.keyframes[ref.property] = frames
            }
        }
        if live {
            if !store.isLiveEditing { store.beginLiveEdit() }
            store.liveEdit(apply)
        } else {
            store.edit("Change Easing", apply)
        }
    }

    func deleteKeyframes(_ refs: Set<KeyframeRef>) {
        guard !refs.isEmpty else { return }
        store.edit(refs.count == 1 ? "Delete Keyframe" : "Delete Keyframes") { state in
            for ref in refs {
                state.updateClip(ref.clipID) { $0.animation.removeKeyframe(ref.property, id: ref.keyframeID) }
            }
        }
        selectedKeyframes.subtract(refs)
    }

    /// Removes every keyframe of a parameter, keeping the value at the playhead.
    func clearAnimation(_ property: AnimatableProperty, in clip: Clip) {
        let value = clip.value(of: property, at: playback.currentTime)
        store.edit("Remove \(property.title) Animation") { state in
            state.updateClip(clip.id) { clip in
                clip.animation.keyframes[property] = nil
                clip[keyPath: property.keyPath] = value
            }
        }
        selectedKeyframes = selectedKeyframes.filter { !($0.clipID == clip.id && $0.property == property) }
    }

    /// Drops selected keyframes that no longer exist (after undo, delete, blade…).
    func pruneKeyframeSelection() {
        let valid = selectedKeyframes.filter { keyframe($0) != nil && selection.contains($0.clipID) }
        if valid != selectedKeyframes { selectedKeyframes = valid }
    }
}

// MARK: Presets

extension EditorController {
    /// Applies a preset to the given clips (video and text only) as one undo step.
    /// Gameplay presets start at the playhead and skip clips the playhead isn't over.
    func applyPreset(_ preset: AnimationPreset, placement: AnimationPreset.Placement,
                     duration: Double, to ids: Set<UUID>) {
        let targets = ids.filter { id in
            guard let track = state.track(ofClip: id) else { return false }
            return track.kind.isVisual && !state.isClipLocked(id)
        }
        guard !targets.isEmpty else { NSSound.beep(); return }
        let playhead = playback.currentTime
        var applied = false
        store.edit(preset.title(for: placement)) { state in
            for id in targets {
                guard let clip = state.clip(id) else { continue }
                var where_ = placement
                if case .at = placement {
                    let offset = playhead - clip.start
                    guard offset >= .zero, offset < clip.duration else { continue }
                    where_ = .at(offset)
                }
                let updated = preset.apply(to: clip, placement: where_, duration: duration, settings: state.settings)
                state.updateClip(id) { $0 = updated }
                applied = true
            }
        }
        if !applied { NSSound.beep() }
    }
}

// MARK: Transitions

/// Where a dragged transition would land: the cut between two clips, or a clip's
/// open start (no outgoing clip) or end (no incoming clip).
struct TransitionDropTarget: Equatable {
    let trackIndex: Int
    let outgoingID: UUID?
    let incomingID: UUID?
    let cut: Time
}

/// Drag payload for transitions dragged out of the Effects tab.
nonisolated struct TransitionDragItem: Codable, Transferable {
    let kind: TransitionKind

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .cutlineTransition)
    }
}

extension EditorController {
    /// The cut or open clip edge nearest a timeline point on a track, if close enough to drop on.
    func transitionTarget(onTrack index: Int, near time: Time, tolerance: Time) -> TransitionDropTarget? {
        guard state.tracks.indices.contains(index), state.tracks[index].kind.isVisual, !state.tracks[index].isLocked,
              let cut = state.cut(onTrack: index, near: time, tolerance: tolerance) else { return nil }
        return TransitionDropTarget(trackIndex: index, outgoingID: cut.outgoing?.id, incomingID: cut.incoming?.id,
                                    cut: cut.time)
    }

    /// Adds (or replaces) a transition on a cut or open edge and selects it.
    func addTransition(_ kind: TransitionKind, at target: TransitionDropTarget) {
        var id: UUID?
        store.edit("Add \(kind.title)") { state in
            id = state.addTransition(kind, between: target.outgoingID, and: target.incomingID,
                                     duration: Time(seconds: transitionDuration))
        }
        if let id {
            selectedTransition = id
            selection = []
        } else {
            NSSound.beep()
        }
    }

    /// Applies a transition to the cut nearest the playhead (within a second) on the
    /// selected clip's track, or on the first visual track with a cut there.
    func applyTransitionAtPlayhead(_ kind: TransitionKind) {
        let time = playback.currentTime
        let tolerance = Time(seconds: 1)
        var candidates = state.tracks.indices.filter { state.tracks[$0].kind.isVisual }
        if let selected = selectedClips.first, let index = state.trackIndex(ofClip: selected.id) {
            candidates.removeAll { $0 == index }
            candidates.insert(index, at: 0)
        }
        for index in candidates {
            if let target = transitionTarget(onTrack: index, near: time, tolerance: tolerance) {
                addTransition(kind, at: target)
                return
            }
        }
        NSSound.beep()
    }

    /// Selects a transition; its settings show in the inspector and the Effects tab.
    func selectTransition(_ id: UUID) {
        endTextEditing()
        selectedTransition = id
        selection = []
    }

    func setTransitionKind(_ kind: TransitionKind, for id: UUID) {
        store.edit("Change Transition") { state in
            guard let (track, _) = state.transition(id),
                  let index = state.tracks[track].transitions.firstIndex(where: { $0.id == id }) else { return }
            state.tracks[track].transitions[index].kind = kind
        }
    }

    /// Sets a transition's length; `live` while dragging its slider (one undo step per drag).
    func setTransitionDuration(_ duration: Time, for id: UUID) {
        let apply: (inout ProjectState) -> Void = { state in
            guard let (track, _) = state.transition(id),
                  let index = state.tracks[track].transitions.firstIndex(where: { $0.id == id }) else { return }
            state.tracks[track].transitions[index].duration = max(duration, Transition.minimumDuration)
        }
        if store.isLiveEditing { store.liveEdit(apply) } else { store.edit("Change Transition Length", apply) }
        transitionDuration = duration.seconds
    }

    func deleteTransition(_ id: UUID) {
        store.edit("Delete Transition") { state in
            for index in state.tracks.indices { state.tracks[index].transitions.removeAll { $0.id == id } }
        }
        if selectedTransition == id { selectedTransition = nil }
    }
}
