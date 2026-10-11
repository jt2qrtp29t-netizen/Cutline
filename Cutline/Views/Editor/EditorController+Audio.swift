import AppKit
import Synchronization

/// Mixer edits. A fader or pan drag is one live edit (one undo step); clicks are single edits.
extension EditorController {
    /// The audio tracks, in timeline order.
    var audioTrackIndices: [Int] { state.trackIndices(of: .audio) }

    /// A track parameter's value at the playhead (its keyframes there, or its plain value).
    func trackAudioValue(_ parameter: AudioParameter, track id: UUID) -> Double {
        guard let track = state.tracks.first(where: { $0.id == id }) else { return parameter.defaultValue }
        return track.audioValue(parameter, at: playback.currentTime)
    }

    func masterVolume() -> Double {
        let frames = state.audio.master.keyframes[AudioParameter.volume.id] ?? []
        return frames.isEmpty ? state.audio.master.volumeDB : ClipAnimation.interpolate(frames, atOffset: playback.currentTime)
    }

    /// Sets a track parameter during a drag. A keyframed parameter gets a keyframe at the
    /// playhead; otherwise the plain value changes. Call `endAudioAdjustment` when done.
    func adjustTrackAudio(_ parameter: AudioParameter, to value: Double, track id: UUID) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        let value = parameter.clamped(value)
        let time = playback.currentTime.snappedToFrame(fps: fps)
        store.liveEdit { state in
            guard let index = state.tracks.firstIndex(where: { $0.id == id }) else { return }
            state.tracks[index].audio.set(parameter, value, at: time)
        }
    }

    func adjustMasterVolume(to value: Double) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        let value = AudioParameter.volume.clamped(value)
        let time = playback.currentTime.snappedToFrame(fps: fps)
        store.liveEdit { state in
            if let frames = state.audio.master.keyframes[AudioParameter.volume.id], !frames.isEmpty {
                state.audio.master.keyframes[AudioParameter.volume.id] = ClipAnimation.setting(frames, at: time, value: value)
            } else {
                state.audio.master.volumeDB = value
            }
        }
    }

    func endAudioAdjustment(_ actionName: String) {
        store.commitLiveEdit(actionName)
    }

    /// Puts a track parameter back to its default (double-click), as one undo step.
    func resetTrackAudio(_ parameter: AudioParameter, track id: UUID) {
        let time = playback.currentTime.snappedToFrame(fps: fps)
        store.edit("Reset \(parameter.title)") { state in
            guard let index = state.tracks.firstIndex(where: { $0.id == id }) else { return }
            state.tracks[index].audio.set(parameter, parameter.defaultValue, at: time)
        }
    }

    func resetMasterVolume() {
        store.edit("Reset Master Volume") { state in
            if let frames = state.audio.master.keyframes[AudioParameter.volume.id], !frames.isEmpty {
                state.audio.master.keyframes[AudioParameter.volume.id] = ClipAnimation.setting(
                    frames, at: playback.currentTime.snappedToFrame(fps: fps), value: 0)
            } else {
                state.audio.master.volumeDB = 0
            }
        }
    }

    func toggleMute(track id: UUID) {
        if let index = state.tracks.firstIndex(where: { $0.id == id }) { toggleMute(trackAt: index) }
    }

    func toggleSolo(track id: UUID) {
        if let index = state.tracks.firstIndex(where: { $0.id == id }) { toggleSolo(trackAt: index) }
    }
}

nonisolated extension TrackAudio {
    /// Sets a parameter: a keyframe at `time` if it's animated, otherwise its plain value.
    mutating func set(_ parameter: AudioParameter, _ value: Double, at time: Time) {
        if let frames = keyframes[parameter.id], !frames.isEmpty {
            keyframes[parameter.id] = ClipAnimation.setting(frames, at: time, value: value)
            return
        }
        switch parameter.id {
        case AudioParameter.volume.id: volumeDB = value
        case AudioParameter.pan.id: pan = value
        default: break
        }
    }
}

// MARK: - Clip tools: gain, fades and crossfades

extension EditorController {
    /// Sets a clip's fade length during a drag of its fade handle (one undo step per
    /// drag; call `endAudioAdjustment`). The two fades together never exceed the clip.
    func adjustFade(_ edge: ClipEdge, of id: UUID, to duration: Time) {
        guard !state.isClipLocked(id) else { return }
        if !store.isLiveEditing { store.beginLiveEdit() }
        store.liveEdit { state in
            state.updateClip(id) { clip in
                let other = edge == .leading ? clip.fadeOut.duration : clip.fadeIn.duration
                let length = min(max(duration, .zero), max(clip.duration - other, .zero))
                if edge == .leading { clip.fadeIn.duration = length } else { clip.fadeOut.duration = length }
            }
        }
    }

    /// Sets a fade's length in one step (menus and the inspector).
    func setFade(_ edge: ClipEdge, of ids: Set<UUID>, to duration: Time) {
        store.edit(duration > .zero ? "Change Fade" : "Remove Fade") { state in
            for id in ids where !state.isClipLocked(id) {
                state.updateClip(id) { clip in
                    let other = edge == .leading ? clip.fadeOut.duration : clip.fadeIn.duration
                    let length = min(max(duration, .zero), max(clip.duration - other, .zero))
                    if edge == .leading { clip.fadeIn.duration = length } else { clip.fadeOut.duration = length }
                }
            }
        }
    }

    func setFadeCurve(_ edge: ClipEdge, of ids: Set<UUID>, to curve: FadeCurve) {
        store.edit("Change Fade Curve") { state in
            for id in ids where !state.isClipLocked(id) {
                state.updateClip(id) { clip in
                    if edge == .leading { clip.fadeIn.curve = curve } else { clip.fadeOut.curve = curve }
                }
            }
        }
    }

    /// The touching clip before or after an audio clip on its track.
    func neighbor(of id: UUID, after: Bool) -> Clip? {
        guard let index = state.trackIndex(ofClip: id), state.tracks[index].kind == .audio,
              let clip = state.clip(id) else { return nil }
        return state.tracks[index].clips.first { after ? $0.start == clip.end : $0.end == clip.start }
    }

    /// Crossfades an audio clip with the touching clip before or after it, and selects the crossfade.
    func addCrossfade(to id: UUID, after: Bool) {
        guard let other = neighbor(of: id, after: after) else { NSSound.beep(); return }
        var created: UUID?
        store.edit("Add Crossfade") { state in
            created = after ? state.addCrossfade(between: id, and: other.id) : state.addCrossfade(between: other.id, and: id)
        }
        if let created { selectTransition(created) } else { NSSound.beep() }
    }

    func setCrossfadeCurve(_ curve: FadeCurve, for id: UUID) {
        store.edit("Change Crossfade Curve") { state in
            guard let (track, _) = state.transition(id),
                  let index = state.tracks[track].transitions.firstIndex(where: { $0.id == id }) else { return }
            state.tracks[track].transitions[index].curve = curve
        }
    }
}

// MARK: - Track effect chains

/// A keyframable track parameter: the track's volume or pan, or an effect parameter.
nonisolated struct TrackParameterRef: Hashable, Sendable {
    let trackID: UUID
    /// Keyframe key on the track: "volume", "pan" or "<effect ID>/<parameter>".
    let key: String
    let parameter: AudioParameter
    let effectID: UUID?

    static func volume(_ track: UUID) -> TrackParameterRef { TrackParameterRef(trackID: track, key: AudioParameter.volume.id, parameter: .volume, effectID: nil) }
    static func pan(_ track: UUID) -> TrackParameterRef { TrackParameterRef(trackID: track, key: AudioParameter.pan.id, parameter: .pan, effectID: nil) }
    static func effect(_ effect: AudioEffect, _ parameter: AudioParameter, track: UUID) -> TrackParameterRef {
        TrackParameterRef(trackID: track, key: effect.keyframeKey(parameter), parameter: parameter, effectID: effect.id)
    }
}

nonisolated extension TrackAudio {
    /// Sets a parameter: a keyframe at `time` if it's animated, otherwise its plain value.
    mutating func set(_ ref: TrackParameterRef, _ value: Double, at time: Time) {
        let value = ref.parameter.clamped(value)
        if let frames = keyframes[ref.key], !frames.isEmpty {
            keyframes[ref.key] = ClipAnimation.setting(frames, at: time, value: value)
            return
        }
        if let effectID = ref.effectID {
            guard let index = effects.firstIndex(where: { $0.id == effectID }) else { return }
            effects[index].values[ref.parameter.id] = value
        } else {
            set(ref.parameter, value, at: time)
        }
    }

    func value(_ ref: TrackParameterRef, at time: Time) -> Double {
        if let effectID = ref.effectID {
            guard let effect = effects.first(where: { $0.id == effectID }) else { return ref.parameter.defaultValue }
            return value(of: ref.parameter, in: effect, at: time)
        }
        if let frames = keyframes[ref.key], !frames.isEmpty { return ClipAnimation.interpolate(frames, atOffset: time) }
        return ref.parameter.id == AudioParameter.volume.id ? volumeDB : pan
    }

    /// Removes an effect and its keyframes.
    mutating func removeEffect(_ id: UUID) {
        effects.removeAll { $0.id == id }
        keyframes = keyframes.filter { !$0.key.hasPrefix(id.uuidString + "/") }
    }
}

extension EditorController {
    /// The audio track the Audio tab's settings show: the one picked in the mixer, else
    /// the track of a selected audio clip, else the first audio track.
    var audioSettingsTrack: Track? {
        if let id = selectedAudioTrackID, let track = state.tracks.first(where: { $0.id == id && $0.kind == .audio }) { return track }
        if let clip = selectedClips.first, let track = state.track(ofClip: clip.id), track.kind == .audio { return track }
        return audioTrackIndices.first.map { state.tracks[$0] }
    }

    private func editTrackAudio(_ id: UUID, _ actionName: String, _ body: @escaping (inout TrackAudio) -> Void) {
        store.edit(actionName) { state in
            guard let index = state.tracks.firstIndex(where: { $0.id == id }) else { return }
            body(&state.tracks[index].audio)
        }
    }

    func addEffect(_ kind: AudioEffectKind, to track: UUID) {
        editTrackAudio(track, "Add \(kind.title)") { $0.effects.append(AudioEffect(kind: kind)) }
    }

    func removeEffect(_ effect: UUID, from track: UUID) {
        editTrackAudio(track, "Remove Effect") { $0.removeEffect(effect) }
    }

    /// Moves an effect earlier (−1) or later (+1) in the chain.
    func moveEffect(_ effect: UUID, by offset: Int, in track: UUID) {
        editTrackAudio(track, "Move Effect") { audio in
            guard let from = audio.effects.firstIndex(where: { $0.id == effect }) else { return }
            let to = min(max(from + offset, 0), audio.effects.count - 1)
            guard to != from else { return }
            audio.effects.insert(audio.effects.remove(at: from), at: to)
        }
    }

    func setBypassed(_ bypassed: Bool, effect: UUID, in track: UUID) {
        editTrackAudio(track, bypassed ? "Bypass Effect" : "Enable Effect") { audio in
            guard let index = audio.effects.firstIndex(where: { $0.id == effect }) else { return }
            audio.effects[index].isBypassed = bypassed
        }
    }

    /// Replaces a track's chain with a preset's (ordinary, editable effects).
    func applyPreset(_ preset: AudioPreset, to track: UUID) {
        editTrackAudio(track, "Apply \(preset.name)") { audio in
            for effect in audio.effects { audio.removeEffect(effect.id) }
            audio.effects = preset.makeEffects()
            audio.presetName = preset.name
        }
    }

    func clearEffects(of track: UUID) {
        editTrackAudio(track, "Remove All Effects") { audio in
            for effect in audio.effects { audio.removeEffect(effect.id) }
            audio.presetName = nil
        }
    }

    // MARK: Parameters

    func trackParameterValue(_ ref: TrackParameterRef) -> Double {
        state.tracks.first { $0.id == ref.trackID }?.audio.value(ref, at: playback.currentTime) ?? ref.parameter.defaultValue
    }

    /// Changes a parameter during a drag (one undo step; call `endAudioAdjustment`).
    func adjustTrackParameter(_ ref: TrackParameterRef, to value: Double) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        let time = playback.currentTime.snappedToFrame(fps: fps)
        store.liveEdit { state in
            guard let index = state.tracks.firstIndex(where: { $0.id == ref.trackID }) else { return }
            state.tracks[index].audio.set(ref, value, at: time)
        }
    }

    /// Sets a parameter in one step (typed values, resets).
    func setTrackParameter(_ ref: TrackParameterRef, to value: Double) {
        let time = playback.currentTime.snappedToFrame(fps: fps)
        editTrackAudio(ref.trackID, "Change \(ref.parameter.title)") { $0.set(ref, value, at: time) }
    }

    func trackKeyframes(_ ref: TrackParameterRef) -> [Keyframe] {
        state.tracks.first { $0.id == ref.trackID }?.audio.keyframes[ref.key] ?? []
    }

    /// The keyframe of a parameter under the playhead (within half a frame), if any.
    func trackKeyframeAtPlayhead(_ ref: TrackParameterRef) -> Keyframe? {
        let half = Time(ticks: Time.frame(fps: fps).ticks / 2)
        let now = playback.currentTime
        return trackKeyframes(ref).first { abs(($0.time - now).ticks) <= half.ticks }
    }

    /// Adds a keyframe with the current value at the playhead, or removes the one there.
    func toggleTrackKeyframe(_ ref: TrackParameterRef) {
        let time = playback.currentTime.snappedToFrame(fps: fps)
        if let existing = trackKeyframeAtPlayhead(ref) {
            editTrackAudio(ref.trackID, "Remove Keyframe") { audio in
                var frames = audio.keyframes[ref.key] ?? []
                frames.removeAll { $0.id == existing.id }
                audio.keyframes[ref.key] = frames.isEmpty ? nil : frames
            }
        } else {
            let value = trackParameterValue(ref)
            editTrackAudio(ref.trackID, "Add Keyframe") { audio in
                audio.keyframes[ref.key] = ClipAnimation.setting(audio.keyframes[ref.key] ?? [], at: time, value: value)
            }
        }
    }

    /// Removes a parameter's keyframes, keeping the value at the playhead as its plain value.
    func clearTrackKeyframes(_ ref: TrackParameterRef) {
        let value = trackParameterValue(ref)
        let time = playback.currentTime
        editTrackAudio(ref.trackID, "Remove Keyframes") { audio in
            audio.keyframes[ref.key] = nil
            audio.set(ref, value, at: time)
        }
    }

    func jumpToTrackKeyframe(_ ref: TrackParameterRef, next: Bool) {
        let now = playback.currentTime
        let times = trackKeyframes(ref).map(\.time)
        let target = next ? times.first { $0 > now + Time(ticks: 1) } : times.last { $0 < now - Time(ticks: 1) }
        guard let target else { NSSound.beep(); return }
        playback.pause()
        playback.seek(to: target, audible: false)
    }
}

// MARK: - Loudness, Normalize and ducking

extension EditorController {
    /// Measures and adjusts `target` to the project's loudness target, as one undo step.
    /// Runs in the background; the Audio tab shows progress and the result.
    func normalize(_ target: NormalizeTarget) {
        guard audioActivity == nil else { return }
        let lufs = state.audio.loudnessTarget
        let snapshot = state
        audioActivity = "Normalizing \(target.title.lowercased())…"
        audioMessage = nil
        Task {
            defer { audioActivity = nil }
            do {
                let sources = await AudioSourceCache.shared.preparedSources(for: snapshot)
                let result = try await Task.detached(priority: .userInitiated) {
                    try Normalizer.normalize(snapshot, target, to: lufs, sources: sources)
                }.value
                store.edit("Normalize \(target.title)") { $0.applyNormalizeGain(result.gainChange, to: target) }
                audioMessage = String(format: "%@ normalized to %.1f LUFS (%@%.1f dB).", target.title, lufs,
                                      result.gainChange >= 0 ? "+" : "−", abs(result.gainChange))
                    .replacingOccurrences(of: "-", with: "−")
            } catch {
                audioMessage = "Couldn't normalize: \(error.localizedDescription)"
            }
        }
    }

    func setLoudnessTarget(_ lufs: Double) {
        store.edit("Change Loudness Target") { $0.audio.loudnessTarget = min(max(lufs, ProjectAudio.loudnessRange.lowerBound), ProjectAudio.loudnessRange.upperBound) }
    }

    func setMasterLimiter(_ enabled: Bool) {
        store.edit(enabled ? "Turn On Master Limiter" : "Turn Off Master Limiter") { $0.audio.master.limiterEnabled = enabled }
    }

    func adjustMasterCeiling(to db: Double) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        store.liveEdit { $0.audio.master.ceilingDB = min(max(db, MasterAudio.ceilingRange.lowerBound), MasterAudio.ceilingRange.upperBound) }
    }

    /// Sets up ducking: `game` goes down while `voice` is talking.
    func setDucking(voice: UUID, game: UUID) {
        guard voice != game else { NSSound.beep(); return }
        store.edit("Set Up Ducking") { state in
            var settings = state.audio.ducking ?? DuckingSettings(voiceTrackID: voice, gameTrackID: game)
            settings.voiceTrackID = voice
            settings.gameTrackID = game
            state.audio.ducking = settings
        }
    }

    func removeDucking() {
        store.edit("Remove Ducking") { $0.audio.ducking = nil }
    }

    func setDuckingEnabled(_ enabled: Bool) {
        store.edit(enabled ? "Turn On Ducking" : "Turn Off Ducking") { $0.audio.ducking?.isEnabled = enabled }
    }

    /// Changes a ducking setting during a drag (one undo step; call `endAudioAdjustment`).
    func adjustDucking(_ keyPath: WritableKeyPath<DuckingSettings, Double>, to value: Double, in range: ClosedRange<Double>) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        store.liveEdit { $0.audio.ducking?[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound) }
    }

    /// The master's live loudness.
    func readLoudness() -> LoudnessReading { playback.audio.graph.loudness.read() }

    func resetLoudness() { playback.audio.graph.loudness.resetRequested.store(true, ordering: .relaxed) }
}

// MARK: - Audio keyframe lanes

extension EditorController {
    /// The Edit tab's keyframe lane clip (speed and crop softness): exactly one selected clip.
    var editLaneClip: Clip? {
        let selected = selectedClips
        guard selected.count == 1, let clip = selected.first else { return nil }
        return clip
    }

    /// The Audio tab's clip: exactly one selected clip on an audio track.
    var audioClip: Clip? {
        let selected = selectedClips
        guard selected.count == 1, let clip = selected.first, state.track(ofClip: clip.id)?.kind == .audio else { return nil }
        return clip
    }

    /// A track parameter's title for the keyframe lane: "Volume", or "Equalizer · Low Cut".
    func trackParameterTitle(_ key: String, in track: Track) -> String {
        if key == AudioParameter.volume.id { return "Volume" }
        if key == AudioParameter.pan.id { return "Pan" }
        let parts = key.split(separator: "/")
        guard parts.count == 2, let effect = track.audio.effects.first(where: { $0.id.uuidString == parts[0] }),
              let parameter = effect.kind.parameter(String(parts[1])) else { return key }
        return "\(effect.kind.title) · \(parameter.title)"
    }

    /// Moves a track keyframe in time during a drag (one undo step; call `endAudioAdjustment`).
    func moveTrackKeyframe(_ id: UUID, key: String, track trackID: UUID, by delta: Time) {
        if !store.isLiveEditing { store.beginLiveEdit() }
        guard let base = store.liveBase, let index = base.tracks.firstIndex(where: { $0.id == trackID }),
              let frames = base.tracks[index].audio.keyframes[key], let original = frames.first(where: { $0.id == id }) else { return }
        let time = max(.zero, original.time + delta).snappedToFrame(fps: fps)
        store.liveEdit { state in
            var moved = frames.filter { $0.id != id && $0.time != time }
            var frame = original
            frame.time = time
            moved.append(frame)
            state.tracks[index].audio.keyframes[key] = moved.sorted { $0.time < $1.time }
        }
    }

    func deleteTrackKeyframe(_ id: UUID, key: String, track trackID: UUID) {
        store.edit("Delete Keyframe") { state in
            guard let index = state.tracks.firstIndex(where: { $0.id == trackID }) else { return }
            var frames = state.tracks[index].audio.keyframes[key] ?? []
            frames.removeAll { $0.id == id }
            state.tracks[index].audio.keyframes[key] = frames.isEmpty ? nil : frames
        }
    }

    func setTrackKeyframeEasing(_ easing: Easing, id: UUID, key: String, track trackID: UUID) {
        store.edit("Change Easing") { state in
            guard let index = state.tracks.firstIndex(where: { $0.id == trackID }),
                  let k = state.tracks[index].audio.keyframes[key]?.firstIndex(where: { $0.id == id }) else { return }
            state.tracks[index].audio.keyframes[key]?[k].easing = easing
        }
    }
}
