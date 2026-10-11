import Foundation

/// Loudness by ITU-R BS.1770 / EBU R128 at 48 kHz stereo: K-weighting, momentary
/// (400 ms) and short-term (3 s) loudness, gated integrated loudness, and true peak
/// (4× oversampled). Used live on the master bus and for offline analysis (Normalize),
/// so both measure the same way. All storage is allocated up front: processing never
/// allocates, so it can run on the render thread.
nonisolated final class LoudnessMeter: @unchecked Sendable {
    /// Below this, loudness reads as silence (−∞).
    static let silence = -200.0
    private static let subBlock = 4800  // 100 ms
    private static let binsPerLU = 10
    private static let histogramFloor = -70.0
    private static let binCount = 800  // −70 … +10 LUFS

    // K-weighting: a high shelf (head effects) and a high-pass (RLB), coefficients for 48 kHz.
    private var shelf = StereoBiquad()
    private var highPass = StereoBiquad()

    private var subEnergy = 0.0
    private var subCount = 0
    /// The last 30 sub-blocks' mean square (3 s).
    private var ring = [Double](repeating: 0, count: 30)
    private var ringIndex = 0
    private var filled = 0
    /// Gating blocks (400 ms, every 100 ms) by loudness bin: count and summed mean square.
    private var counts = [Int](repeating: 0, count: binCount)
    private var energies = [Double](repeating: 0, count: binCount)

    private(set) var momentary = silence
    private(set) var shortTerm = silence
    private(set) var integrated = silence
    private let truePeakMeter = TruePeakMeter()
    var truePeak: Double { truePeakMeter.peak }

    init() {
        shelf.k = BiquadCoefficients(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                                     a1: -1.69065929318241, a2: 0.73248077421585)
        highPass.k = BiquadCoefficients(b0: 1, b1: -2, b2: 1, a1: -1.99004745483398, a2: 0.99007225036621)
    }

    /// Clears everything (for a new measurement).
    func reset() {
        shelf = { var b = StereoBiquad(); b.k = shelf.k; return b }()
        highPass = { var b = StereoBiquad(); b.k = highPass.k; return b }()
        subEnergy = 0; subCount = 0
        for i in ring.indices { ring[i] = 0 }
        ringIndex = 0; filled = 0
        for i in counts.indices { counts[i] = 0; energies[i] = 0 }
        momentary = Self.silence; shortTerm = Self.silence; integrated = Self.silence
        truePeakMeter.reset()
    }

    /// Clears only the integrated measurement (the meter's reset button).
    func resetIntegrated() {
        for i in counts.indices { counts[i] = 0; energies[i] = 0 }
        integrated = Self.silence
        truePeakMeter.reset()
    }

    static func loudness(ofMeanSquare z: Double) -> Double {
        z > 1e-20 ? -0.691 + 10 * log10(z) : silence
    }

    @inline(__always) func process(_ l: Double, _ r: Double) {
        truePeakMeter.process(l, r)
        var (wl, wr) = shelf.process(l, r)
        (wl, wr) = highPass.process(wl, wr)
        subEnergy += wl * wl + wr * wr
        subCount += 1
        if subCount == Self.subBlock { finishSubBlock() }
    }

    private func finishSubBlock() {
        ring[ringIndex] = subEnergy / Double(Self.subBlock)
        ringIndex = (ringIndex + 1) % ring.count
        filled = min(filled + 1, ring.count)
        subEnergy = 0
        subCount = 0
        guard filled >= 4 else { return }
        // Momentary: the last 4 sub-blocks (400 ms), which is also the gating block.
        var z = 0.0
        for k in 1...4 { z += ring[(ringIndex - k + ring.count) % ring.count] }
        z /= 4
        momentary = Self.loudness(ofMeanSquare: z)
        var total = 0.0
        for k in 1...filled { total += ring[(ringIndex - k + ring.count) % ring.count] }
        shortTerm = filled >= 30 ? Self.loudness(ofMeanSquare: total / Double(filled)) : Self.silence
        if momentary >= Self.histogramFloor {
            let bin = min(Self.binCount - 1, Int((momentary - Self.histogramFloor) * Double(Self.binsPerLU)))
            counts[bin] += 1
            energies[bin] += z
        }
        integrated = computeIntegrated()
    }

    /// Gated mean: blocks above −70 LUFS, then above (their loudness − 10 LU).
    private func computeIntegrated() -> Double {
        var n = 0, sum = 0.0
        for i in 0..<Self.binCount where counts[i] > 0 { n += counts[i]; sum += energies[i] }
        guard n > 0 else { return Self.silence }
        let relative = Self.loudness(ofMeanSquare: sum / Double(n)) - 10
        let first = max(0, Int(((relative - Self.histogramFloor) * Double(Self.binsPerLU)).rounded(.up)))
        var gatedN = 0, gatedSum = 0.0
        for i in first..<Self.binCount where counts[i] > 0 { gatedN += counts[i]; gatedSum += energies[i] }
        return gatedN > 0 ? Self.loudness(ofMeanSquare: gatedSum / Double(gatedN)) : Self.silence
    }
}

/// True peak: the highest level between samples, found by 4× oversampling with a
/// 48-tap windowed-sinc interpolator.
nonisolated final class TruePeakMeter: @unchecked Sendable {
    private static let phases = 4
    private static let tapsPerPhase = 12
    private static let coefficients: [[Double]] = {
        let n = phases * tapsPerPhase
        let center = Double(n - 1) / 2
        var h = (0..<n).map { i -> Double in
            let x = (Double(i) - center) / Double(phases)
            let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
            let window = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(n - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(n - 1))
            return sinc * window
        }
        // Each phase passes DC at unity.
        var result: [[Double]] = []
        for p in 0..<phases {
            let taps = stride(from: p, to: n, by: phases).map { h[$0] }
            let sum = taps.reduce(0, +)
            result.append(taps.map { $0 / sum })
        }
        h = []
        return result
    }()

    /// History kept twice in a row, so the newest `tapsPerPhase` samples are always contiguous.
    private var left = [Double](repeating: 0, count: tapsPerPhase * 2)
    private var right = [Double](repeating: 0, count: tapsPerPhase * 2)
    private var index = 0
    private(set) var peak = 0.0

    func reset() {
        for i in left.indices { left[i] = 0; right[i] = 0 }
        index = 0
        peak = 0
    }

    @inline(__always) func process(_ l: Double, _ r: Double) {
        let n = Self.tapsPerPhase
        left[index] = l; left[index + n] = l
        right[index] = r; right[index + n] = r
        // The newest sample is at index + n, the oldest at index + 1.
        let newest = index + n
        for phase in Self.coefficients {
            var yl = 0.0, yr = 0.0
            for k in 0..<n {
                yl += phase[k] * left[newest - k]
                yr += phase[k] * right[newest - k]
            }
            peak = max(peak, abs(yl), abs(yr))
        }
        index = (index + 1) % n
    }
}

/// A loudness snapshot for display.
nonisolated struct LoudnessReading: Equatable, Sendable {
    var momentary = LoudnessMeter.silence
    var shortTerm = LoudnessMeter.silence
    var integrated = LoudnessMeter.silence
    /// dBTP.
    var truePeak = LoudnessMeter.silence

    static func label(_ value: Double) -> String {
        value <= -199 ? "−∞" : String(format: "%.1f", value).replacingOccurrences(of: "-", with: "−")
    }
}
