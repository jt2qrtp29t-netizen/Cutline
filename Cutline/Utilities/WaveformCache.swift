import AVFoundation
import Observation

/// Audio peak data for drawing waveforms, computed once per media item in the
/// background and kept in memory. Like `ThumbnailCache`, a miss returns nil,
/// schedules the work, and bumps `revision` when the data arrives.
@Observable
final class WaveformCache {
    static let shared = WaveformCache()

    /// Peak resolution: one value per 10 ms of source audio.
    nonisolated static let bucketsPerSecond = 100.0
    nonisolated private static let analysisSampleRate = 8000.0

    private(set) var revision = 0

    @ObservationIgnored private var peaks: [UUID: [Float]] = [:]
    @ObservationIgnored private var loading: Set<UUID> = []

    /// Drops peaks for media whose file went missing, moved or came back.
    func forget(_ ids: Set<UUID>) {
        for id in ids where peaks[id] != nil {
            peaks[id] = nil
            revision &+= 1
        }
    }

    func peaks(for media: MediaItem, url: URL) -> [Float]? {
        if let cached = peaks[media.id] { return cached }
        guard media.hasAudio, !loading.contains(media.id) else { return nil }
        loading.insert(media.id)
        Task {
            let result = await Self.readPeaks(from: url) ?? []
            peaks[media.id] = result
            loading.remove(media.id)
            revision &+= 1
        }
        return nil
    }

    /// Decodes the first audio track to mono floats and keeps the peak of each bucket,
    /// normalized so the loudest bucket is 1.
    @concurrent
    nonisolated private static func readPeaks(from url: URL) async -> [Float]? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: analysisSampleRate,
        ])
        guard reader.canAdd(output) else { return nil }
        let provider = reader.outputProvider(for: output)
        do { try reader.start() } catch { return nil }

        let samplesPerBucket = Int(analysisSampleRate / bucketsPerSecond)
        var result: [Float] = []
        var current: Float = 0
        var count = 0

        while let ready = try? await provider.next() {
            let samples: [Float] = ready.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
                let length = CMBlockBufferGetDataLength(block)
                var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                samples.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                return samples
            }
            for sample in samples {
                current = max(current, abs(sample))
                count += 1
                if count == samplesPerBucket {
                    result.append(current)
                    current = 0
                    count = 0
                }
            }
        }
        if count > 0 { result.append(current) }

        let loudest = result.max() ?? 0
        guard loudest > 0 else { return result }
        return result.map { $0 / loudest }
    }
}
