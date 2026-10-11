import Foundation

/// Signal processing for the track effects, run sample by sample on the render
/// thread. Everything here is deterministic: the same input and parameters always
/// give the same output, in real time and offline.
nonisolated enum DSP {
    static let sampleRate = AudioGraphFormat.sampleRate

    /// One-pole smoothing coefficient for a time constant in milliseconds.
    static func coefficient(ms: Double) -> Double {
        ms <= 0 ? 0 : exp(-1 / (ms * 0.001 * sampleRate))
    }

    @inline(__always) static func db(_ linear: Double) -> Double { linear > 1e-9 ? 20 * log10(linear) : -180 }
    @inline(__always) static func linear(_ db: Double) -> Double { pow(10, db / 20) }
}

/// Biquad coefficients (RBJ audio EQ cookbook), normalized so a0 = 1.
nonisolated struct BiquadCoefficients: Equatable {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0

    static let identity = BiquadCoefficients()

    private static func make(_ b0: Double, _ b1: Double, _ b2: Double, _ a0: Double, _ a1: Double, _ a2: Double) -> BiquadCoefficients {
        BiquadCoefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func omega(_ frequency: Double) -> (cos: Double, sin: Double) {
        let w = 2 * .pi * min(max(frequency, 10), DSP.sampleRate * 0.49) / DSP.sampleRate
        return (cos(w), sin(w))
    }

    static func highPass(_ f: Double, q: Double = 0.7071) -> BiquadCoefficients {
        let (c, s) = omega(f), alpha = s / (2 * q)
        return make((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func lowPass(_ f: Double, q: Double = 0.7071) -> BiquadCoefficients {
        let (c, s) = omega(f), alpha = s / (2 * q)
        return make((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + alpha, -2 * c, 1 - alpha)
    }

    static func peak(_ f: Double, gainDB: Double, q: Double) -> BiquadCoefficients {
        let (c, s) = omega(f), a = pow(10, gainDB / 40), alpha = s / (2 * max(q, 0.05))
        return make(1 + alpha * a, -2 * c, 1 - alpha * a, 1 + alpha / a, -2 * c, 1 - alpha / a)
    }

    static func lowShelf(_ f: Double, gainDB: Double) -> BiquadCoefficients {
        let (c, s) = omega(f), a = pow(10, gainDB / 40), alpha = s / 2 * 2.0.squareRoot()
        let sq = 2 * a.squareRoot() * alpha
        return make(a * ((a + 1) - (a - 1) * c + sq), 2 * a * ((a - 1) - (a + 1) * c), a * ((a + 1) - (a - 1) * c - sq),
                    (a + 1) + (a - 1) * c + sq, -2 * ((a - 1) + (a + 1) * c), (a + 1) + (a - 1) * c - sq)
    }

    static func highShelf(_ f: Double, gainDB: Double) -> BiquadCoefficients {
        let (c, s) = omega(f), a = pow(10, gainDB / 40), alpha = s / 2 * 2.0.squareRoot()
        let sq = 2 * a.squareRoot() * alpha
        return make(a * ((a + 1) + (a - 1) * c + sq), -2 * a * ((a - 1) + (a + 1) * c), a * ((a + 1) + (a - 1) * c - sq),
                    (a + 1) - (a - 1) * c + sq, 2 * ((a - 1) - (a + 1) * c), (a + 1) - (a - 1) * c - sq)
    }
}

/// A stereo biquad (transposed direct form II): coefficients can change between
/// samples without resetting the filter's memory.
nonisolated struct StereoBiquad {
    var k = BiquadCoefficients.identity
    private var l1 = 0.0, l2 = 0.0, r1 = 0.0, r2 = 0.0

    @inline(__always) mutating func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let yl = k.b0 * l + l1
        l1 = k.b1 * l - k.a1 * yl + l2
        l2 = k.b2 * l - k.a2 * yl
        let yr = k.b0 * r + r1
        r1 = k.b1 * r - k.a1 * yr + r2
        r2 = k.b2 * r - k.a2 * yr
        return (yl, yr)
    }
}

/// A peak level follower: rises with `attack`, falls with `release`.
nonisolated struct EnvelopeFollower {
    var attack = DSP.coefficient(ms: 1)
    var release = DSP.coefficient(ms: 100)
    var level = 0.0

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let c = x > level ? attack : release
        level = c * level + (1 - c) * x
        return level
    }
}

// MARK: - Effects

/// One effect's signal processing. `update` receives the parameter values (in the
/// order of `AudioEffectKind.parameters`) at most every control interval.
nonisolated protocol EffectDSP: AnyObject {
    func update(_ values: [Double])
    func process(_ l: Double, _ r: Double) -> (Double, Double)
}

nonisolated enum EffectDSPFactory {
    static func make(_ kind: AudioEffectKind) -> EffectDSP {
        switch kind {
        case .equalizer: EqualizerDSP()
        case .compressor: CompressorDSP()
        case .gate: GateDSP()
        case .deEsser: DeEsserDSP()
        case .limiter: LimiterDSP()
        case .noiseReduction: NoiseReductionDSP()
        }
    }
}

/// Low and high cut (24 dB per octave), a low shelf, two bells and a high shelf.
/// Filters at their neutral settings are skipped, so a flat EQ passes sound exactly.
nonisolated final class EqualizerDSP: EffectDSP {
    private var cutLow = [StereoBiquad(), StereoBiquad()]
    private var cutHigh = [StereoBiquad(), StereoBiquad()]
    private var bands = [StereoBiquad(), StereoBiquad(), StereoBiquad(), StereoBiquad()]
    private var lowCutOn = false, highCutOn = false
    private var bandOn = [false, false, false, false]
    private var last: [Double] = []

    func update(_ v: [Double]) {
        guard v != last, v.count >= 12 else { return }
        last = v
        lowCutOn = v[0] > 20.5
        if lowCutOn {
            // Two stages of a fourth-order Butterworth.
            cutLow[0].k = .highPass(v[0], q: 0.5412)
            cutLow[1].k = .highPass(v[0], q: 1.3066)
        }
        highCutOn = v[1] < 19_999
        if highCutOn {
            cutHigh[0].k = .lowPass(v[1], q: 0.5412)
            cutHigh[1].k = .lowPass(v[1], q: 1.3066)
        }
        bandOn = [v[3] != 0, v[5] != 0, v[8] != 0, v[11] != 0]
        bands[0].k = .lowShelf(v[2], gainDB: v[3])
        bands[1].k = .peak(v[4], gainDB: v[5], q: v[6])
        bands[2].k = .peak(v[7], gainDB: v[8], q: v[9])
        bands[3].k = .highShelf(v[10], gainDB: v[11])
    }

    func process(_ l: Double, _ r: Double) -> (Double, Double) {
        var (l, r) = (l, r)
        if lowCutOn { (l, r) = cutLow[0].process(l, r); (l, r) = cutLow[1].process(l, r) }
        if highCutOn { (l, r) = cutHigh[0].process(l, r); (l, r) = cutHigh[1].process(l, r) }
        for i in 0..<4 where bandOn[i] { (l, r) = bands[i].process(l, r) }
        return (l, r)
    }
}

/// Feed-forward compressor with a soft knee, stereo linked.
nonisolated final class CompressorDSP: EffectDSP {
    private var threshold = -18.0, ratio = 3.0, knee = 6.0, makeup = 0.0
    private var attack = 0.0, release = 0.0
    /// Current gain reduction in dB (≤ 0).
    private(set) var reduction = 0.0

    func update(_ v: [Double]) {
        threshold = v[0]; ratio = max(v[1], 1)
        attack = DSP.coefficient(ms: v[2]); release = DSP.coefficient(ms: v[3])
        knee = v[4]; makeup = v[5]
    }

    /// Static gain change (dB) for an input level.
    static func gainComputer(_ x: Double, threshold: Double, ratio: Double, knee: Double) -> Double {
        let over = x - threshold
        if knee > 0, abs(over) <= knee / 2 {
            let t = over + knee / 2
            return (1 / ratio - 1) * t * t / (2 * knee)
        }
        return over > 0 ? over * (1 / ratio - 1) : 0
    }

    func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let level = DSP.db(max(abs(l), abs(r)))
        let target = Self.gainComputer(level, threshold: threshold, ratio: ratio, knee: knee)
        let c = target < reduction ? attack : release
        reduction = c * reduction + (1 - c) * target
        let g = DSP.linear(reduction + makeup)
        return (l * g, r * g)
    }
}

/// Noise gate: opens above the threshold, holds, then closes down to `range`.
nonisolated final class GateDSP: EffectDSP {
    private var threshold = -50.0, range = 0.01
    private var attack = 0.0, release = 0.0, holdSamples = 0
    private var detector = EnvelopeFollower(attack: DSP.coefficient(ms: 0.1), release: DSP.coefficient(ms: 20))
    private var held = 0
    private var gain = 1.0

    func update(_ v: [Double]) {
        threshold = v[0]; range = DSP.linear(v[1])
        attack = DSP.coefficient(ms: v[2]); holdSamples = Int(v[3] * 0.001 * DSP.sampleRate)
        release = DSP.coefficient(ms: v[4])
    }

    func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let level = DSP.db(detector.process(max(abs(l), abs(r))))
        if level >= threshold { held = holdSamples } else if held > 0 { held -= 1 }
        let open = level >= threshold || held > 0
        let target = open ? 1 : range
        let c = target > gain ? attack : release
        gain = c * gain + (1 - c) * target
        return (l * gain, r * gain)
    }
}

/// De-esser as a dynamic high shelf: a detector listens to the band above `frequency`,
/// and while it's louder than the threshold a high shelf at that frequency cuts by up to
/// `amount`. Below the threshold the shelf is at 0 dB and the sound passes exactly.
nonisolated final class DeEsserDSP: EffectDSP {
    private var sidechain = StereoBiquad()
    private var shelf = StereoBiquad()
    private var detector = EnvelopeFollower(attack: DSP.coefficient(ms: 0.5), release: DSP.coefficient(ms: 60))
    private var threshold = -30.0, amount = 8.0, frequency = 0.0
    private var reduction = 0.0
    private var shelfReduction = 0.0
    private let smoothing = DSP.coefficient(ms: 2)
    private var counter = 0

    func update(_ v: [Double]) {
        if v[0] != frequency {
            frequency = v[0]
            sidechain.k = .highPass(frequency)
            shelfReduction = .nan  // Rebuild the shelf at the new frequency.
        }
        threshold = v[1]; amount = v[2]
    }

    func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let (hl, hr) = sidechain.process(l, r)
        // The follower sits below a fast sine's peaks; +3 dB reads it as its RMS-ish level.
        let level = DSP.db(detector.process(max(abs(hl), abs(hr)))) + 3
        let target = min(amount, max(0, (level - threshold) * 0.75))
        reduction = smoothing * reduction + (1 - smoothing) * target
        // Re-tune the shelf every 16 samples, or when the cut moved noticeably.
        counter += 1
        if counter >= 16 || !(abs(reduction - shelfReduction) < 0.25) {
            counter = 0
            shelfReduction = reduction
            shelf.k = reduction < 0.01 ? .identity : .highShelf(frequency, gainDB: -reduction)
        }
        if shelfReduction < 0.01 && reduction < 0.01 { return (l, r) }
        return shelf.process(l, r)
    }
}

/// Peak limiter: instant gain reduction for anything over the ceiling, smooth release,
/// and a hard stop at the ceiling. No look-ahead, so it adds no delay.
nonisolated final class LimiterDSP: EffectDSP {
    private var ceiling = 0.891, release = 0.0
    private var gain = 1.0

    func update(_ v: [Double]) {
        ceiling = DSP.linear(v[0]); release = DSP.coefficient(ms: v[1])
    }

    func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let peak = max(abs(l), abs(r))
        let target = peak > ceiling ? ceiling / peak : 1
        gain = target < gain ? target : release * gain + (1 - release) * target
        let lo = -ceiling, hi = ceiling
        return (min(max(l * gain, lo), hi), min(max(r * gain, lo), hi))
    }
}

/// Basic noise reduction: four bands (split at 250 Hz, 1.5 kHz and 6 kHz so they sum
/// back exactly), each turned down by `amount` while its level is under the
/// threshold. Steady hiss or hum between words drops; noise under speech stays.
nonisolated final class NoiseReductionDSP: EffectDSP {
    private var lows = [StereoBiquad(), StereoBiquad(), StereoBiquad()]
    private var detectors = [EnvelopeFollower](repeating: EnvelopeFollower(attack: DSP.coefficient(ms: 1), release: DSP.coefficient(ms: 60)), count: 4)
    private var gains = [Double](repeating: 1, count: 4)
    private var threshold = -55.0, floorGain = 0.25
    private var attack = DSP.coefficient(ms: 2), release = 0.0

    init() {
        lows[0].k = .lowPass(250)
        lows[1].k = .lowPass(1500)
        lows[2].k = .lowPass(6000)
    }

    func update(_ v: [Double]) {
        threshold = v[0]; floorGain = DSP.linear(-v[1]); release = DSP.coefficient(ms: v[2])
    }

    @inline(__always) private func band(_ i: Int, _ l: Double, _ r: Double) -> (Double, Double) {
        let level = DSP.db(detectors[i].process(max(abs(l), abs(r))))
        let target = level < threshold ? floorGain : 1
        let c = target > gains[i] ? attack : release
        gains[i] = c * gains[i] + (1 - c) * target
        return (l * gains[i], r * gains[i])
    }

    func process(_ l: Double, _ r: Double) -> (Double, Double) {
        let (a0, a1) = lows[0].process(l, r)
        let (b0, b1) = lows[1].process(l, r)
        let (c0, c1) = lows[2].process(l, r)
        // Differences of the lowpasses: the four bands add back up to the input exactly.
        let (w0, w1) = band(0, a0, a1)
        let (x0, x1) = band(1, b0 - a0, b1 - a1)
        let (y0, y1) = band(2, c0 - b0, c1 - b1)
        let (z0, z1) = band(3, l - c0, r - c1)
        return (w0 + x0 + y0 + z0, w1 + x1 + y1 + z1)
    }
}
