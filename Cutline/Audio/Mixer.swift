import Foundation
import Observation

/// Where a fader's knob sits for a level: a console-style scale with more travel
/// around 0 dB (three quarters up) than in the quiet end.
nonisolated enum FaderScale {
    /// (dB, position) from the top of the fader down.
    static let points: [(db: Double, position: Double)] = [
        (12, 1), (6, 0.89), (0, 0.76), (-6, 0.64), (-12, 0.52), (-20, 0.4), (-30, 0.28), (-40, 0.18), (-60, 0.07), (-96, 0),
    ]
    static let range = -96.0...12.0

    static func position(forDB db: Double) -> Double {
        let db = min(max(db, range.lowerBound), range.upperBound)
        for (upper, lower) in zip(points, points.dropFirst()) where db >= lower.db {
            let u = (db - lower.db) / (upper.db - lower.db)
            return lower.position + (upper.position - lower.position) * u
        }
        return 0
    }

    static func db(forPosition position: Double) -> Double {
        let p = min(max(position, 0), 1)
        for (upper, lower) in zip(points, points.dropFirst()) where p >= lower.position {
            let u = (p - lower.position) / (upper.position - lower.position)
            return lower.db + (upper.db - lower.db) * u
        }
        return range.lowerBound
    }

    /// How a level reads on a fader: "0.0", "−6.5", "+3.0", or "−∞".
    static func label(_ db: Double) -> String {
        if db <= -95.5 { return "−∞" }
        let text = String(format: "%.1f", abs(db))
        return db > 0.05 ? "+" + text : (db < -0.05 ? "−" + text : "0.0")
    }

    /// Tick marks drawn beside the fader.
    static let ticks: [Double] = [12, 6, 0, -6, -12, -20, -30, -40, -60]
}

/// How a meter moves: it jumps up to a new peak at once, falls back smoothly, holds the
/// highest recent peak for a moment, and latches the clip light until it's clicked.
nonisolated struct MeterBallistics: Equatable, Sendable {
    /// Bottom of the meter.
    static let floorDB = -60.0
    /// How fast the bar falls, in dB per second.
    static let fallRate = 24.0
    static let holdTime = 1.5

    var level = floorDB
    var peakHold = floorDB
    var holdAge = 0.0
    var clipped = false

    /// Advances by `elapsed` seconds with the peak measured since the last update (linear).
    mutating func update(peak: Double, sawClip: Bool, elapsed: Double) {
        let db = max(Self.floorDB, AudioLevel.db(fromLinear: peak))
        level = max(db, level - Self.fallRate * elapsed)
        holdAge += elapsed
        if db >= peakHold || holdAge > Self.holdTime {
            peakHold = max(db, level)
            holdAge = 0
        }
        if sawClip { clipped = true }
    }

    /// Position of a level on the meter (0 = floor, 1 = 0 dBFS).
    static func fraction(_ db: Double) -> Double {
        min(max((db - floorDB) / -floorDB, 0), 1)
    }
}

/// The mixer's meters for one editor: reads the peaks the audio graph measured about
/// 30 times a second while the mixer is on screen (never per audio buffer), and only
/// publishes a change when a bar actually moves.
@Observable
final class MixerMeters {
    struct Reading: Equatable {
        var left = MeterBallistics()
        var right = MeterBallistics()
        var isActive: Bool { left.level > MeterBallistics.floorDB || right.level > MeterBallistics.floorDB || left.clipped || right.clipped }
    }

    static let refreshInterval = 1.0 / 30

    private(set) var tracks: [UUID: Reading] = [:]
    private(set) var master = Reading()
    /// The master's loudness (published when it moves by a tenth of a LU or more).
    private(set) var loudness = LoudnessReading()

    @ObservationIgnored private weak var graph: AudioGraph?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watchers = 0

    init(graph: AudioGraph) {
        self.graph = graph
    }

    /// Starts reading while a mixer view is visible.
    func beginWatching() {
        watchers += 1
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.tick() }
        }
    }

    func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Clears a strip's clip lights (click on them).
    func resetClip(track id: UUID?) {
        if let id {
            tracks[id]?.left.clipped = false
            tracks[id]?.right.clipped = false
        } else {
            master.left.clipped = false
            master.right.clipped = false
        }
    }

    /// One refresh: read every meter and move the bars.
    func tick(elapsed: Double = refreshInterval) {
        guard let graph else { return }
        var next = tracks
        for id in graph.trackIDs {
            guard let meter = graph.meter(forTrack: id) else { continue }
            next[id] = Self.advance(next[id] ?? Reading(), meter.read(), elapsed: elapsed)
        }
        next = next.filter { graph.trackIDs.contains($0.key) }
        let nextMaster = Self.advance(master, graph.masterMeter.read(), elapsed: elapsed)
        // Publish only visible movement, so idle meters don't redraw.
        if !Self.same(next, tracks) { tracks = next }
        if !Self.same(nextMaster, master) { master = nextMaster }
        let nextLoudness = graph.loudness.read()
        func moved(_ a: Double, _ b: Double) -> Bool { abs(a - b) >= 0.05 }
        if moved(nextLoudness.momentary, loudness.momentary) || moved(nextLoudness.shortTerm, loudness.shortTerm)
            || moved(nextLoudness.integrated, loudness.integrated) || moved(nextLoudness.truePeak, loudness.truePeak) {
            loudness = nextLoudness
        }
    }

    private static func advance(_ reading: Reading, _ peaks: (left: Float, right: Float, clipped: Bool), elapsed: Double) -> Reading {
        var r = reading
        r.left.update(peak: Double(peaks.left), sawClip: peaks.clipped && peaks.left >= PeakMeter.clipLevel, elapsed: elapsed)
        r.right.update(peak: Double(peaks.right), sawClip: peaks.clipped && peaks.right >= PeakMeter.clipLevel, elapsed: elapsed)
        return r
    }

    private static func same(_ a: Reading, _ b: Reading) -> Bool {
        func close(_ x: MeterBallistics, _ y: MeterBallistics) -> Bool {
            abs(x.level - y.level) < 0.25 && abs(x.peakHold - y.peakHold) < 0.25 && x.clipped == y.clipped
        }
        return close(a.left, b.left) && close(a.right, b.right)
    }

    private static func same(_ a: [UUID: Reading], _ b: [UUID: Reading]) -> Bool {
        a.count == b.count && a.allSatisfy { key, value in b[key].map { same(value, $0) } ?? false }
    }
}
