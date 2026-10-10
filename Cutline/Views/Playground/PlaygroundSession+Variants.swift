import AppKit

nonisolated extension VariantGroup {
    /// The project as it's drawn with this group compared: in toggle mode only the
    /// active variant shows; in split mode each variant shows its own vertical slice.
    func apply(to state: inout ProjectState) {
        for (index, id) in clipIDs.enumerated() {
            state.updateClip(id) { clip in
                switch compare {
                case .toggle:
                    if index != active { clip.isMuted = true }
                case .split:
                    clip.isMuted = false
                    let n = Double(clipIDs.count)
                    clip.crop.left = max(clip.crop.left, Double(index) / n)
                    clip.crop.right = max(clip.crop.right, 1 - Double(index + 1) / n)
                }
            }
        }
    }
}

extension PlaygroundSession {
    /// Re-applies variant compare and Labs switches to what the Playground shows.
    func updateRenderFilter() {
        let groups = variants
        let disabled = disabledExperiments
        editor.playback.renderFilter = { state in
            // Which variants exist is read from the state being drawn, so undo and
            // deletes are reflected right away.
            var state = state
            for group in PlaygroundState(project: state).withVariants(groups).liveVariants { group.apply(to: &state) }
            if !disabled.isEmpty { state.disableExperiments(disabled) }
            return state
        }
    }

    /// The variant group a clip belongs to.
    func variantGroup(containing clipID: UUID) -> VariantGroup? {
        liveVariants.first { $0.clipIDs.contains(clipID) }
    }

    var liveVariants: [VariantGroup] {
        PlaygroundState(project: editor.state).withVariants(variants).liveVariants
    }

    /// Duplicates a clip into another variant (B, C…) at the same time, on a new track
    /// above. The new variant becomes the one shown.
    @discardableResult
    func makeVariant(of clipID: UUID) -> UUID? {
        guard let clip = editor.state.clip(clipID), let track = editor.state.track(ofClip: clipID), track.kind.isVisual else {
            NSSound.beep(); return nil
        }
        let existing = variantGroup(containing: clipID)
        guard (existing?.clipIDs.count ?? 1) < 26 else { NSSound.beep(); return nil }
        var copy = clip
        copy.id = UUID()
        copy.linkID = nil
        copy.name = clip.name.replacingOccurrences(of: #" \([A-Z]\)$"#, with: "", options: .regularExpression)
            + " (\(VariantGroup.letter(existing?.clipIDs.count ?? 1)))"
        editor.store.edit("Make Variant") { state in
            let index = state.appendTrack(track.kind)
            state.tracks[index].clips.append(copy)
        }
        if var group = existing, let at = variants.firstIndex(where: { $0.id == group.id }) {
            group.clipIDs.append(copy.id)
            group.active = group.clipIDs.count - 1
            variants[at] = group
        } else {
            variants.removeAll { $0.clipIDs.contains(clipID) }
            variants.append(VariantGroup(clipIDs: [clipID, copy.id], active: 1))
        }
        editor.selection = [copy.id]
        updateRenderFilter()
        return copy.id
    }

    func showVariant(_ index: Int, in groupID: UUID) {
        guard let at = variants.firstIndex(where: { $0.id == groupID }) else { return }
        variants[at].active = index
        if variants[at].clipIDs.indices.contains(index) { editor.selection = [variants[at].clipIDs[index]] }
        updateRenderFilter()
    }

    func setCompare(_ compare: VariantGroup.Compare, for groupID: UUID) {
        guard let at = variants.firstIndex(where: { $0.id == groupID }) else { return }
        variants[at].compare = compare
        updateRenderFilter()
    }

    /// Keeps one variant and deletes the others (one undo step), ending the comparison.
    func keepOnly(_ clipID: UUID, in groupID: UUID) {
        guard let group = variants.first(where: { $0.id == groupID }) else { return }
        let others = Set(group.clipIDs).subtracting([clipID])
        let homeTrack = group.clipIDs.first.flatMap { editor.state.track(ofClip: $0)?.id }
        editor.store.edit("Keep Variant") { state in
            for index in state.tracks.indices { state.tracks[index].clips.removeAll { others.contains($0.id) } }
            // The kept variant takes the original's place.
            if let homeTrack, let home = state.tracks.firstIndex(where: { $0.id == homeTrack }),
               let current = state.trackIndex(ofClip: clipID), current != home,
               let kept = state.clip(clipID), !state.tracks[home].clips.contains(where: { $0.range.overlaps(kept.range) }) {
                state.tracks[current].clips.removeAll { $0.id == clipID }
                state.tracks[home].clips.append(kept)
                state.tracks[home].clips.sort { $0.start < $1.start }
            }
            state.removeEmptyExtraTracks()
        }
        variants.removeAll { $0.id == groupID }
        editor.selection = [clipID]
        updateRenderFilter()
    }

    /// Ends a comparison, keeping every variant as an ordinary clip.
    func ungroup(_ groupID: UUID) {
        variants.removeAll { $0.id == groupID }
        updateRenderFilter()
    }

    // MARK: Snapshots

    func saveSnapshot(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let title = trimmed.isEmpty ? "Snapshot \(snapshots.count + 1)" : trimmed
        snapshots.insert(PlaygroundSnapshot(name: title, date: Date(), project: editor.state, variants: liveVariants), at: 0)
    }

    /// Puts the Playground back to a snapshot (undoable in the Playground).
    func restore(_ snapshot: PlaygroundSnapshot) {
        editor.playback.pause()
        editor.selection = []
        editor.selectedKeyframes = []
        editor.store.edit("Restore “\(snapshot.name)”") { $0 = snapshot.project }
        variants = snapshot.variants
        updateRenderFilter()
    }

    func deleteSnapshot(_ id: UUID) {
        snapshots.removeAll { $0.id == id }
    }

    func renameSnapshot(_ id: UUID, to name: String) {
        guard let index = snapshots.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { snapshots[index].name = trimmed }
    }
}

nonisolated extension PlaygroundState {
    func withVariants(_ variants: [VariantGroup]) -> PlaygroundState {
        var copy = self
        copy.variants = variants
        return copy
    }
}

nonisolated extension ProjectState {
    /// Removes empty tracks beyond the first of each kind (left behind by variants).
    mutating func removeEmptyExtraTracks() {
        for kind in [TrackKind.video, .audio, .text] {
            let indices = trackIndices(of: kind)
            for index in indices.dropFirst().reversed() where tracks[index].clips.isEmpty {
                tracks.remove(at: index)
            }
        }
    }

    /// Switches off Labs experiments by ID (effects are skipped, generators hidden).
    mutating func disableExperiments(_ ids: Set<String>) {
        for t in tracks.indices {
            for c in tracks[t].clips.indices {
                for e in tracks[t].clips[c].labs.indices where ids.contains(tracks[t].clips[c].labs[e].experimentID) {
                    tracks[t].clips[c].labs[e].isEnabled = false
                }
                if let generator = tracks[t].clips[c].generator, ids.contains(generator.experimentID) {
                    tracks[t].clips[c].generator?.isEnabled = false
                }
            }
        }
    }
}
