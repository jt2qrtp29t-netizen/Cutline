import CoreImage
import Foundation

/// Renders a `ColorGrade` with Core Image, on the GPU. Preview, scrubbing and export
/// all go through `apply`, so they always match.
///
/// Fixed order (see `ColorGrade`), with the Core Image step used for each:
/// 1. exposure — `CIExposureAdjust`
/// 2–4. white balance, offset, lift, gain — one `CIColorMatrix` (all per-channel
///      scale-and-add), then gamma — `CIColorCurves`
/// 5. brightness/contrast/saturation — `CIColorControls`; highlights/shadows — color cube
/// 6. RGB curves — `CIColorCurves`; hue vs saturation — color cube
/// 7. LUT — the same color cube
/// then a single clamp to 0...1 at the very end.
///
/// Steps 2–7 work on encoded values in `gradingSpace`, and nothing is clamped
/// between them. Exposure and the color controls are the filters older versions
/// used, so grades made then render exactly as before.
nonisolated enum ColorPipeline {
    /// The color space grading happens in. Rec.709 for now: HDR work only needs to
    /// change this (and the curve/cube domains).
    static let gradingSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
    /// Entries per side of generated color cubes.
    static let cubeSize = 33
    /// Input range covered by the 1D tables, wide enough for values pushed past black
    /// or white by earlier steps; samples per table.
    static let curveDomain = -1.0...2.0
    static let curveSamples = 1536

    static func apply(_ grade: ColorGrade, to image: CIImage, lut: CubeLUT?) -> CIImage {
        guard !grade.isNeutral else { return image }
        var image = image
        var graded = false

        if grade.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: grade.exposure])
        }
        if !PrimariesKey(grade).isLinearIdentity {
            let (scale, bias) = primariesMatrix(grade)
            image = (image.matchedFromWorkingSpace(to: gradingSpace) ?? image)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: scale.x, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: scale.y, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: scale.z, w: 0),
                    "inputBiasVector": CIVector(x: bias.x, y: bias.y, z: bias.z, w: 0),
                ])
                .matchedToWorkingSpace(from: gradingSpace) ?? image
            graded = true
        }
        if !grade.gamma.isNeutral {
            image = curves(image) { gammaCurve($0, grade) }
            graded = true
        }
        if grade.brightness != 0 || grade.contrast != 1 || grade.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: grade.brightness,
                kCIInputContrastKey: grade.contrast,
                kCIInputSaturationKey: grade.saturation,
            ])
        }
        if grade.highlights != 0 || grade.shadows != 0 {
            image = cube(image, data: cubes.data(for: .tone(grade.highlights, grade.shadows)) { tone($0, grade) })
            graded = true
        }
        if !grade.curves.isIdentity {
            let evaluators = CurveEvaluators(grade)
            image = curves(image) { evaluators.rgb($0) }
            graded = true
        }
        let finish = FinishKey(grade, lut: lut)
        if !finish.isIdentity {
            let evaluator = HueCurve.Evaluator(grade.hueSaturation)
            image = cube(image, data: cubes.data(for: .finish(finish)) { self.finish($0, grade, lut: lut, hue: evaluator) })
            graded = true
        }
        // Clamp once, at the end. Grades from before the Color tab never clamped
        // (the output buffer did), so they're left exactly as they were.
        if graded {
            image = image.applyingFilter("CIColorClamp")
        }
        return image
    }

    private static func cube(_ image: CIImage, data: Data) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": cubeSize,
            "inputCubeData": data,
            "inputColorSpace": gradingSpace,
            "inputExtrapolate": true,
        ])
    }

    /// A per-channel 1D lookup over `curveDomain`.
    private static func curves(_ image: CIImage, _ transform: (SIMD3<Double>) -> SIMD3<Double>) -> CIImage {
        var table = [Float](repeating: 0, count: curveSamples * 3)
        let lo = curveDomain.lowerBound, span = curveDomain.upperBound - curveDomain.lowerBound
        for i in 0..<curveSamples {
            let v = lo + span * Double(i) / Double(curveSamples - 1)
            let out = transform(SIMD3(repeating: v))
            table[i * 3] = Float(out.x)
            table[i * 3 + 1] = Float(out.y)
            table[i * 3 + 2] = Float(out.z)
        }
        return image.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table.withUnsafeBufferPointer { Data(buffer: $0) },
            "inputCurvesDomain": CIVector(x: curveDomain.lowerBound, y: curveDomain.upperBound),
            "inputColorSpace": gradingSpace,
        ])
    }

    // MARK: Math (encoded Rec.709 values; anything outside 0...1 is kept)

    /// Steps 2–4 for one color: white balance, offset, lift, gain, then gamma.
    static func primaries(_ c: SIMD3<Double>, _ g: ColorGrade) -> SIMD3<Double> {
        let (scale, bias) = primariesMatrix(g)
        return gammaCurve(c * scale + bias, g)
    }

    /// White balance, offset, lift and gain are all per-channel `v × a + b`, so they
    /// combine into one scale and bias:
    ///   v₁ = v × wb + offset
    ///   v₂ = v₁ + lift × (1 − v₁)     (lift raises blacks, fading out toward white)
    ///   v₃ = v₂ × gain
    static func primariesMatrix(_ g: ColorGrade) -> (scale: SIMD3<Double>, bias: SIMD3<Double>) {
        // White balance: warm raises red and lowers blue; tint trades green for magenta.
        let wb = SIMD3(1 + 0.3 * g.temperature + 0.1 * g.tint, 1 - 0.3 * g.tint, 1 - 0.3 * g.temperature + 0.1 * g.tint)
        let offset = SIMD3(repeating: g.offset.master * 0.5) + g.offset.chroma * 0.5
        let lift = SIMD3(repeating: g.lift.master * 0.5) + g.lift.chroma * 0.8
        let gain = SIMD3(repeating: 1 + g.gain.master) + g.gain.chroma * 1.6
        let one = SIMD3<Double>(repeating: 1)
        return (wb * (one - lift) * gain, (offset * (one - lift) + lift) * gain)
    }

    /// Gamma bends the midtones (positive brightens them); values at or below zero pass through.
    static func gammaCurve(_ c: SIMD3<Double>, _ g: ColorGrade) -> SIMD3<Double> {
        var v = c
        let gamma = SIMD3(repeating: g.gamma.master) + g.gamma.chroma * 1.6
        for i in 0..<3 where v[i] > 0 && gamma[i] != 0 {
            v[i] = pow(v[i], pow(2, -gamma[i]))
        }
        return v
    }

    /// Steps 5 (second half) to 7 for one color: highlights/shadows, curves, hue vs
    /// saturation, then the LUT.
    static func secondaries(_ c: SIMD3<Double>, _ g: ColorGrade, lut: CubeLUT?) -> SIMD3<Double> {
        let curves = CurveEvaluators(g)
        return finish(curves.rgb(tone(c, g)), g, lut: lut, hue: curves.hue)
    }

    /// Highlights and shadows: brighten or darken by luminance.
    static func tone(_ c: SIMD3<Double>, _ g: ColorGrade) -> SIMD3<Double> {
        guard g.highlights != 0 || g.shadows != 0 else { return c }
        let luma = min(max(dot(c, lumaWeights), 0), 1)
        let shadowWeight = 1 - smoothstep(0, 0.6, luma)
        let highlightWeight = smoothstep(0.4, 1, luma)
        return c + SIMD3(repeating: 0.3 * (g.shadows * shadowWeight + g.highlights * highlightWeight))
    }

    /// Hue vs saturation, then the LUT mixed in by its intensity.
    static func finish(_ c: SIMD3<Double>, _ g: ColorGrade, lut: CubeLUT?, hue: HueCurve.Evaluator) -> SIMD3<Double> {
        var v = c
        if !g.hueSaturation.isIdentity {
            let luma = dot(v, lumaWeights)
            let scale = hue(Self.hue(of: v))
            v = SIMD3(repeating: luma) + (v - SIMD3(repeating: luma)) * scale
        }
        if let lut, g.lutIntensity > 0 {
            let mapped = lut.sample(v)
            v += (mapped - v) * min(max(g.lutIntensity, 0), 1)
        }
        return v
    }

    /// Curve evaluators built once per frame rather than per sample.
    struct CurveEvaluators {
        let master, red, green, blue: ToneCurve.Evaluator
        let hue: HueCurve.Evaluator

        init(_ g: ColorGrade) {
            master = ToneCurve.Evaluator(g.curves.master)
            red = ToneCurve.Evaluator(g.curves.red)
            green = ToneCurve.Evaluator(g.curves.green)
            blue = ToneCurve.Evaluator(g.curves.blue)
            hue = HueCurve.Evaluator(g.hueSaturation)
        }

        /// Master curve, then each channel's own.
        func rgb(_ v: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(red(master(v.x)), green(master(v.y)), blue(master(v.z)))
        }
    }

    static let lumaWeights = SIMD3<Double>(0.2126, 0.7152, 0.0722)

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

    /// HSV hue, 0...1 (red 0, green 1/3, blue 2/3).
    static func hue(of c: SIMD3<Double>) -> Double {
        let maxV = c.max(), minV = c.min()
        let d = maxV - minV
        guard d > 1e-9 else { return 0 }
        var h: Double
        if maxV == c.x { h = (c.y - c.z) / d } else if maxV == c.y { h = 2 + (c.z - c.x) / d } else { h = 4 + (c.x - c.y) / d }
        h /= 6
        return h < 0 ? h + 1 : h
    }

    // MARK: Cubes

    /// What the primaries depend on.
    struct PrimariesKey: Hashable {
        let temperature, tint: Double
        let lift, gain, offset: ColorWheel

        init(_ g: ColorGrade) {
            temperature = g.temperature
            tint = g.tint
            lift = g.lift
            gain = g.gain
            offset = g.offset
        }

        /// No white balance, offset, lift or gain: the color matrix can be skipped.
        var isLinearIdentity: Bool {
            temperature == 0 && tint == 0 && lift.isNeutral && gain.isNeutral && offset.isNeutral
        }
    }

    /// What the final cube (hue vs saturation and LUT) depends on.
    struct FinishKey: Hashable {
        let hueSaturation: HueCurve
        let lutPath: String?
        let lutIntensity: Double

        init(_ g: ColorGrade, lut: CubeLUT?) {
            hueSaturation = g.hueSaturation
            lutPath = lut == nil || g.lutIntensity <= 0 ? nil : g.lut?.path
            lutIntensity = lutPath == nil ? 0 : g.lutIntensity
        }

        var isIdentity: Bool { hueSaturation.isIdentity && lutPath == nil }
    }

    enum CubeKey: Hashable {
        case tone(Double, Double)
        case finish(FinishKey)
    }

    static let cubes = CubeCache()

    /// Generated cube data, reused while a grade doesn't change. Thread-safe: frames
    /// render on several queues. The least recently used cubes go first, so an animated
    /// grade (a new cube every frame) can't push out the steady grades of other clips.
    final class CubeCache: @unchecked Sendable {
        private let cache = LRUCache<CubeKey, Data>(countLimit: 128)

        func data(for key: CubeKey, _ transform: (SIMD3<Double>) -> SIMD3<Double>) -> Data {
            cache.value(for: key) { ColorPipeline.makeCube(transform) }
        }
    }

    /// Float RGBA cube data for `CIColorCubeWithColorSpace` (red fastest, then green, blue).
    static func makeCube(_ transform: (SIMD3<Double>) -> SIMD3<Double>) -> Data {
        let n = cubeSize
        var values = [Float](repeating: 1, count: n * n * n * 4)
        let step = 1 / Double(n - 1)
        var i = 0
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = transform(SIMD3(Double(r) * step, Double(g) * step, Double(b) * step))
                    values[i] = Float(out.x)
                    values[i + 1] = Float(out.y)
                    values[i + 2] = Float(out.z)
                    i += 4
                }
            }
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Loaded .cube LUTs by file, so each is parsed once. Missing or invalid files give
/// nil (and the reason), and the grade renders without a LUT.
nonisolated final class LUTLibrary: @unchecked Sendable {
    static let shared = LUTLibrary()

    private let lock = NSLock()
    private var loaded: [String: (stamp: Date?, result: Result<CubeLUT, Error>)] = [:]

    func lut(for reference: LUTReference?) -> CubeLUT? {
        guard let reference else { return nil }
        return try? result(for: reference).get()
    }

    /// The parsed LUT or why it couldn't be used.
    func result(for reference: LUTReference) -> Result<CubeLUT, Error> {
        let url = reference.resolveURL()
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        lock.lock()
        if let cached = loaded[url.path], cached.stamp == stamp, stamp != nil {
            lock.unlock()
            return cached.result
        }
        lock.unlock()
        let result: Result<CubeLUT, Error>
        if stamp == nil && !FileManager.default.fileExists(atPath: url.path) {
            result = .failure(CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: url.path]))
        } else {
            result = Result { try CubeLUT.load(from: url) }
        }
        lock.lock()
        loaded[url.path] = (stamp, result)
        lock.unlock()
        return result
    }

    func isAvailable(_ reference: LUTReference) -> Bool {
        (try? result(for: reference).get()) != nil
    }
}
