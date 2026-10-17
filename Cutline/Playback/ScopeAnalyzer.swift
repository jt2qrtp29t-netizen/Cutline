import CoreGraphics
import CoreImage
import Foundation

/// Histogram, waveform and vectorscope data for one frame.
nonisolated struct ScopeData: @unchecked Sendable {
    /// 256 bins each for red, green, blue and luma.
    var histogram: [[UInt32]]
    /// Luma waveform: `waveformWidth` columns × `levels` rows (row 0 = black). Each pixel
    /// is shared between the two nearest levels, so the total is the pixel count.
    var waveform: [Float]
    var waveformWidth: Int
    /// Vectorscope: `vectorSize` × `vectorSize`, Cb across, Cr up (row 0 = top), each
    /// pixel shared between the four nearest cells.
    var vectorscope: [Float]
    /// The traces as images, made with the analysis (off the main thread).
    var waveformImage: CGImage?
    var vectorscopeImage: CGImage?

    static let levels = 256
    static let vectorSize = 256
}

/// Computes scopes from a frame. The frame is first shrunk on the GPU with Core Image
/// (to `analysisWidth` pixels across and at most `analysisHeight` down), so the
/// counting is cheap even at 4K60. Rows are kept more than columns: each waveform
/// column gets many samples, so its trace is continuous rather than dotted.
nonisolated enum ScopeAnalyzer {
    static let analysisWidth = 512
    static let analysisHeight = 720
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Downsamples `image` and reads it back as encoded Rec.709 RGBA8.
    static func downsample(_ image: CIImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite else { return nil }
        let scaleX = min(1, CGFloat(analysisWidth) / extent.width)
        let scaleY = min(1, CGFloat(analysisHeight) / extent.height)
        let width = max(1, Int((extent.width * scaleX).rounded()))
        let height = max(1, Int((extent.height * scaleY).rounded()))
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY])
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(small, toBitmap: &pixels, rowBytes: width * 4,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: ColorPipeline.gradingSpace)
        return (pixels, width, height)
    }

    static func analyze(_ image: CIImage) -> ScopeData? {
        guard let (pixels, width, height) = downsample(image) else { return nil }
        return analyze(pixels: pixels, width: width, height: height)
    }

    /// Counts scopes from RGBA8 pixels in encoded Rec.709 (top row first).
    static func analyze(pixels: [UInt8], width: Int, height: Int) -> ScopeData {
        let levels = ScopeData.levels, vSize = ScopeData.vectorSize
        var histogram = [[UInt32]](repeating: [UInt32](repeating: 0, count: 256), count: 4)
        var waveform = [Float](repeating: 0, count: width * levels)
        var vectorscope = [Float](repeating: 0, count: vSize * vSize)
        let top = Float(levels - 1), edge = Float(vSize - 1)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Float(pixels[i]) / 255, g = Float(pixels[i + 1]) / 255, b = Float(pixels[i + 2]) / 255
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                histogram[0][Int(pixels[i])] += 1
                histogram[1][Int(pixels[i + 1])] += 1
                histogram[2][Int(pixels[i + 2])] += 1
                histogram[3][min(255, Int((luma * 255).rounded()))] += 1

                // Shared between the two nearest levels (no steps between levels).
                let level = min(max(luma * top, 0), top)
                let l0 = min(Int(level), levels - 2), f = level - Float(l0)
                waveform[l0 * width + x] += 1 - f
                waveform[(l0 + 1) * width + x] += f

                // Rec.709 chroma, -0.5...0.5, shared between the four nearest cells.
                let cb = (b - luma) / 1.8556, cr = (r - luma) / 1.5748
                let vx = min(max((cb + 0.5) * edge, 0), edge), vy = min(max((0.5 - cr) * edge, 0), edge)
                let x0 = min(Int(vx), vSize - 2), y0 = min(Int(vy), vSize - 2)
                let fx = vx - Float(x0), fy = vy - Float(y0)
                vectorscope[y0 * vSize + x0] += (1 - fx) * (1 - fy)
                vectorscope[y0 * vSize + x0 + 1] += fx * (1 - fy)
                vectorscope[(y0 + 1) * vSize + x0] += (1 - fx) * fy
                vectorscope[(y0 + 1) * vSize + x0 + 1] += fx * fy
            }
        }
        return ScopeData(histogram: histogram, waveform: waveform, waveformWidth: width, vectorscope: vectorscope,
                         waveformImage: image(of: waveform, width: width, height: levels, flipRows: true),
                         vectorscopeImage: image(of: vectorscope, width: vSize, height: vSize, flipRows: false))
    }

    /// Where a color lands on the vectorscope, in unit coordinates (0...1, y down).
    static func vectorPosition(r: Double, g: Double, b: Double) -> CGPoint {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - luma) / 1.8556, cr = (r - luma) / 1.5748
        return CGPoint(x: cb + 0.5, y: 0.5 - cr)
    }

    /// A trace as a grayscale image: softened a little (so scattered pixels read as a
    /// glow, not specks), then brighter where more pixels land. Brightness is relative
    /// to the busiest part of the trace (not the single busiest cell, which would dim
    /// everything else) and eases in, so rare values show faintly rather than as dots.
    static func image(of counts: [Float], width: Int, height: Int, flipRows: Bool) -> CGImage? {
        guard width > 0, height > 0, counts.count == width * height else { return nil }
        let soft = blur(counts, width: width, height: height)
        let lit = soft.filter { $0 > 1e-4 }.sorted()
        guard let busiest = lit.last, busiest > 0 else { return nil }
        let reference = max(lit[min(lit.count - 1, Int(Double(lit.count) * 0.98))], busiest * 0.02)
        var brightness = [Float](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = flipRows ? height - 1 - row : row
            for x in 0..<width {
                let d = soft[source * width + x] / reference
                guard d > 0.0005 else { continue }
                // Rises quickly, then levels off toward full: thin areas glow visibly,
                // busy ones are bright without washing everything else out.
                brightness[row * width + x] = 1 - exp(-3 * pow(d, 0.4))
            }
        }
        // Softened once more, so saturated spots fade out round instead of ending in an edge.
        let smooth = blur(brightness, width: width, height: height, kernel: [1, 2, 1])
        let bytes = smooth.map { UInt8(min(255, $0 * 255)) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A light separable blur (1-4-6-4-1 by default) that keeps the total.
    static func blur(_ values: [Float], width: Int, height: Int, kernel weights: [Float] = [1, 4, 6, 4, 1]) -> [Float] {
        let total = weights.reduce(0, +)
        let kernel = weights.map { $0 / total }
        let reach = kernel.count / 2
        var across = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for k in -reach...reach { sum += values[y * width + min(max(x + k, 0), width - 1)] * kernel[k + reach] }
                across[y * width + x] = sum
            }
        }
        var out = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for k in -reach...reach { sum += across[min(max(y + k, 0), height - 1) * width + x] * kernel[k + reach] }
                out[y * width + x] = sum
            }
        }
        return out
    }
}
