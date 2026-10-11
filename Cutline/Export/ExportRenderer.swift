import AVFoundation
import CoreImage
import VideoToolbox

/// A frozen copy of everything an export needs, taken when Export is pressed. Later
/// edits (or deleting clips and tracks) can't change a running export.
nonisolated struct ExportSnapshot: Sendable {
    /// The timeline as it will be drawn (Playground variant choices already applied).
    var state: ProjectState
    /// Resolved media files.
    var urls: [UUID: URL]
    /// The part of the timeline to export, on frame boundaries.
    var range: TimeRange
    var settings: ExportSettings

    var frameRate: Int { settings.frameRate(for: state.settings) }
    var frameCount: Int { Self.frameCount(range.duration, fps: frameRate) }

    static func frameCount(_ duration: Time, fps: Int) -> Int {
        Int((duration.seconds * Double(fps)).rounded())
    }

    /// Lines the range up with output frames: start on a frame, whole frames long.
    static func snapped(_ range: TimeRange, fps: Int) -> TimeRange {
        let frame = Time.frame(fps: fps)
        let start = range.start.snappedToFrame(fps: fps)
        let frames = max(1, frameCount(range.end - start, fps: fps))
        return TimeRange(start: start, end: start + Time(ticks: frame.ticks * Int64(frames)))
    }

    /// Labs items in the snapshot, to report any that failed while rendering.
    var labEffects: [(clip: String, effect: LabEffect)] {
        state.allClips.flatMap { clip in
            (clip.generator.map { [$0] } ?? []).map { (clip.name, $0) } + clip.labs.filter(\.isEnabled).map { (clip.name, $0) }
        }
    }
}

/// Stops a running export from any thread.
nonisolated final class ExportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

nonisolated enum ExportError: LocalizedError, Equatable {
    case emptyTimeline
    case cancelled
    case setupFailed(String)
    case writingFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyTimeline: "There’s nothing to export: the timeline (or the chosen range) is empty."
        case .cancelled: "The export was canceled."
        case .setupFailed(let reason): "The export couldn’t start: \(reason)"
        case .writingFailed(let reason): "The export failed: \(reason)"
        }
    }
}

/// Writes a snapshot to a movie file using the same composition and compositor as the
/// preview, so the file looks exactly like what's on screen.
nonisolated enum ExportRenderer {
    /// Renders video and the (already mixed) audio file into `output`. Reports progress
    /// as frames written. The file is only complete when this returns.
    static func render(_ snapshot: ExportSnapshot, audio: URL?, to output: URL,
                       cancellation: ExportCancellation,
                       progress: @escaping @Sendable (Int) -> Void) async throws {
        guard snapshot.range.duration > .zero, snapshot.frameCount > 0 else { throw ExportError.emptyTimeline }

        // The timeline at the export frame rate; the compositor renders each output frame.
        var state = snapshot.state
        state.settings.frameRate = snapshot.frameRate
        let built = try await CompositionBuilder.build(state, urls: snapshot.urls)
        guard let videoComposition = built.videoComposition else { throw ExportError.emptyTimeline }
        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        guard !videoTracks.isEmpty else { throw ExportError.emptyTimeline }

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: built.composition) } catch {
            throw ExportError.setupFailed(error.localizedDescription)
        }
        reader.timeRange = snapshot.range.cmTimeRange
        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = videoComposition
        guard reader.canAdd(videoOutput) else { throw ExportError.setupFailed("the video can’t be read.") }

        // The mixed audio, read back as PCM for the AAC encoder.
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if let audio {
            let asset = AVURLAsset(url: audio)
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                let r = try AVAssetReader(asset: asset)
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                if r.canAdd(o) {
                    audioReader = r
                    audioOutput = o
                }
            }
        }

        let settings = snapshot.settings
        let fileType: AVFileType = settings.effectiveContainer == .mov ? .mov : .mp4
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: output, fileType: fileType) } catch {
            throw ExportError.setupFailed(error.localizedDescription)
        }
        // Network optimization: the movie's index goes at the start of the file.
        writer.shouldOptimizeForNetworkUse = settings.networkOptimized
        let (width, height) = settings.resolution.size(for: state.settings)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(settings, width: width, height: height,
                                                                                            project: state.settings))
        guard writer.canAdd(videoInput) else { throw ExportError.setupFailed("the video encoder isn’t available with these settings.") }

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: settings.audioSampleRate,
                AVNumberOfChannelsKey: settings.audioChannels,
                AVEncoderBitRateKey: settings.audioBitrate * 1000,
            ])
            if writer.canAdd(input) {
                audioInput = input
            }
        }

        // Each stream is read and written by its own task.
        let video = VideoStream(provider: reader.outputProvider(for: videoOutput),
                                receiver: writer.inputPixelBufferReceiver(for: videoInput, pixelBufferAttributes: nil))
        var audioStream: AudioStream?
        if let audioReader, let audioOutput, let audioInput {
            audioStream = AudioStream(provider: audioReader.outputProvider(for: audioOutput),
                                      receiver: writer.inputReceiver(for: audioInput))
        }

        do {
            try reader.start()
            try audioReader?.start()
            try writer.start()
        } catch {
            reader.cancelReading()
            audioReader?.cancelReading()
            writer.cancelWriting()
            throw ExportError.setupFailed(error.localizedDescription)
        }
        // Times in the file start at zero; the audio mix already starts at the range start.
        writer.startSession(atSourceTime: .zero)

        let rangeStart = snapshot.range.start.cmTime
        let audioEnd = snapshot.range.duration.cmTime
        let total = snapshot.frameCount
        // One loop offers the writer the next video frame and audio sample without ever
        // blocking: it takes whichever it's ready for (it interleaves the two itself), and
        // when it takes neither the loop waits a moment. Nothing can deadlock, and cancel
        // is noticed within milliseconds.
        let pipeline = Pipeline(readers: [reader] + (audioReader.map { [$0] } ?? []), writer: writer)
        let streams = Streams(video: video, audio: audioStream)
        do {
            // On the export's own thread: the providers wait for samples synchronously.
            try await Task.detached(executorPreference: MediaWorkThread(label: "app.cutline.export")) {
                var written = 0
                func nextVideo() async throws -> (pixels: CVReadOnlyPixelBuffer, time: CMTime)? {
                    while written < total, let sample = try await streams.video.provider.next() {
                        if case .pixelBuffer(let pixels) = sample.content {
                            return (pixels, CMTimeSubtract(sample.presentationTimeStamp, rangeStart))
                        }
                    }
                    return nil
                }
                func nextAudio() async throws -> CMReadySampleBuffer<CMSampleBuffer.DynamicContent>? {
                    guard let audio = streams.audio, let sample = try await audio.provider.next(),
                          CMTimeCompare(sample.presentationTimeStamp, audioEnd) < 0 else { return nil }
                    return sample
                }
                var pendingVideo = try await nextVideo()
                var pendingAudio = try await nextAudio()
                if pendingAudio == nil { streams.audio?.receiver.finish() }
                while pendingVideo != nil || pendingAudio != nil {
                    if cancellation.isCancelled || Task.isCancelled { throw ExportError.cancelled }
                    var progressed = false
                    if let frame = pendingVideo, try streams.video.receiver.appendImmediately(frame.pixels, with: frame.time) {
                        written += 1
                        progress(written)
                        pendingVideo = try await nextVideo()
                        if pendingVideo == nil { streams.video.receiver.finish() }
                        progressed = true
                    }
                    if let sample = pendingAudio, let audio = streams.audio, try audio.receiver.appendImmediately(sample) {
                        pendingAudio = try await nextAudio()
                        if pendingAudio == nil { audio.receiver.finish() }
                        progressed = true
                    }
                    if !progressed {
                        if let failure = pipeline.writerError { throw ExportError.writingFailed(failure) }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                }
            }.value
        } catch {
            pipeline.abort()
            reader.cancelReading()
            audioReader?.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            if cancellation.isCancelled || error as? ExportError == .cancelled || error is CancellationError {
                throw ExportError.cancelled
            }
            throw ExportError.writingFailed(error.localizedDescription)
        }

        // Exactly as long as the range, however long the last frame's sample says.
        writer.endSession(atSourceTime: snapshot.range.duration.cmTime)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            throw ExportError.writingFailed(writer.error?.localizedDescription ?? "the file couldn’t be finished.")
        }
    }

    static func videoSettings(_ settings: ExportSettings, width: Int, height: Int, project: ProjectSettings) -> [String: Any] {
        let codec: AVVideoCodecType = switch settings.codec {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        }
        var result: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: settings.fit == .fill ? AVVideoScalingModeResizeAspectFill : AVVideoScalingModeResizeAspect,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: settings.hardwareEncoding,
            ],
        ]
        if settings.codec.usesBitrate {
            let fps = settings.frameRate(for: project)
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(settings.videoBitrate(for: project)),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
            if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            if settings.usesFastEncoding {
                compression[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
            }
            result[AVVideoCompressionPropertiesKey] = compression
        }
        return result
    }

    /// Stops reading and writing at once (when an export fails or is canceled).
    private final class Pipeline: @unchecked Sendable {
        private let lock = NSLock()
        private let readers: [AVAssetReader]
        private let writer: AVAssetWriter
        private var aborted = false

        init(readers: [AVAssetReader], writer: AVAssetWriter) {
            self.readers = readers
            self.writer = writer
        }

        /// Why the writer stopped, if it failed.
        var writerError: String? {
            writer.status == .failed ? (writer.error?.localizedDescription ?? "the encoder stopped.") : nil
        }

        func abort() {
            lock.lock()
            let first = !aborted
            aborted = true
            lock.unlock()
            guard first else { return }
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
        }
    }

    /// Both streams, handed to the task that writes them.
    private struct Streams: @unchecked Sendable {
        let video: VideoStream
        let audio: AudioStream?
    }

    /// A stream's reader and writer ends, handed to the one task that uses them.
    private struct VideoStream: @unchecked Sendable {
        let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        let receiver: AVAssetWriterInput.PixelBufferReceiver
    }

    private struct AudioStream: @unchecked Sendable {
        let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        let receiver: AVAssetWriterInput.SampleBufferReceiver
    }
}

/// Mixes the audio tracks exactly as playback does (the same voices, speed, pitch,
/// pan, volume and mute/solo), rendered offline into a file on a background thread.
enum ExportAudioMixer {
    static func render(_ snapshot: ExportSnapshot, to url: URL, cancellation: ExportCancellation,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let state = snapshot.state
        // Audio from movie files is decoded once into a readable proxy; wait for those.
        var readable: [UUID: URL] = [:]
        let audioMedia = Set(state.trackIndices(of: .audio).flatMap { state.tracks[$0].clips.map(\.mediaID) })
        for media in state.media where audioMedia.contains(media.id) && media.hasAudio && MediaURLCache.shared.isAvailable(media) {
            if let url = await AudioSourceCache.shared.prepare(media) { readable[media.id] = url }
        }
        let files = readable
        try await Task.detached(priority: .userInitiated) {
            try mix(snapshot, files: files, to: url, cancellation: cancellation, progress: progress)
        }.value
    }

    nonisolated private static func mix(_ snapshot: ExportSnapshot, files: [UUID: URL], to url: URL,
                                        cancellation: ExportCancellation, progress: (Double) -> Void) throws {
        let rate = Double(snapshot.settings.audioSampleRate)
        let channels = AVAudioChannelCount(max(1, min(2, snapshot.settings.audioChannels)))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else {
            throw ExportError.setupFailed("the audio format isn’t supported.")
        }
        let engine = AVAudioEngine()
        let chunk: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        _ = engine.mainMixerNode
        let voices = AudioVoice.makeAll(for: snapshot.state, from: snapshot.range.start, in: engine) { files[$0.id] }
        try engine.start()
        defer {
            voices.forEach { $0.player.stop() }
            engine.stop()
        }
        for voice in voices { try voice.player.playAudio(at: nil) }

        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw ExportError.setupFailed("the audio couldn’t be prepared.")
        }
        let total = AVAudioFramePosition((snapshot.range.duration.seconds * rate).rounded())
        var done: AVAudioFramePosition = 0
        while done < total {
            if cancellation.isCancelled { throw ExportError.cancelled }
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - done))
            // When the Mac is busy the players may not have read their files ahead yet;
            // that's "try again", not an error.
            var status = try engine.renderOffline(frames, to: buffer)
            var retries = 0
            while status == .cannotDoInCurrentContext && retries < 2_000 {
                if cancellation.isCancelled { throw ExportError.cancelled }
                Thread.sleep(forTimeInterval: 0.002)
                status = try engine.renderOffline(frames, to: buffer)
                retries += 1
            }
            guard status == .success else { throw ExportError.writingFailed("the audio mix stopped early.") }
            try file.write(from: buffer)
            done += AVAudioFramePosition(buffer.frameLength)
            progress(Double(done) / Double(total))
        }
    }
}
