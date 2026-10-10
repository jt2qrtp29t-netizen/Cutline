import AVFoundation
import CoreImage
import Observation
import QuartzCore

/// Owns playback for one editor window: an `AVPlayer` for the picture and an
/// `AudioRenderer` for the audio tracks, started together at a shared host time.
@Observable
final class PlaybackController {
    let player = AVPlayer()
    @ObservationIgnored let audio = AudioRenderer()

    /// The playhead. Updated continuously during playback and immediately while scrubbing.
    private(set) var currentTime: Time = .zero
    private(set) var isPlaying = false
    private(set) var duration: Time = .zero

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var installed: CompositionBuilder.Output?
    @ObservationIgnored private var installedTiming: TimingSignature?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored private var pendingSeek: Time?
    @ObservationIgnored private var frameDuration = Time.frame(fps: 30)
    @ObservationIgnored private var latestState: ProjectState?
    @ObservationIgnored private var mediaObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// Lead time so the video and audio can both be ready to start on the same host tick.
    private static let startLatency = 0.08

    init() {
        player.actionAtItemEnd = .pause
        // Required for starting at an exact host time with setRate(_:time:atHostTime:).
        player.automaticallyWaitsToMinimizeStalling = false
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time) }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in
                self?.isPlaying = playing
                if !playing { self?.audio.stop() }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let item = notification.object as? AVPlayerItem
            MainActor.assumeIsolated {
                guard let self, item === self.player.currentItem else { return }
                self.currentTime = self.duration
            }
        }
        // Rebuild when files go missing or come back, so offline clips show their slate
        // (and recovered ones their media) without any edit.
        mediaObserver = NotificationCenter.default.addObserver(
            forName: .mediaAvailabilityChanged, object: nil, queue: .main
        ) { [weak self] notification in
            let ids = notification.object as? Set<UUID> ?? []
            MainActor.assumeIsolated { self?.reloadMedia(ids) }
        }
    }

    /// Forgets prepared media for `ids` and rebuilds the composition.
    func reloadMedia(_ ids: Set<UUID>) {
        AudioSourceCache.shared.forget(ids)
        installedTiming = nil
        if let latestState { update(with: latestState, isLiveEdit: false) }
    }

    isolated deinit {
        audio.stop()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let mediaObserver { NotificationCenter.default.removeObserver(mediaObserver) }
        rebuildTask?.cancel()
    }

    // MARK: Transport

    func setMuted(_ muted: Bool) {
        audio.isMuted = muted
    }

    func togglePlayback() {
        // Check the player too, so a late rate notification can never make Space restart playback.
        (isPlaying || player.rate != 0) ? pause() : play()
    }

    func play() {
        guard duration > .zero, player.currentItem != nil else { return }
        var from = currentTime.clamped(.zero, duration)
        if from >= duration - frameDuration {
            from = .zero
            currentTime = .zero
        }
        startSynchronized(from: from)
    }

    /// Starts picture and sound at the same future host time. AVPlayer refuses a
    /// synchronized start (it throws) until the player and item are ready, e.g. just
    /// after a project opens or an edit rebuilt the composition, so wait for that.
    private func startSynchronized(from time: Time) {
        pendingSeek = nil
        isPlaying = true
        startTask?.cancel()
        guard isReadyForSynchronizedStart else {
            startTask = Task {
                for _ in 0..<300 where !isReadyForSynchronizedStart {
                    try? await Task.sleep(for: .milliseconds(10))
                    if Task.isCancelled || !isPlaying { return }
                }
                guard isPlaying, isReadyForSynchronizedStart else { isPlaying = false; return }
                startSynchronized(from: time)
            }
            return
        }
        let hostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.startLatency)
        player.setRate(1, time: time.cmTime, atHostTime: CMClockMakeHostTimeFromSystemUnits(hostTime))
        if let latestState {
            audio.start(latestState, at: time, hostTime: hostTime)
        }
    }

    private var isReadyForSynchronizedStart: Bool {
        player.status == .readyToPlay && player.currentItem?.status == .readyToPlay
    }

    func pause() {
        startTask?.cancel()
        player.pause()
        isPlaying = false
        audio.stop()
        currentTime = Time(player.currentTime()).clamped(.zero, duration)
    }

    /// Moves the playhead. Seeks are coalesced: while one is in flight only the
    /// latest requested time is kept, so scrubbing stays responsive. With `audible`,
    /// a short grain of the audio at the new position is played (scrub audio).
    func seek(to time: Time, audible: Bool = false) {
        let target = time.clamped(.zero, max(duration, .zero))
        let previous = currentTime
        currentTime = max(time, .zero)
        pendingSeek = target
        drainSeeks()
        if audible, !isPlaying, currentTime != previous, let latestState {
            audio.scrub(latestState, at: currentTime)
        }
    }

    func step(frames: Int) {
        pause()
        seek(to: (currentTime + Time(ticks: frameDuration.ticks * Int64(frames))).snappedToFrame(fps: fpsValue),
             audible: true)
    }

    private var fpsValue: Int { Int(Time.ticksPerSecond / max(frameDuration.ticks, 1)) }

    private func drainSeeks() {
        guard !seekInFlight, let target = pendingSeek else { return }
        pendingSeek = nil
        seekInFlight = true
        Task {
            await player.seek(to: target.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
            seekInFlight = false
            drainSeeks()
        }
    }

    private func playerTimeChanged(_ time: CMTime) {
        // While paused the playhead belongs to the user (it may sit past the end of the media).
        guard isPlaying || player.rate != 0 else { return }
        currentTime = Time(time)
    }

    // MARK: Composition updates

    /// Called whenever the project changes. Appearance-only changes (transform, crop,
    /// opacity, color, volume, pan, pitch, mute/solo) update the compositor
    /// instructions and playing voices in place; structural changes rebuild the
    /// composition (deferred while a gesture is in progress).
    func update(with state: ProjectState, isLiveEdit: Bool) {
        frameDuration = state.settings.frameDuration
        latestState = state
        AudioSourceCache.shared.prefetch(state)
        let timing = TimingSignature(state)

        if timing == installedTiming, let installed, let item = player.currentItem {
            if installed.videoComposition != nil {
                item.videoComposition = CompositionBuilder.makeVideoComposition(
                    for: prepared(state), duration: installed.duration,
                    clipTrackIDs: installed.clipTrackIDs, sourceTransforms: installed.sourceTransforms
                )
            }
            audio.update(state)
            if !isPlaying { refreshFrame() }
            return
        }
        guard !isLiveEdit else { return }
        scheduleRebuild(prepared(state), timing: timing)
    }

    /// Changes what's drawn without changing the project (the Playground's variant
    /// compare and Labs switches use it).
    @ObservationIgnored var renderFilter: ((ProjectState) -> ProjectState)? {
        didSet { if let latestState { update(with: latestState, isLiveEdit: false) } }
    }

    /// The state as it's rendered: grades removed for "before", then the render filter.
    func prepared(_ state: ProjectState) -> ProjectState {
        var state = gradeBypassed ? state.withoutGrades() : state
        if let renderFilter { state = renderFilter(state) }
        return state
    }

    /// Shows every clip ungraded (the "before" view) without touching the project.
    private(set) var gradeBypassed = false

    func setGradeBypassed(_ bypassed: Bool) {
        guard bypassed != gradeBypassed else { return }
        gradeBypassed = bypassed
        if let latestState { update(with: latestState, isLiveEdit: false) }
    }

    private func scheduleRebuild(_ state: ProjectState, timing: TimingSignature) {
        rebuildTask?.cancel()
        let urls = Dictionary(uniqueKeysWithValues: state.media.map { ($0.id, MediaURLCache.shared.url(for: $0)) })
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            do {
                let output = try await CompositionBuilder.build(state, urls: urls)
                guard !Task.isCancelled else { return }
                install(output, timing: timing)
            } catch {
                guard !Task.isCancelled else { return }
                install(nil, timing: timing)
            }
        }
    }

    private func install(_ output: CompositionBuilder.Output?, timing: TimingSignature) {
        let wasPlaying = isPlaying
        installed = output
        installedTiming = timing

        guard let output, output.duration > .zero else {
            player.replaceCurrentItem(with: nil)
            duration = .zero
            return
        }

        let resumeAt = Time(player.currentTime())
        let item = AVPlayerItem(asset: output.composition)
        item.videoComposition = output.videoComposition
        attachFrameOutput(to: item)
        player.replaceCurrentItem(with: item)
        duration = output.duration

        if wasPlaying {
            // Keep playing from where we were, with sound rescheduled for the new timeline.
            startSynchronized(from: resumeAt.clamped(.zero, duration))
        } else {
            pendingSeek = currentTime.clamped(.zero, duration)
            seekInFlight = false
            drainSeeks()
        }
    }

    // MARK: Frames for scopes

    /// While true, the displayed frames can be read with `latestFrame()` (the scopes
    /// turn this on while they're visible; it costs a copy per frame).
    var providesFrames = false {
        didSet {
            guard providesFrames != oldValue else { return }
            if let item = player.currentItem {
                if providesFrames { attachFrameOutput(to: item) } else { detachFrameOutput(from: item) }
            }
        }
    }
    @ObservationIgnored private var frameOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored private var lastFrame: CIImage?
    /// Keeps the pixel buffer behind `lastFrame` alive (CIImage reads it lazily).
    @ObservationIgnored private var lastFrameBuffer: CVReadOnlyPixelBuffer?
    /// Bumped whenever `latestFrame()` returns a new frame.
    @ObservationIgnored private(set) var frameNumber = 0

    private func attachFrameOutput(to item: AVPlayerItem) {
        frameOutput = nil
        guard providesFrames else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: CVPixelBufferAttributes(
            pixelFormatTypes: [CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA)]))
        item.add(output)
        frameOutput = output
        // A paused frame was drawn before the output existed: draw it again.
        if !isPlaying { refreshFrame() }
    }

    private func detachFrameOutput(from item: AVPlayerItem) {
        if let frameOutput { item.remove(frameOutput) }
        frameOutput = nil
        lastFrame = nil
        lastFrameBuffer = nil
    }

    /// The frame being shown, as rendered (with the grade), or nil before one is available.
    func latestFrame() -> CIImage? {
        guard let output = frameOutput else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        let itemTime = isPlaying ? time : player.currentTime()
        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let buffer = output.pixelBufferAndDisplayTime(forItemTime: itemTime).pixelBuffer {
            lastFrameBuffer = buffer
            lastFrame = buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
            frameNumber += 1
        }
        return lastFrame
    }

    /// Re-renders the current frame after appearance changes while paused.
    private func refreshFrame() {
        pendingSeek = currentTime.clamped(.zero, duration)
        drainSeeks()
    }
}

