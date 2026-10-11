import Foundation

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
