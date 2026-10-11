import CoreImage
import Foundation

nonisolated extension ExperimentRegistry {
    /// The experiments that ship with Cutline.
    static let builtIn: [Experiment] = [
        // MARK: Generators

        Experiment(id: "solid", name: "Solid Color", summary: "A single color filling the frame.",
                   kind: .generator, symbolName: "square.fill",
                   parameters: [
                       ExperimentParameter(id: "hue", name: "Hue", range: 0...360, defaultValue: 210, unit: "°"),
                       ExperimentParameter(id: "saturation", name: "Saturation", range: 0...1, defaultValue: 0.6),
                       ExperimentParameter(id: "brightness", name: "Brightness", range: 0...1, defaultValue: 0.6),
                   ]) { context in
            CIImage(color: LabColor.hsb(context.value("hue"), context.value("saturation"), context.value("brightness")))
                .cropped(to: context.canvas)
        },

        Experiment(id: "gradient", name: "Gradient", summary: "A smooth blend between two colors at any angle.",
                   kind: .generator, symbolName: "square.fill.and.line.vertical.and.square",
                   parameters: [
                       ExperimentParameter(id: "angle", name: "Angle", range: 0...360, defaultValue: 90, unit: "°"),
                       ExperimentParameter(id: "hueA", name: "First Hue", range: 0...360, defaultValue: 20, unit: "°"),
                       ExperimentParameter(id: "hueB", name: "Second Hue", range: 0...360, defaultValue: 260, unit: "°"),
                       ExperimentParameter(id: "brightness", name: "Brightness", range: 0...1, defaultValue: 0.8),
                   ]) { context in
            let canvas = context.canvas
            let angle = context.value("angle") * .pi / 180
            let center = CGPoint(x: canvas.midX, y: canvas.midY)
            let reach = (canvas.width * abs(cos(angle)) + canvas.height * abs(sin(angle))) / 2
            let dx = cos(angle) * reach, dy = sin(angle) * reach
            let b = context.value("brightness")
            guard let gradient = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: center.x - dx, y: center.y - dy),
                "inputPoint1": CIVector(x: center.x + dx, y: center.y + dy),
                "inputColor0": LabColor.hsb(context.value("hueA"), 0.75, b),
                "inputColor1": LabColor.hsb(context.value("hueB"), 0.75, b),
            ])?.outputImage else { throw ExperimentError.message("Core Image has no linear gradient.") }
            return gradient.cropped(to: canvas)
        },

        Experiment(id: "noise", name: "Noise", summary: "Animated film-grain style noise, in gray or color.",
                   kind: .generator, symbolName: "aqi.medium",
                   parameters: [
                       ExperimentParameter(id: "grain", name: "Grain Size", range: 1...40, defaultValue: 3, unit: "px"),
                       ExperimentParameter(id: "contrast", name: "Contrast", range: 0.2...2, defaultValue: 1),
                       ExperimentParameter(id: "color", name: "Color", range: 0...1, defaultValue: 0),
                       ExperimentParameter(id: "speed", name: "Speed", range: 0...60, defaultValue: 24, unit: "/s"),
                   ]) { context in
            // A new noise pattern `speed` times a second, by sliding the infinite random image.
            let step = (context.time * context.value("speed")).rounded(.down)
            let grain = context.value("grain")
            return CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(translationX: step * 97, y: step * 61))
                .samplingNearest()
                .transformed(by: CGAffineTransform(scaleX: grain, y: grain))
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: context.value("color"),
                    kCIInputContrastKey: context.value("contrast"),
                ])
                .cropped(to: context.canvas)
        },

        Experiment(id: "bars", name: "Color Bars", summary: "75% color bars for checking color and levels.",
                   kind: .generator, symbolName: "rectangle.split.3x1.fill",
                   parameters: [
                       ExperimentParameter(id: "level", name: "Level", range: 0.5...1, defaultValue: 0.75),
                   ]) { context in
            let canvas = context.canvas
            let l = context.value("level")
            let colors: [(Double, Double, Double)] = [(l, l, l), (l, l, 0), (0, l, l), (0, l, 0), (l, 0, l), (l, 0, 0), (0, 0, l)]
            let width = canvas.width / CGFloat(colors.count)
            var image = CIImage(color: .black).cropped(to: canvas)
            for (index, c) in colors.enumerated() {
                let bar = CGRect(x: canvas.minX + CGFloat(index) * width, y: canvas.minY, width: width + 1, height: canvas.height)
                image = CIImage(color: CIColor(red: c.0, green: c.1, blue: c.2)).cropped(to: bar).composited(over: image)
            }
            return image.cropped(to: canvas)
        },

        // MARK: Effects

        Experiment(id: "rgbSplit", name: "RGB Split & Glitch",
                   summary: "Pulls the red and blue channels apart and tears random strips sideways.",
                   kind: .effect, symbolName: "square.3.layers.3d.down.right",
                   parameters: [
                       ExperimentParameter(id: "amount", name: "Split", range: 0...80, defaultValue: 12, unit: "px"),
                       ExperimentParameter(id: "angle", name: "Direction", range: 0...360, defaultValue: 0, unit: "°"),
                       ExperimentParameter(id: "glitch", name: "Glitch", range: 0...1, defaultValue: 0.4),
                       ExperimentParameter(id: "speed", name: "Glitch Rate", range: 0...30, defaultValue: 8, unit: "/s"),
                   ]) { context in
            guard let input = context.input else { throw ExperimentError.message("Needs a clip to work on.") }
            return try LabGlitch.render(input, canvas: context.canvas, amount: context.value("amount"),
                                    angle: context.value("angle"), glitch: context.value("glitch"),
                                    seed: Int((context.time * context.value("speed")).rounded(.down)))
        },

        Experiment(id: "waveWarp", name: "Wave Warp (Metal)",
                   summary: "Ripples the picture with a Metal shader compiled when first used.",
                   kind: .effect, symbolName: "water.waves",
                   parameters: [
                       ExperimentParameter(id: "amplitude", name: "Amplitude", range: 0...80, defaultValue: 14, unit: "px"),
                       ExperimentParameter(id: "wavelength", name: "Wavelength", range: 10...400, defaultValue: 90, unit: "px"),
                       ExperimentParameter(id: "speed", name: "Speed", range: -10...10, defaultValue: 2),
                   ]) { context in
            guard let input = context.input else { throw ExperimentError.message("Needs a clip to work on.") }
            guard let kernel = try KernelCache.shared.kernels(for: LabShaders.waveWarp).first as? CIWarpKernel else {
                throw ExperimentError.message("The wave shader didn’t produce a warp kernel.")
            }
            let amplitude = context.value("amplitude")
            let output = kernel.apply(extent: input.extent, roiCallback: { _, rect in
                rect.insetBy(dx: -amplitude * 1.5 - 1, dy: -amplitude * 1.5 - 1)
            }, image: input, arguments: [amplitude, context.value("wavelength"), context.time * context.value("speed")])
            guard let output else { throw ExperimentError.message("The wave shader couldn’t run.") }
            return output.cropped(to: input.extent)
        },

        Experiment(id: "customShader", name: "Custom Shader",
                   summary: "Write your own Metal color shader. Sliders A, B and C and the time are passed in.",
                   kind: .effect, symbolName: "chevron.left.forwardslash.chevron.right",
                   parameters: [
                       ExperimentParameter(id: "a", name: "A", range: 0...1, defaultValue: 0.5),
                       ExperimentParameter(id: "b", name: "B", range: 0...1, defaultValue: 0.3),
                       ExperimentParameter(id: "c", name: "C", range: 0...1, defaultValue: 0.2),
                   ],
                   defaultSource: LabShaders.customDefault) { context in
            guard let input = context.input else { throw ExperimentError.message("Needs a clip to work on.") }
            let source = context.source ?? LabShaders.customDefault
            guard let kernel = try KernelCache.shared.kernels(for: source).first else {
                throw ExperimentError.message("The shader has no [[stitchable]] function.")
            }
            let arguments: [Any] = [input, context.value("a"), context.value("b"), context.value("c"), context.time]
            let output: CIImage?
            if let color = kernel as? CIColorKernel {
                output = color.apply(extent: input.extent, arguments: arguments)
            } else if kernel is CIWarpKernel {
                throw ExperimentError.message("Write a color kernel: it gets each pixel’s color (coreimage::sample_t) and returns a float4.")
            } else {
                output = kernel.apply(extent: input.extent, roiCallback: { _, rect in rect }, arguments: arguments)
            }
            guard let output else {
                throw ExperimentError.message("The shader couldn’t run. Its function should take the color, then a, b, c and time.")
            }
            return output
        },
    ]
}

// MARK: Helpers

nonisolated enum LabColor {
    /// A color from hue (degrees), saturation and brightness (0...1).
    static func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> CIColor {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch Int(h) {
        case 0: (c, x, 0)
        case 1: (x, c, 0)
        case 2: (0, c, x)
        case 3: (0, x, c)
        case 4: (x, 0, c)
        default: (c, 0, x)
        }
        let m = brightness - c
        return CIColor(red: r + m, green: g + m, blue: b + m)
    }
}

nonisolated enum LabGlitch {
    static func render(_ input: CIImage, canvas: CGRect, amount: Double, angle: Double, glitch: Double, seed: Int) throws -> CIImage {
        // Channel split (a Metal shader): red read from one side, blue from the other.
        let radians = angle * .pi / 180
        let dx = cos(radians) * amount, dy = sin(radians) * amount
        guard let kernel = try KernelCache.shared.kernels(for: LabShaders.rgbSplit).first else {
            throw ExperimentError.message("The RGB split shader didn’t compile.")
        }
        let reach = abs(amount) + 1
        guard var image = kernel.apply(extent: input.extent, roiCallback: { _, rect in rect.insetBy(dx: -reach, dy: -reach) },
                                       arguments: [input, CIVector(x: dx, y: dy)]) else {
            throw ExperimentError.message("The RGB split shader couldn’t run.")
        }
        image = image.cropped(to: input.extent)

        // Tears: a few horizontal strips shifted sideways, different for each glitch step.
        guard glitch > 0, !input.extent.isInfinite else { return image }
        var random = SplitMix(seed: UInt64(bitPattern: Int64(seed)))
        let strips = 1 + Int(glitch * 8)
        let extent = input.extent
        for _ in 0..<strips {
            guard random.next() < glitch else { continue }
            let height = extent.height * (0.01 + 0.08 * random.next())
            let y = extent.minY + (extent.height - height) * random.next()
            let shift = (random.next() - 0.5) * extent.width * 0.15 * glitch
            let strip = image.cropped(to: CGRect(x: extent.minX, y: y, width: extent.width, height: height))
                .transformed(by: CGAffineTransform(translationX: shift, y: 0))
            image = strip.composited(over: image)
        }
        return image.cropped(to: extent)
    }

    /// A tiny deterministic random sequence, so a glitch looks the same each time it plays.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }
}

/// Core Image kernels compiled from Metal source at runtime, by source text.
nonisolated final class KernelCache: @unchecked Sendable {
    static let shared = KernelCache()
    /// Least recently used first, so shaders in use are never recompiled mid-playback.
    private let compiled = LRUCache<String, Result<[CIKernel], Error>>(countLimit: 64)

    /// The kernels in `source`, compiling it the first time. Throws the compiler's message.
    func kernels(for source: String) throws -> [CIKernel] {
        if let cached = compiled[source] { return try cached.get() }
        let result: Result<[CIKernel], Error> = Result {
            do {
                let kernels = try CIKernel.kernels(withMetalString: source)
                guard !kernels.isEmpty else { throw ExperimentError.message("No [[stitchable]] function was found.") }
                return kernels
            } catch let error as ExperimentError {
                throw error
            } catch {
                throw ExperimentError.message(Self.describe(error))
            }
        }
        compiled.set(result, for: source)
        return try result.get()
    }

    /// The useful part of a Metal compiler error. Core Image wraps the compiler's
    /// error, so look through the underlying errors for the one with the message.
    private static func describe(_ error: Error) -> String {
        var texts: [String] = []
        var current: NSError? = error as NSError
        while let e = current {
            texts.append(e.localizedDescription)
            if let reason = e.localizedFailureReason { texts.append(reason) }
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let line = texts.flatMap { $0.split(separator: "\n").map(String.init) }.first { $0.contains("error:") }
        guard let line else { return "Shader didn’t compile: " + (texts.first ?? "unknown error") }
        // Drop "program_source:1453:25:": the line numbers refer to Core Image's expanded source.
        let message = line.replacingOccurrences(of: #"^.*?\d+:\d+:\s*error:\s*"#, with: "", options: .regularExpression)
        return "Shader didn’t compile: " + message
    }
}

nonisolated enum LabShaders {
    static let rgbSplit = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" float4 rgbSplit(coreimage::sampler src, float2 offset, coreimage::destination dest) [[stitchable]] {
        float2 p = dest.coord();
        float4 center = src.sample(src.transform(p));
        float4 red = src.sample(src.transform(p - offset));
        float4 blue = src.sample(src.transform(p + offset));
        return float4(red.r, center.g, blue.b, max(center.a, max(red.a, blue.a)));
    }
    """

    static let waveWarp = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" float2 waveWarp(float amplitude, float wavelength, float phase, coreimage::destination dest) [[stitchable]] {
        float2 p = dest.coord();
        return float2(p.x + amplitude * sin(p.y / wavelength + phase),
                      p.y + amplitude * 0.5 * sin(p.x / (wavelength * 1.3) + phase * 0.7));
    }
    """

    static let customDefault = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    // Edit me! This function gets each pixel's color and returns a new one.
    // a, b and c are the sliders (0 to 1); time is in seconds.
    extern "C" float4 shade(coreimage::sample_t color, float a, float b, float c, float time) [[stitchable]] {
        // A: swap green and blue. B: extra saturation. C: pulse with time.
        float3 rgb = mix(color.rgb, float3(color.r, color.b, color.g), a);
        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        rgb = mix(float3(luma), rgb, 1.0 + b * 2.0);
        float pulse = 0.75 + 0.25 * sin(time * 3.0);
        rgb = mix(rgb, rgb * pulse, c);
        return float4(rgb, color.a);
    }
    """
}
