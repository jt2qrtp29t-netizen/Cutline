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
        /// How far from `time` the frame may be (half a tile): the decoder can use a nearby
        /// full frame instead of decoding seconds of long-GOP video for each thumbnail.
        var tolerance: Time = Time(seconds: 0.25)
    }

    /// Bumped (at most a few times per second) whenever new images land.
    private(set) var revision = 0

    /// The images, dropped least recently shown first when over budget. (Not NSCache: it
    /// evicts in no particular order, including images on screen, which then flickered
    /// as they were made again and pushed out others.)
    @ObservationIgnored private var images: [String: (image: CGImage, cost: Int, used: UInt64)] = [:]
    @ObservationIgnored private var totalCost = 0
    @ObservationIgnored private var useCounter: UInt64 = 0
    /// Memory budget in bytes.
    let costLimit: Int
    @ObservationIgnored private var generators: [String: AVAssetImageGenerator] = [:]
    /// Waiting requests by key, with when they were last asked for.
    @ObservationIgnored private var pending: [String: (request: Request, asked: ContinuousClock.Instant)] = [:]
    @ObservationIgnored private var running: Set<String> = []
    /// Frames that couldn't be made (not retried on every redraw).
    @ObservationIgnored private var failed: Set<String> = []
    /// Cached times per media and size, to offer the nearest frame while a new one is made.
    @ObservationIgnored private var cachedTimes: [String: [Int64]] = [:]
    @ObservationIgnored private var revisionScheduled = false

    /// Decodes at once at most; the hardware decoder is shared with playback.
    static let maximumRunning = 3
    /// Requests nobody has asked for again within this long are dropped (scrolled away,
    /// or a speed drag moved every tile on).
    static let staleAfter = Duration.milliseconds(1_500)

    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?

    init(costLimit: Int = 256 << 20) {
        self.costLimit = costLimit
        // When the Mac is short of memory, keep only what was shown most recently.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.trim(to: costLimit / 4) }
        }
        source.activate()
        memoryPressure = source
    }

    /// The thumbnail if it's ready. Otherwise starts making it (unless `generate` is off,
    /// e.g. mid-drag) and returns the nearest frame already made for that media, if any.
    func image(for request: Request, generate: Bool = true) -> CGImage? {
        let key = Self.key(for: request)
        if let image = use(key) { return image }
        if generate { enqueue(request, key: key) }
        return nearest(to: request)
    }

    /// Whether this exact frame has been made (not just a nearby stand-in).
    func isCached(_ request: Request) -> Bool {
        images[Self.key(for: request)] != nil
    }

    /// An image, marked as just shown.
    private func use(_ key: String) -> CGImage? {
        guard let entry = images[key] else { return nil }
        useCounter &+= 1
        images[key]?.used = useCounter
        return entry.image
    }

    /// Keeps a made frame, then drops the least recently shown ones while over budget.
    func insert(_ image: CGImage, for request: Request) {
        let key = Self.key(for: request)
        let cost = image.bytesPerRow * image.height
        useCounter &+= 1
        if let old = images.updateValue((image, cost, useCounter), forKey: key) { totalCost -= old.cost }
        totalCost += cost
        let group = Self.group(for: request)
        var times = cachedTimes[group] ?? []
        if !times.contains(request.time.ticks) { times.append(request.time.ticks) }
        cachedTimes[group] = times
        if totalCost > costLimit { trim(to: costLimit * 3 / 4) }
    }

    /// Drops least recently shown images until under `budget` bytes.
    func trim(to budget: Int) {
        guard totalCost > budget else { return }
        for (key, entry) in images.sorted(by: { $0.value.used < $1.value.used }) {
            guard totalCost > budget else { break }
            images[key] = nil
            totalCost -= entry.cost
            if let at = key.lastIndex(of: "@"), let ticks = Int64(key[key.index(after: at)...]) {
                let group = String(key[..<at])
                cachedTimes[group]?.removeAll { $0 == ticks }
            }
        }
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
        pending = pending.filter { !matches($0.key) }
        failed = failed.filter { !matches($0) }
        cachedTimes = cachedTimes.filter { !matches($0.key) }
        for (key, entry) in images where matches(key) {
            images[key] = nil
            totalCost -= entry.cost
        }
        generators = generators.filter { !matches($0.key) }
        revision &+= 1
    }

    private static func key(for request: Request) -> String {
        // The file path is part of the key so a relinked item never shows the old file's frames.
        "\(group(for: request))@\(request.time.ticks)"
    }

    private static func group(for request: Request) -> String {
        "\(request.mediaID.uuidString)/\(request.size.rawValue)#\(request.url.path.hashValue)"
    }

    private func nearest(to request: Request) -> CGImage? {
        let group = Self.group(for: request)
        guard let times = cachedTimes[group], !times.isEmpty else { return nil }
        let best = times.min { abs($0 - request.time.ticks) < abs($1 - request.time.ticks) }!
        return use("\(group)@\(best)")
    }

    private func generator(for request: Request) -> AVAssetImageGenerator {
        let tolerance = min(max(request.tolerance, Time(seconds: 0.25)), Time(seconds: 2))
        let key = "\(Self.group(for: request))~\(tolerance.ticks)"
        if let existing = generators[key] { return existing }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: request.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = request.size.maximumPixels
        generator.requestedTimeToleranceBefore = tolerance.cmTime
        generator.requestedTimeToleranceAfter = tolerance.cmTime
        generators[key] = generator
        return generator
    }

    private func enqueue(_ request: Request, key: String) {
        guard !failed.contains(key), !running.contains(key) else { return }
        pending[key] = (request, ContinuousClock.now)
        pump()
    }

    /// Starts the most recently wanted requests, a few at a time.
    private func pump() {
        let now = ContinuousClock.now
        pending = pending.filter { now - $0.value.asked < Self.staleAfter }
        while running.count < Self.maximumRunning,
              let next = pending.max(by: { $0.value.asked < $1.value.asked }) {
            pending[next.key] = nil
            running.insert(next.key)
            let key = next.key, request = next.value.request
            generator(for: request).generateCGImageAsynchronously(for: request.time.cmTime) { [weak self] image, _, _ in
                Task { @MainActor in
                    self?.finish(key: key, request: request, image: image)
                }
            }
        }
    }

    private func finish(key: String, request: Request, image: CGImage?) {
        running.remove(key)
        if let image {
            insert(image, for: request)
            scheduleRevision()
        } else {
            failed.insert(key)
        }
        pump()
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
