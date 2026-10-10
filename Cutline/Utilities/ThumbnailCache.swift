import AVFoundation
import Observation

/// Generates video thumbnails asynchronously and keeps them in memory.
///
/// Views ask for a thumbnail with `image(for:)`. A cache miss returns nil and
/// schedules generation; when images arrive `revision` changes, which re-renders
/// any view that read it.
@Observable
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    enum Size: String, Hashable {
        /// Small tiles for the timeline filmstrip.
        case strip
        /// Larger, sharp frames for media bin cards.
        case poster

        var maximumPixels: CGSize {
            switch self {
            case .strip: CGSize(width: 220, height: 124)
            case .poster: CGSize(width: 480, height: 270)
            }
        }
    }

    struct Request: Hashable {
        let mediaID: UUID
        let url: URL
        /// Source time, already quantized by the caller so nearby requests share a key.
        let time: Time
        var size: Size = .strip
    }

    /// Bumped (at most a few times per second) whenever new images land.
    private(set) var revision = 0

    @ObservationIgnored private let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 4000
        return cache
    }()
    @ObservationIgnored private var generators: [String: AVAssetImageGenerator] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var revisionScheduled = false

    func image(for request: Request) -> CGImage? {
        let key = Self.key(for: request)
        if let image = cache.object(forKey: key as NSString) { return image }
        generate(request, key: key)
        return nil
    }

    /// Picks a quantization step so a strip of tiles reuses cached frames while zooming.
    static func quantum(forTileDuration seconds: Double, fps: Int) -> Time {
        let steps: [Double] = [1 / Double(fps), 0.1, 0.25, 0.5, 1, 2, 5, 10, 30, 60, 120, 300, 600]
        return Time(seconds: steps.first { $0 >= seconds } ?? 600)
    }

    static func quantize(_ time: Time, step: Time) -> Time {
        guard step.ticks > 0 else { return time }
        return Time(ticks: (time.ticks / step.ticks) * step.ticks)
    }

    /// Drops everything for media whose file went missing, moved or came back, so
    /// frames that failed (or came from the old file) are generated again.
    func forget(_ ids: Set<UUID>) {
        let prefixes = ids.map(\.uuidString)
        func matches(_ key: String) -> Bool { prefixes.contains { key.hasPrefix($0) } }
        inFlight = inFlight.filter { !matches($0) }
        generators = generators.filter { !matches($0.key) }
        revision &+= 1
    }

    private static func key(for request: Request) -> String {
        // The file path is part of the key so a relinked item never shows the old file's frames.
        "\(request.mediaID.uuidString)@\(request.time.ticks)/\(request.size.rawValue)#\(request.url.path.hashValue)"
    }

    private func generator(for request: Request) -> AVAssetImageGenerator {
        let key = "\(request.mediaID.uuidString)/\(request.size.rawValue)#\(request.url.path.hashValue)"
        if let existing = generators[key] { return existing }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: request.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = request.size.maximumPixels
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        generators[key] = generator
        return generator
    }

    private func generate(_ request: Request, key: String) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let generator = generator(for: request)
        generator.generateCGImageAsynchronously(for: request.time.cmTime) { [weak self] image, _, _ in
            Task { @MainActor in
                self?.finish(key: key, image: image)
            }
        }
    }

    private func finish(key: String, image: CGImage?) {
        // Failed keys stay in `inFlight` so a missing frame is not retried on every redraw.
        guard let image else { return }
        inFlight.remove(key)
        cache.setObject(image, forKey: key as NSString)
        scheduleRevision()
    }

    /// Coalesces many thumbnail arrivals into one redraw.
    private func scheduleRevision() {
        guard !revisionScheduled else { return }
        revisionScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            revisionScheduled = false
            revision &+= 1
        }
    }
}
