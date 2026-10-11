import AVFoundation
import Observation

/// The game track's ducking gain over the timeline: one value per millisecond, worked
/// out ahead of time from the voice track, so playback and export duck identically.
nonisolated struct DuckingCurve: Sendable, Equatable {
    let gameTrackID: UUID
    /// Gain in dB every `step` samples from the start of the timeline.
    let gainsDB: [Float]

    static let step: Int64 = 48  // 1 ms at 48 kHz

    /// The gain (dB) at a timeline sample, interpolated between milliseconds; 0 dB outside.
    @inline(__always) func gainDB(at sample: Int64) -> Double {
        guard sample >= 0, !gainsDB.isEmpty else { return 0 }
        let index = Int(sample / Self.step)
        guard index + 1 < gainsDB.count else { return index < gainsDB.count ? Double(gainsDB[index]) : 0 }
        let f = Float(sample % Self.step) / Float(Self.step)
        return Double(gainsDB[index] + (gainsDB[index + 1] - gainsDB[index]) * f)
    }

    /// Builds the curve from the voice's peak level (dB) in each millisecond. The voice
    /// counts as present above the threshold; it stays "present" for a short hold so
    /// the game doesn't pump between words. The game goes down linearly over the attack
    /// time, starting that early so it's already down when the voice begins, and comes
    /// back up linearly over the release time.
    static func compute(voiceLevels: [Float], settings: DuckingSettings) -> DuckingCurve {
        let n = voiceLevels.count
        let hold = Int(DuckingSettings.holdMS)
        let attack = max(1, Int(settings.attackMS))
        var present = [Bool](repeating: false, count: n)
        var lastLoud = -Int.max / 2
        for i in 0..<n {
            if Double(voiceLevels[i]) >= settings.thresholdDB { lastLoud = i }
            present[i] = i - lastLoud <= hold
        }
        // Look ahead by the attack time: duck if the voice is present within it.
        var early = [Bool](repeating: false, count: n)
        var nextPresent = Int.max / 2
        for i in stride(from: n - 1, through: 0, by: -1) {
            if present[i] { nextPresent = i }
            early[i] = nextPresent - i <= attack
        }
        let amount = min(0, settings.amountDB)
        let down = -amount / Double(attack)
        let up = -amount / max(1, settings.releaseMS)
        var gains = [Float](repeating: 0, count: n)
        var g = 0.0
        for i in 0..<n {
            let target = early[i] ? amount : 0
            g = target < g ? max(target, g - down) : min(target, g + up)
            gains[i] = Float(g)
        }
        return DuckingCurve(gameTrackID: settings.gameTrackID, gainsDB: gains)
    }
}

/// Works out a ducking curve: renders the voice track alone (through its clips, effects
/// and fader, as it sounds in the mix) and measures its peak level every millisecond.
nonisolated enum DuckingAnalyzer {
    /// The project with only the voice track sounding, through a neutral master.
    static func voiceOnly(_ state: ProjectState, _ settings: DuckingSettings) -> ProjectState {
        var voice = state
        voice.audio.ducking = nil
        voice.audio.master = MasterAudio()
        for index in voice.trackIndices(of: .audio) {
            let isVoice = voice.tracks[index].id == settings.voiceTrackID
            voice.tracks[index].isSoloed = isVoice
            if !isVoice { voice.tracks[index].clips = [] }
        }
        return voice
    }

    static func curve(for state: ProjectState, sources: [UUID: PreparedAudio], isCancelled: () -> Bool = { false }) throws -> DuckingCurve? {
        guard let settings = state.audio.ducking, settings.isEnabled else { return nil }
        let duration = state.duration
        guard duration > .zero else { return DuckingCurve(gameTrackID: settings.gameTrackID, gainsDB: []) }
        var levels: [Float] = []
        levels.reserveCapacity(Int(duration.seconds * 1000) + 1)
        var blockPeak: Float = 0, inBlock = 0
        try AudioGraph.render(voiceOnly(state, settings), range: TimeRange(start: .zero, end: duration), sources: sources,
                              isCancelled: isCancelled) { buffer in
            let n = Int(buffer.frameLength)
            let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
            for i in 0..<n {
                blockPeak = max(blockPeak, abs(l[i]), abs(r[i]))
                inBlock += 1
                if inBlock == Int(DuckingCurve.step) {
                    levels.append(Float(AudioLevel.db(fromLinear: Double(blockPeak))))
                    blockPeak = 0
                    inBlock = 0
                }
            }
        }
        return DuckingCurve.compute(voiceLevels: levels, settings: settings)
    }

    /// Everything the curve depends on: the settings, the voice track and its media.
    static func signature(of state: ProjectState) -> String? {
        guard let settings = state.audio.ducking, settings.isEnabled,
              let voice = state.tracks.first(where: { $0.id == settings.voiceTrackID }) else { return nil }
        let media = state.media.filter { item in voice.clips.contains { $0.mediaID == item.id } }
        struct Key: Encodable {
            let settings: DuckingSettings
            let voice: Track
            let media: [MediaItem]
            let stamps: [String]
        }
        let stamps = media.map { DiskCache.stamp(for: $0.resolveURL()) ?? "" }
        guard let data = try? JSONEncoder().encode(Key(settings: settings, voice: voice, media: media, stamps: stamps)) else { return nil }
        return data.base64EncodedString()
    }
}

extension Notification.Name {
    /// Posted when a ducking curve finished computing.
    static let duckingCurveReady = Notification.Name("app.cutline.duckingCurveReady")
}

/// Keeps ducking curves for playback: hands out the curve for a project if it's ready,
/// and otherwise works it out in the background (playback picks it up when done).
@Observable
final class DuckingCenter {
    static let shared = DuckingCenter()

    /// Signatures being worked out right now (the UI shows "Analyzing…").
    private(set) var analyzing: Set<String> = []
    @ObservationIgnored private var cache: [String: DuckingCurve] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var latestCurve: [UUID: DuckingCurve] = [:]

    /// The project's ducking curve if it's ready. If not, starts working it out and, until
    /// then, returns the last curve for the same game track (or nil).
    func curve(for state: ProjectState) -> DuckingCurve? {
        guard let signature = DuckingAnalyzer.signature(of: state), let settings = state.audio.ducking else { return nil }
        if let curve = cache[signature] { return curve }
        start(signature, state: state)
        return latestCurve[settings.gameTrackID]
    }

    func isAnalyzing(_ state: ProjectState) -> Bool {
        DuckingAnalyzer.signature(of: state).map { analyzing.contains($0) } ?? false
    }

    /// Waits for the project's curve (used by tests; export computes its own from its snapshot).
    func prepare(for state: ProjectState) async throws -> DuckingCurve? {
        guard let signature = DuckingAnalyzer.signature(of: state) else { return nil }
        if let curve = cache[signature] { return curve }
        let curve = try await Self.compute(state)
        store(curve, signature: signature)
        return curve
    }

    private func start(_ signature: String, state: ProjectState) {
        guard !analyzing.contains(signature) else { return }
        analyzing.insert(signature)
        Task {
            let curve = try? await Self.compute(state)
            analyzing.remove(signature)
            guard let curve else { return }
            store(curve, signature: signature)
            NotificationCenter.default.post(name: .duckingCurveReady, object: nil)
        }
    }

    private func store(_ curve: DuckingCurve?, signature: String) {
        guard let curve else { return }
        cache[signature] = curve
        latestCurve[curve.gameTrackID] = curve
        order.removeAll { $0 == signature }
        order.append(signature)
        // A few recent curves are enough (an undo brings the previous one back at once).
        while order.count > 8 { cache[order.removeFirst()] = nil }
    }

    /// Prepares the voice's sources and renders it on a background thread.
    static func compute(_ state: ProjectState) async throws -> DuckingCurve? {
        let sources = await AudioSourceCache.shared.preparedSources(for: state)
        return try await Task.detached(priority: .userInitiated) {
            try DuckingAnalyzer.curve(for: state, sources: sources)
        }.value
    }
}

extension AudioSourceCache {
    /// Every audio clip's media, prepared (waiting for any still being converted).
    func preparedSources(for state: ProjectState) async -> [UUID: PreparedAudio] {
        var result: [UUID: PreparedAudio] = [:]
        let used = Set(state.trackIndices(of: .audio).flatMap { state.tracks[$0].clips.map(\.mediaID) })
        for media in state.media where used.contains(media.id) && media.hasAudio && MediaURLCache.shared.isAvailable(media) {
            if let prepared = await preparedAudio(media) { result[media.id] = prepared }
        }
        return result
    }
}
