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

/// Plays the audio tracks through the project's `AudioGraph` in real time, started at
/// a host time shared with the video player; scrubbing goes through the same graph.
final class AudioRenderer {
    let engine: AVAudioEngine
    let graph: AudioGraph

    private let scrubLoader = ScrubSourceLoader()
    private var teardown: DispatchWorkItem?
    private(set) var isPlaying = false

    var isMuted: Bool {
        get { graph.isMuted }
        set { graph.isMuted = newValue }
    }

    init(engine: AVAudioEngine = AVAudioEngine()) {
        self.engine = engine
        graph = AudioGraph(engine: engine)
    }

    /// Schedules every audio clip from `time` and starts them at `hostTime`
    /// (immediately when nil, e.g. for offline rendering).
    func start(_ state: ProjectState, at time: Time, hostTime: UInt64?) {
        cancelTeardown()
        // Offline, the graph is built before the engine starts (as for export): players
        // added to a running offline engine would join a render cycle late.
        if engine.isInManualRenderingMode { engine.stop() }
        if !engine.isInManualRenderingMode { guard startEngine() else { return } }
        graph.prepareVoices(state, from: time) { AudioSourceCache.shared.prepared(for: $0) }
        if engine.isInManualRenderingMode { guard startEngine() else { return } }
        graph.start(at: time, hostTime: hostTime)
        isPlaying = true
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
        guard !isPlaying else { return }
        cancelTeardown()
        guard startEngine() else { return }
        let sources = scrubLoader.sources(around: time, in: state)
        let mono = Set(state.media.filter { AudioSourceCache.shared.prepared(for: $0)?.isMono == true }.map(\.id))
        graph.scrub(state, to: time, sources: sources, monoSources: mono)
    }

    func stopScrubbing() {
        graph.stopScrubbing()
    }

    /// Stops playback. In real time the master fades out over a few milliseconds first,
    /// so stopping never clicks.
    func stop() {
        guard isPlaying else { return }
        isPlaying = false
        if engine.isInManualRenderingMode || !engine.isRunning {
            graph.removeVoices()
            return
        }
        graph.fadeOut()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isPlaying else { return }
            self.graph.removeVoices()
            self.teardown = nil
        }
        teardown = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    private func cancelTeardown() {
        guard let teardown else { return }
        teardown.cancel()
        self.teardown = nil
        graph.removeVoices()
    }

    /// Applies volume, pan, fades, mute/solo and fader changes to the playing graph.
    func update(_ state: ProjectState) {
        graph.update(state)
    }
}
