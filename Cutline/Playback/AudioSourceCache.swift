import AVFoundation

/// Provides a file `AVAudioFile` can read for each media item. Plain audio files
/// (WAV, AIFF, CAF, M4A, MP3, FLAC…) are used directly; the sound of movie files
/// is decoded once into a cached CAF proxy, prepared in the background.
final class AudioSourceCache {
    static let shared = AudioSourceCache()

    private var ready: [UUID: URL] = [:]
    private var preparing: [UUID: Task<URL?, Never>] = [:]

    /// The readable URL if it's ready; otherwise starts preparing it and returns nil.
    func readableURL(for media: MediaItem) -> URL? {
        if let url = ready[media.id] { return url }
        _ = task(for: media)
        return nil
    }

    /// Drops prepared files for media whose source went missing, moved or came back.
    func forget(_ ids: Set<UUID>) {
        for id in ids {
            ready[id] = nil
            preparing[id]?.cancel()
            preparing[id] = nil
        }
    }

    /// Waits until the media's audio is readable.
    func prepare(_ media: MediaItem) async -> URL? {
        if let url = ready[media.id] { return url }
        return await task(for: media).value
    }

    func prefetch(_ state: ProjectState) {
        let audioMedia = Set(state.trackIndices(of: .audio).flatMap { state.tracks[$0].clips.map(\.mediaID) })
        for media in state.media where audioMedia.contains(media.id) && media.hasAudio {
            _ = readableURL(for: media)
        }
    }

    private func task(for media: MediaItem) -> Task<URL?, Never> {
        if let existing = preparing[media.id] { return existing }
        let source = MediaURLCache.shared.url(for: media)
        let id = media.id
        let task = Task {
            let url = await Self.makeReadable(source, id: id)
            if let url { ready[id] = url }
            preparing[id] = nil
            return url
        }
        preparing[media.id] = task
        return task
    }

    /// Forgets every prepared file (after the cache folder was cleared).
    func forgetAll() {
        forget(Set(ready.keys).union(preparing.keys))
    }

    @concurrent
    nonisolated private static func makeReadable(_ url: URL, id: UUID) async -> URL? {
        if (try? AVAudioFile(forReading: url)) != nil { return url }

        // Name the proxy after the source file's identity so edits to the file invalidate it.
        let stamp = DiskCache.stamp(for: url) ?? "0-0"
        let folder = DiskCache.audio.folder
        let proxy = folder.appendingPathComponent("\(id.uuidString)-\(stamp).caf")
        if FileManager.default.fileExists(atPath: proxy.path) {
            DiskCache.touch(proxy)
            return proxy
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent("\(UUID().uuidString).tmp.caf")
        // Reading waits for each sample, so it runs on a thread of its own.
        let decoded = await withTaskExecutorPreference(MediaWorkThread(label: "app.cutline.audio-proxy")) {
            await decode(url, to: temp)
        }
        guard decoded else {
            try? FileManager.default.removeItem(at: temp)
            return nil
        }
        try? FileManager.default.moveItem(at: temp, to: proxy)
        return proxy
    }

    /// Decodes the first audio track to 32-bit float stereo PCM.
    @concurrent
    nonisolated private static func decode(_ url: URL, to destination: URL) async -> Bool {
        let sampleRate = 48_000.0
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: true),
              let file = try? AVAudioFile(forWriting: destination, settings: format.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: true)
        else { return false }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: sampleRate,
        ])
        guard reader.canAdd(output) else { return false }
        let provider = reader.outputProvider(for: output)
        do { try reader.start() } catch { return false }

        while let ready = try? await provider.next() {
            let written: Bool = ready.withUnsafeSampleBuffer { sample in
                guard let block = CMSampleBufferGetDataBuffer(sample) else { return true }
                let length = CMBlockBufferGetDataLength(block)
                let frames = AVAudioFrameCount(length / (MemoryLayout<Float>.size * 2))
                guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
                      let destination = pcm.floatChannelData?[0] else { return true }
                pcm.frameLength = frames
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
                return (try? file.write(from: pcm)) != nil
            }
            guard written else { return false }
        }
        return true
    }
}
