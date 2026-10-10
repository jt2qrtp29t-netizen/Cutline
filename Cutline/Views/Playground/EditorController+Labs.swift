import AppKit

extension EditorController {
    /// Adds a generator clip (5 s) at the playhead, on a free video track or a new one.
    func addGenerator(_ experimentID: String) {
        guard let experiment = ExperimentRegistry.experiment(experimentID), experiment.kind == .generator else {
            NSSound.beep(); return
        }
        let start = playback.currentTime.snappedToFrame(fps: fps)
        var clip = Clip(id: UUID(), mediaID: Clip.generatedMediaID, name: experiment.name, start: start,
                        duration: Time(seconds: 5), sourceStart: .zero)
        var generator = LabEffect(experimentID: experiment.id, values: experiment.defaultValues())
        generator.source = experiment.defaultSource
        clip.generator = generator
        store.edit("Add \(experiment.name)") { state in
            let free = state.trackIndices(of: .video).first { index in
                !state.tracks[index].isLocked && !state.tracks[index].clips.contains { $0.range.overlaps(clip.range) }
            }
            let index = free ?? state.appendTrack(.video)
            state.tracks[index].clips.append(clip)
            state.tracks[index].clips.sort { $0.start < $1.start }
        }
        selection = [clip.id]
    }

    /// Adds a Labs effect to the selected visual clips.
    func applyLabEffect(_ experimentID: String, to clipIDs: Set<UUID>) {
        guard let experiment = ExperimentRegistry.experiment(experimentID), experiment.kind == .effect else {
            NSSound.beep(); return
        }
        let targets = clipIDs.filter { state.track(ofClip: $0)?.kind.isVisual == true && !state.isClipLocked($0) }
        guard !targets.isEmpty else { NSSound.beep(); return }
        store.edit("Apply \(experiment.name)") { state in
            for id in targets {
                state.updateClip(id) { clip in
                    var effect = LabEffect(experimentID: experiment.id, values: experiment.defaultValues())
                    effect.source = experiment.defaultSource
                    clip.labs.append(effect)
                }
            }
        }
    }

    /// The Labs item (an effect, or the clip's generator) with this ID.
    func labEffect(_ effectID: UUID, in clip: Clip) -> LabEffect? {
        clip.generator?.id == effectID ? clip.generator : clip.labs.first { $0.id == effectID }
    }

    private func updateLab(_ effectID: UUID, in clipID: UUID, actionName: String, live: Bool = false,
                           _ body: @escaping (inout LabEffect, Time?) -> Void) {
        guard let clip = state.clip(clipID), !state.isClipLocked(clipID) else { NSSound.beep(); return }
        let offset = playheadOffset(in: clip)
        let apply: (inout ProjectState) -> Void = { state in
            state.updateClip(clipID) { clip in
                if clip.generator?.id == effectID {
                    body(&clip.generator!, offset)
                } else if let index = clip.labs.firstIndex(where: { $0.id == effectID }) {
                    body(&clip.labs[index], offset)
                }
            }
        }
        if store.isLiveEditing {
            store.liveEdit(apply)
        } else {
            store.edit(actionName, apply)
        }
    }

    /// Sets a parameter: a keyframe at the playhead if it's animated, else its value.
    func setLabValue(_ value: Double, parameter: String, of effectID: UUID, in clipID: UUID) {
        let name = state.clip(clipID).flatMap { labEffect(effectID, in: $0) }
            .flatMap { ExperimentRegistry.experiment($0.experimentID)?.parameter(parameter)?.name } ?? "Parameter"
        updateLab(effectID, in: clipID, actionName: "Change \(name)") { effect, offset in
            if effect.isAnimated(parameter) {
                if let offset { effect.setKeyframe(parameter, at: offset, value: value) }
            } else {
                effect.values[parameter] = value
            }
        }
    }

    /// The keyframe of a Labs parameter under the playhead, if any.
    func labKeyframeAtPlayhead(_ parameter: String, of effect: LabEffect, in clip: Clip) -> Keyframe? {
        guard let offset = playheadOffset(in: clip) else { return nil }
        let half = Time(ticks: Time.frame(fps: fps).ticks / 2)
        return effect.keyframes[parameter]?.first { abs(($0.time - offset).ticks) <= half.ticks }
    }

    func toggleLabKeyframe(_ parameter: String, of effectID: UUID, in clipID: UUID) {
        guard let clip = state.clip(clipID), let effect = labEffect(effectID, in: clip),
              let experiment = ExperimentRegistry.experiment(effect.experimentID),
              let spec = experiment.parameter(parameter), playheadOffset(in: clip) != nil else { NSSound.beep(); return }
        let existing = labKeyframeAtPlayhead(parameter, of: effect, in: clip)
        let current = effect.value(of: parameter, default: spec.defaultValue, atOffset: playback.currentTime - clip.start)
        updateLab(effectID, in: clipID, actionName: existing == nil ? "Add Keyframe" : "Remove Keyframe") { effect, offset in
            if let existing {
                effect.keyframes[parameter]?.removeAll { $0.id == existing.id }
                if effect.keyframes[parameter]?.isEmpty == true {
                    effect.keyframes[parameter] = nil
                    effect.values[parameter] = current
                }
            } else if let offset {
                effect.setKeyframe(parameter, at: offset, value: current)
            }
        }
    }

    func setLabEnabled(_ enabled: Bool, _ effectID: UUID, in clipID: UUID) {
        updateLab(effectID, in: clipID, actionName: enabled ? "Turn On Effect" : "Turn Off Effect") { effect, _ in
            effect.isEnabled = enabled
        }
    }

    func setLabSource(_ source: String, _ effectID: UUID, in clipID: UUID) {
        updateLab(effectID, in: clipID, actionName: "Edit Shader") { effect, _ in effect.source = source }
    }

    func removeLabEffect(_ effectID: UUID, from clipID: UUID) {
        guard !state.isClipLocked(clipID) else { NSSound.beep(); return }
        store.edit("Remove Effect") { state in
            state.updateClip(clipID) { $0.labs.removeAll { $0.id == effectID } }
        }
    }
}

extension PlaygroundSession {
    func isExperimentEnabled(_ id: String) -> Bool { !disabledExperiments.contains(id) }

    /// Switches an experiment on or off for the whole Playground (off = skipped when drawing).
    func setExperiment(_ id: String, enabled: Bool) {
        if enabled { disabledExperiments.remove(id) } else { disabledExperiments.insert(id) }
        updateRenderFilter()
    }
}
