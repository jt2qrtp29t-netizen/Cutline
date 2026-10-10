import AVFoundation

/// What to play for one audio clip when playback starts at a timeline time.
nonisolated struct AudioVoicePlan: Equatable, Sendable {
    /// First frame to read from the file.
    let startFrame: AVAudioFramePosition
    let frameCount: AVAudioFrameCount
    /// Delay before the clip starts, in the player node's own sample time.
    let delayFrames: AVAudioFramePosition

    /// Nil if the clip has already finished at `time` or is empty.
    static func make(for clip: Clip, from time: Time, sampleRate: Double, fileLength: AVAudioFramePosition) -> AudioVoicePlan? {
        guard clip.end > time else { return nil }
        let begin = max(time, clip.start)
        let startFrame = AVAudioFramePosition((clip.sourceTime(at: begin).seconds * sampleRate).rounded())
        guard startFrame < fileLength else { return nil }
        // The time-pitch unit pulls `speed` source frames per output frame.
        let wanted = AVAudioFramePosition(((clip.end - begin).seconds * clip.speed * sampleRate).rounded())
        let frames = min(wanted, fileLength - startFrame)
        guard frames > 0 else { return nil }
        let delay = AVAudioFramePosition(((begin - time).seconds * clip.speed * sampleRate).rounded())
        return AudioVoicePlan(startFrame: startFrame, frameCount: AVAudioFrameCount(frames), delayFrames: delay)
    }
}

/// Plays the audio tracks through an `AVAudioEngine`, one voice per clip:
/// player → time-pitch (speed + pitch) → EQ (gain) → mixer (pan) → main mixer.
/// Voices are started together at a host time shared with the video player.
final class AudioRenderer {
    let engine: AVAudioEngine

    private struct Voice {
        let clipID: UUID
        let trackIndex: Int
        let player: AVAudioPlayerNode
        let timePitch: AVAudioUnitTimePitch
        let gain: AVAudioUnitEQ
        let mixer: AVAudioMixerNode
        var nodes: [AVAudioNode] { [player, timePitch, gain, mixer] }
    }

    private var voices: [Voice] = []

    /// Tape-style scrub audio, created when first needed.
    private var scrubber: AudioScrubber?

    var isMuted = false {
        didSet { engine.mainMixerNode.outputVolume = isMuted ? 0 : 1 }
    }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
    }

    var isPlaying: Bool { !voices.isEmpty }

    /// Schedules every audio clip from `time` and starts them at `hostTime`
    /// (immediately when nil, e.g. for offline rendering).
    func start(_ state: ProjectState, at time: Time, hostTime: UInt64?) {
        stop()
        stopScrubbing()
        guard startEngine() else { return }

        for trackIndex in state.trackIndices(of: .audio) {
            for clip in state.tracks[trackIndex].clips where clip.end > time {
                guard let media = state.mediaItem(clip.mediaID),
                      let url = AudioSourceCache.shared.readableURL(for: media),
                      // Each voice reads through its own file object.
                      let file = try? AVAudioFile(forReading: url) else { continue }
                let format = file.processingFormat
                guard let plan = AudioVoicePlan.make(for: clip, from: time, sampleRate: format.sampleRate,
                                                     fileLength: file.length) else { continue }

                let voice = Voice(clipID: clip.id, trackIndex: trackIndex, player: AVAudioPlayerNode(),
                                  timePitch: AVAudioUnitTimePitch(), gain: AVAudioUnitEQ(numberOfBands: 0),
                                  mixer: AVAudioMixerNode())
                voice.nodes.forEach(engine.attach)
                do {
                    try engine.connectNode(voice.player, to: voice.timePitch, format: format)
                    try engine.connectNode(voice.timePitch, to: voice.gain, format: format)
                    try engine.connectNode(voice.gain, to: voice.mixer, format: format)
                    try engine.connectNode(voice.mixer, to: engine.mainMixerNode, format: format)
                } catch {
                    voice.nodes.forEach(engine.detach)
                    continue
                }
                apply(clip, active: state.isClipActive(clip, onTrack: trackIndex), to: voice)
                let when = plan.delayFrames > 0 ? AVAudioTime(sampleTime: plan.delayFrames, atRate: format.sampleRate) : nil
                voice.player.scheduleSegment(file, startingFrame: plan.startFrame, frameCount: plan.frameCount,
                                             at: when, completionHandler: nil)
                voices.append(voice)
            }
        }

        let start = hostTime.map { AVAudioTime(hostTime: $0) }
        for voice in voices {
            try? voice.player.playAudio(at: start)
        }
    }

    @discardableResult
    private func startEngine() -> Bool {
        _ = engine.mainMixerNode  // Builds the output chain before starting.
        if engine.isRunning { return true }
        do { try engine.start() } catch { return false }
        return true
    }

    /// Moves the scrub head to `time`; it plays the audio it glides over (while paused).
    func scrub(_ state: ProjectState, at time: Time) {
        guard voices.isEmpty, startEngine() else { return }
        if scrubber == nil {
            let rate = engine.isInManualRenderingMode
                ? engine.manualRenderingFormat.sampleRate
                : engine.outputNode.outputFormat(forBus: 0).sampleRate
            let scrubber = AudioScrubber(sampleRate: rate > 0 ? rate : 48_000)
            engine.attach(scrubber.node)
            do {
                try engine.connectNode(scrubber.node, to: engine.mainMixerNode, format: scrubber.node.outputFormat(forBus: 0))
            } catch {
                engine.detach(scrubber.node)
                return
            }
            self.scrubber = scrubber
        }
        scrubber?.move(to: time, in: state)
    }

    func stopScrubbing() {
        scrubber?.stop()
    }

    func stop() {
        for voice in voices {
            voice.player.stop()
            voice.nodes.forEach(engine.detach)
        }
        voices = []
    }

    /// Applies volume, pan, pitch and mute/solo changes to playing voices.
    func update(_ state: ProjectState) {
        for voice in voices {
            guard let clip = state.clip(voice.clipID), state.tracks.indices.contains(voice.trackIndex) else { continue }
            apply(clip, active: state.isClipActive(clip, onTrack: voice.trackIndex), to: voice)
        }
    }

    private func apply(_ clip: Clip, active: Bool, to voice: Voice) {
        voice.timePitch.rate = Float(clip.speed)
        voice.timePitch.pitch = Float(clip.pitchShiftCents)
        // Mixer volume covers 0…100 %; the EQ's gain adds the boost above that.
        voice.mixer.volume = active ? Float(min(clip.volume, 1)) : 0
        voice.gain.globalGain = clip.volume > 1 ? Float(20 * log10(clip.volume)) : 0
        voice.mixer.pan = Float(clip.pan.clamped(to: -1...1))
    }
}
