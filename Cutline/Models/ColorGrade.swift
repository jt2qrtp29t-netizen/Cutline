import Foundation

/// One color wheel (lift, gamma, gain or offset): a puck and a master amount.
///
/// The puck sits in the unit disk. Its direction is a hue, laid out like a
/// vectorscope (x = Cb, y = Cr), and its distance from the center is the strength.
/// The resulting per-channel shift has zero Rec.709 luma, so moving the puck changes
/// color without changing brightness; `master` changes brightness.
nonisolated struct ColorWheel: Codable, Hashable, Sendable {
    var x = 0.0
    var y = 0.0
    /// -1...1, 0 = unchanged.
    var master = 0.0

    static let neutral = ColorWheel()
    var isNeutral: Bool { self == .neutral }

    /// The color shift of the puck: zero-luma RGB from Cb/Cr (Rec.709).
    var chroma: SIMD3<Double> {
        SIMD3(1.5748 * y, -0.1873 * x - 0.4681 * y, 1.8556 * x) * 0.5
    }

    init(x: Double = 0, y: Double = 0, master: Double = 0) {
        self.x = x
        self.y = y
        self.master = master
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        master = try c.decodeIfPresent(Double.self, forKey: .master) ?? 0
    }
}

nonisolated struct CurvePoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

/// A curve through draggable points, interpolated with a monotone cubic so it never
/// overshoots between points. Points are kept sorted by x.
nonisolated struct ToneCurve: Codable, Hashable, Sendable {
    var points: [CurvePoint]

    static let identity = ToneCurve(points: [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)])
    var isIdentity: Bool { points.allSatisfy { $0.x == $0.y } }

    init(points: [CurvePoint]) {
        self.points = points.sorted { $0.x < $1.x }
    }

    /// The curve at `x`. Outside the first and last points it continues with slope 1,
    /// so values beyond 0...1 (e.g. after a large offset) aren't flattened.
    func value(at x: Double) -> Double { Evaluator(self)(x) }

    /// Evaluates the curve many times without recomputing its tangents.
    struct Evaluator {
        private let points: [CurvePoint]
        private let slopes: [Double]

        init(_ curve: ToneCurve) {
            points = curve.points
            slopes = points.count > 1 ? Self.tangents(points) : []
        }

        func callAsFunction(_ x: Double) -> Double {
            guard let first = points.first, let last = points.last else { return x }
            guard points.count > 1 else { return first.y + (x - first.x) }
            if x <= first.x { return first.y + (x - first.x) }
            if x >= last.x { return last.y + (x - last.x) }
            // Binary search for the segment holding x.
            var lo = 0, hi = points.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if points[mid].x <= x { lo = mid } else { hi = mid }
            }
            let a = points[lo], b = points[hi]
            let h = b.x - a.x
            guard h > 0 else { return b.y }
            let t = (x - a.x) / h
            let t2 = t * t, t3 = t2 * t
            return (2 * t3 - 3 * t2 + 1) * a.y + (t3 - 2 * t2 + t) * h * slopes[lo]
                + (-2 * t3 + 3 * t2) * b.y + (t3 - t2) * h * slopes[hi]
        }

        /// Fritsch–Carlson tangents: a cubic Hermite through the points that stays
        /// monotone wherever the points are.
        private static func tangents(_ p: [CurvePoint]) -> [Double] {
            let n = p.count
            var delta = [Double](repeating: 0, count: n - 1)
            for i in 0..<(n - 1) {
                let h = p[i + 1].x - p[i].x
                delta[i] = h > 0 ? (p[i + 1].y - p[i].y) / h : 0
            }
            var m = [Double](repeating: 0, count: n)
            m[0] = delta[0]
            m[n - 1] = delta[n - 2]
            for i in 1..<(n - 1) {
                m[i] = delta[i - 1] * delta[i] <= 0 ? 0 : (delta[i - 1] + delta[i]) / 2
            }
            for i in 0..<(n - 1) where delta[i] == 0 {
                m[i] = 0
                m[i + 1] = 0
            }
            for i in 0..<(n - 1) where delta[i] != 0 {
                let a = m[i] / delta[i], b = m[i + 1] / delta[i]
                let s = a * a + b * b
                if s > 9 {
                    let k = 3 / s.squareRoot()
                    m[i] = k * a * delta[i]
                    m[i + 1] = k * b * delta[i]
                }
            }
            return m
        }
    }
}

/// Master curve applied to all channels first, then one curve per channel.
nonisolated struct RGBCurves: Codable, Hashable, Sendable {
    var master = ToneCurve.identity
    var red = ToneCurve.identity
    var green = ToneCurve.identity
    var blue = ToneCurve.identity

    static let identity = RGBCurves()
    var isIdentity: Bool { master.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        master = try c.decodeIfPresent(ToneCurve.self, forKey: .master) ?? .identity
        red = try c.decodeIfPresent(ToneCurve.self, forKey: .red) ?? .identity
        green = try c.decodeIfPresent(ToneCurve.self, forKey: .green) ?? .identity
        blue = try c.decodeIfPresent(ToneCurve.self, forKey: .blue) ?? .identity
    }
}

/// Hue vs saturation: x is hue (0...1, red at 0 and 1), y is 0...1 with 0.5 unchanged,
/// 0 fully desaturated and 1 double saturation. The curve wraps around at red.
nonisolated struct HueCurve: Codable, Hashable, Sendable {
    var points: [CurvePoint] = []

    static let identity = HueCurve()
    var isIdentity: Bool { points.allSatisfy { $0.y == 0.5 } }

    /// Saturation multiplier for a hue.
    func saturationScale(atHue hue: Double) -> Double { Evaluator(self)(hue) }

    /// Evaluates the curve many times without rebuilding it.
    struct Evaluator {
        private let curve: ToneCurve.Evaluator?

        init(_ hueCurve: HueCurve) {
            let sorted = hueCurve.points.sorted { $0.x < $1.x }
            // Repeat the points one turn before and after so the curve wraps smoothly.
            let wrapped = sorted.map { CurvePoint(x: $0.x - 1, y: $0.y) } + sorted + sorted.map { CurvePoint(x: $0.x + 1, y: $0.y) }
            curve = sorted.isEmpty ? nil : ToneCurve.Evaluator(ToneCurve(points: wrapped))
        }

        func callAsFunction(_ hue: Double) -> Double {
            guard let curve else { return 1 }
            let h = hue - hue.rounded(.down)
            return curve(h).clamped(to: 0...1) * 2
        }
    }
}

/// A .cube LUT file applied at the end of the grade.
nonisolated struct LUTReference: Codable, Hashable, Sendable {
    var name: String
    var path: String
    var bookmark: Data?

    var fileURL: URL { URL(fileURLWithPath: path) }

    /// Resolves the file, preferring the bookmark so moved files are still found.
    func resolveURL() -> URL {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  bookmarkDataIsStale: &stale) {
                return url
            }
        }
        return fileURL
    }
}

nonisolated extension ProjectState {
    /// The project with every grade (and grade keyframe) removed: the "before" view.
    func withoutGrades() -> ProjectState {
        var copy = self
        for t in copy.tracks.indices {
            for c in copy.tracks[t].clips.indices {
                copy.tracks[t].clips[c].color = .neutral
                for property in AnimatableProperty.grade { copy.tracks[t].clips[c].animation.keyframes[property] = nil }
            }
        }
        return copy
    }
}

/// A clip's color grade. It is applied in one fixed order (see `ColorPipeline`):
///
/// 1. exposure
/// 2. white balance (temperature, tint)
/// 3. offset
/// 4. lift, gain, gamma
/// 5. brightness, contrast, saturation, then highlights and shadows
/// 6. curves (master, then red, green, blue), then hue vs saturation
/// 7. LUT (mixed in by its intensity)
///
/// and clamped only at the end, so a large negative offset doesn't destroy data that
/// a later step brings back.
nonisolated struct ColorGrade: Codable, Hashable, Sendable {
    /// Exposure in stops, -3...3.
    var exposure: Double = 0
    /// -1...1, 0 = unchanged.
    var brightness: Double = 0
    /// 0...2, 1 = unchanged.
    var contrast: Double = 1
    /// 0...2, 1 = unchanged.
    var saturation: Double = 1
    /// -1 (cool) ... 1 (warm).
    var temperature: Double = 0
    /// -1 (green) ... 1 (magenta).
    var tint: Double = 0
    /// -1...1, 0 = unchanged.
    var highlights: Double = 0
    var shadows: Double = 0

    var lift = ColorWheel.neutral
    var gamma = ColorWheel.neutral
    var gain = ColorWheel.neutral
    var offset = ColorWheel.neutral

    var curves = RGBCurves.identity
    var hueSaturation = HueCurve.identity

    var lut: LUTReference?
    /// 0...1: how much of the LUT's result is used.
    var lutIntensity: Double = 1

    static let neutral = ColorGrade()
    var isNeutral: Bool { self == .neutral }

    init() {}

    // Older projects only stored exposure, brightness, contrast and saturation.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        lift = try c.decodeIfPresent(ColorWheel.self, forKey: .lift) ?? .neutral
        gamma = try c.decodeIfPresent(ColorWheel.self, forKey: .gamma) ?? .neutral
        gain = try c.decodeIfPresent(ColorWheel.self, forKey: .gain) ?? .neutral
        offset = try c.decodeIfPresent(ColorWheel.self, forKey: .offset) ?? .neutral
        curves = try c.decodeIfPresent(RGBCurves.self, forKey: .curves) ?? .identity
        hueSaturation = try c.decodeIfPresent(HueCurve.self, forKey: .hueSaturation) ?? .identity
        lut = try c.decodeIfPresent(LUTReference.self, forKey: .lut)
        lutIntensity = try c.decodeIfPresent(Double.self, forKey: .lutIntensity) ?? 1
    }
}
