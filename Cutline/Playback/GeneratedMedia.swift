import AVFoundation
import Observation

/// Copies of media files made for smoother editing. Playback can use them; exports
/// always read the original files, so they never cost quality.
nonisolated enum GeneratedMediaKind: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Full size ProRes 422: decodes far more easily than long-GOP H.264/HEVC.
    case optimized
    /// Half size ProRes 422 Proxy: the lightest to play, for big or many layers.
    case proxy

    var id: String { rawValue }
    var title: String { self == .optimized ? "Optimized" : "Proxy" }
    var codec: AVVideoCodecType { self == .optimized ? .proRes422 : .proRes422Proxy }
    /// Frame size relative to the original.
    var scale: Double { self == .optimized ? 1 : 0.5 }
}

/// Which files playback reads.
nonisolated enum PlaybackMedia: String, CaseIterable, Identifiable, Sendable {
    /// The original files.
    case original
    /// Optimized media where it exists, otherwise the original.
    case optimized
    /// Proxy media where it exists, then optimized, then the original.
    case proxy

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original"
        case .optimized: "Optimized"
        case .proxy: "Proxy"
        }
    }

    /// Generated kinds to try, best first.
    var preference: [GeneratedMediaKind] {
        switch self {
        case .original: []
        case .optimized: [.optimized]
        case .proxy: [.proxy, .optimized]
        }
    }
}

extension Notification.Name {
    /// Posted when generated media becomes ready or is deleted; `object` is the set of media IDs.
    static let generatedMediaChanged = Notification.Name("app.cutline.generatedMediaChanged")
}

/// Makes, finds and deletes optimized and proxy media. Files live in the Caches
/// folder, named after the original's identity (modification date and size), so a
/// changed original is never paired with an outdated copy.
@Observable
final class GeneratedMediaLibrary {
    static let shared = GeneratedMediaLibrary()

    enum Status: Equatable {
        case none
        case queued
        /// 0...1.
        case creating(Double)
        case ready
        case failed(String)
    }

    private struct Key: Hashable {
        let mediaID: UUID
        let kind: GeneratedMediaKind
    }

    private struct Request {
        let key: Key
        let media: MediaItem
    }

    /// Bumped on every status change, for views.
    private(set) var revision = 0

    @ObservationIgnored private var statuses: [Key: Status] = [:]
    @ObservationIgnored private var pending: [Request] = []
    @ObservationIgnored private var current: (key: Key, cancellation: ExportCancellation)?
    @ObservationIgnored private var worker: Task<Void, Never>?

    let folder: URL

    init(folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutline/Media", isDirectory: true)) {
        self.folder = folder
    }

    // MARK: Finding

    /// Where the `kind` copy of `media` lives (whether or not it exists yet).
    func fileURL(for media: MediaItem, kind: GeneratedMediaKind) -> URL? {
        let source = MediaURLCache.shared.url(for: media)
        guard let values = try? source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let size = values.fileSize else { return nil }
        let stamp = "\(Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0))-\(size)"
        return folder.appendingPathComponent("\(media.id.uuidString)-\(stamp)-\(kind.rawValue).mov")
    }

    func status(of media: MediaItem, kind: GeneratedMediaKind) -> Status {
        _ = revision
        let key = Key(mediaID: media.id, kind: kind)
        if let status = statuses[key], status != .ready { return status }
        guard media.hasVideo, let url = fileURL(for: media, kind: kind) else { return .none }
        return FileManager.default.fileExists(atPath: url.path) ? .ready : .none
    }

    /// The generated file playback should read for `media` under `choice`, if any.
    func playbackURL(for media: MediaItem, choice: PlaybackMedia) -> URL? {
        for kind in choice.preference where status(of: media, kind: kind) == .ready {
            if let url = fileURL(for: media, kind: kind) { return url }
        }
        return nil
    }

    /// The file playback reads for `media`: a generated copy when `choice` asks for one
    /// and it's ready, otherwise the original.
    func playbackSourceURL(for media: MediaItem, choice: PlaybackMedia = AppSettings.shared.playbackMedia) -> URL {
        playbackURL(for: media, choice: choice) ?? MediaURLCache.shared.url(for: media)
    }

    // MARK: Making

    /// Queues `kind` copies of the video files among `media` that don't have one yet.
    func create(_ kind: GeneratedMediaKind, for media: [MediaItem]) {
        for item in media where item.hasVideo && MediaURLCache.shared.isAvailable(item) {
            let key = Key(mediaID: item.id, kind: kind)
            switch status(of: item, kind: kind) {
            case .ready, .queued, .creating: continue
            case .none, .failed: break
            }
            statuses[key] = .queued
            pending.append(Request(key: key, media: item))
        }
        changed([])
        startWorker()
    }

    /// Makes the copies the Parameters ask for of newly imported media.
    func createAutomatically(for media: [MediaItem]) {
        if AppSettings.shared.createOptimizedOnImport { create(.optimized, for: media) }
        if AppSettings.shared.createProxyOnImport { create(.proxy, for: media) }
    }

    /// Stops making (or deletes) `kind` copies of `media`.
    func delete(_ kind: GeneratedMediaKind, for media: [MediaItem]) {
        var ids = Set<UUID>()
        for item in media {
            let key = Key(mediaID: item.id, kind: kind)
            pending.removeAll { $0.key == key }
            if current?.key == key { current?.cancellation.cancel() }
            statuses[key] = nil
            if let url = fileURL(for: item, kind: kind), FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                ids.insert(item.id)
            }
        }
        changed(ids)
    }

    /// Waits until nothing is queued or being made (for tests).
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func startWorker() {
        guard worker == nil else { return }
        worker = Task {
            while !pending.isEmpty {
                let request = pending.removeFirst()
                await make(request)
            }
            worker = nil
        }
    }

    private func make(_ request: Request) async {
        let key = request.key
        guard let destination = fileURL(for: request.media, kind: key.kind) else {
            statuses[key] = .failed("The original file can’t be read.")
            changed([])
            return
        }
        let cancellation = ExportCancellation()
        current = (key, cancellation)
        statuses[key] = .creating(0)
        changed([])
        let source = MediaURLCache.shared.url(for: request.media)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await MediaTranscoder.transcode(source, to: destination, kind: key.kind, cancellation: cancellation) { fraction in
                Task { @MainActor in
                    guard case .creating = self.statuses[key] else { return }
                    self.statuses[key] = .creating(fraction)
                    self.revision += 1
                }
            }
            statuses[key] = nil  // Found on disk from now on.
            changed([key.mediaID])
        } catch {
            statuses[key] = cancellation.isCancelled ? nil : .failed(error.localizedDescription)
            changed([])
        }
        current = nil
    }

    private func changed(_ ids: Set<UUID>) {
        revision += 1
        if !ids.isEmpty { NotificationCenter.default.post(name: .generatedMediaChanged, object: ids) }
    }

    // MARK: Disk use

    /// Bytes used by all generated media.
    func diskUsage() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Deletes every generated file (not ones being made right now).
    func deleteAll() {
        pending.removeAll()
        current?.cancellation.cancel()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var ids = Set<UUID>()
        for file in files {
            if let id = UUID(uuidString: String(file.lastPathComponent.prefix(36))) { ids.insert(id) }
            try? FileManager.default.removeItem(at: file)
        }
        statuses.removeAll()
        changed(ids)
    }
}

/// Writes a ProRes copy of a movie's picture with exactly the same frame times, so a
/// copy can stand in for the original anywhere on the timeline.
nonisolated enum MediaTranscoder {
    enum Failure: LocalizedError {
        case noVideo
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "The file has no video."
            case .failed(let reason): reason
            }
        }
    }

    static func transcode(_ source: URL, to destination: URL, kind: GeneratedMediaKind,
                          cancellation: ExportCancellation, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (naturalSize, transform, timeRange) = try await track.load(.naturalSize, .preferredTransform, .timeRange)
        let width = max(2, Int((abs(naturalSize.width) * kind.scale / 2).rounded()) * 2)
        let height = max(2, Int((abs(naturalSize.height) * kind.scale / 2).rounded()) * 2)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_422YpCbCr10, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange],
        ])

        // Written beside the destination and moved into place when complete.
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: kind.codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspectFill,
        ])
        // The same orientation as the original, so the compositor treats both alike.
        input.transform = transform

        let provider = reader.outputProvider(for: output)
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try reader.start()
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        let streams = TranscodeStreams(provider: provider, receiver: receiver)
        let total = max(timeRange.duration.seconds, 0.001)
        do {
            // Reading waits for each frame, so it runs on a thread of its own.
            try await Task.detached(executorPreference: MediaWorkThread(label: "app.cutline.transcode")) {
                while let sample = try await streams.provider.next() {
                    if cancellation.isCancelled { throw CancellationError() }
                    guard case .pixelBuffer(let pixels) = sample.content else { continue }
                    let time = sample.presentationTimeStamp
                    try await streams.receiver.append(pixels, with: time)
                    progress(min(1, max(0, CMTimeSubtract(time, timeRange.start).seconds / total)))
                }
                streams.receiver.finish()
            }.value
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: temp)
            if cancellation.isCancelled || error is CancellationError { throw CancellationError() }
            throw Failure.failed(error.localizedDescription)
        }
        // Exactly as long as the original track.
        writer.endSession(atSourceTime: timeRange.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            throw Failure.failed(writer.error?.localizedDescription ?? "The copy couldn’t be finished.")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    private struct TranscodeStreams: @unchecked Sendable {
        let provider: AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>
        let receiver: AVAssetWriterInput.PixelBufferReceiver
    }
}
