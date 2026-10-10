import CoreGraphics
import CoreImage
import Foundation

/// Histogram, waveform and vectorscope data for one frame.
nonisolated struct ScopeData: Sendable {
    /// 256 bins each for red, green, blue and luma.
    var histogram: [[UInt32]]
    /// Luma waveform: `waveformWidth` columns × `levels` rows (row 0 = black).
    var waveform: [UInt32]
    var waveformWidth: Int
    /// Vectorscope: `vectorSize` × `vectorSize`, Cb across, Cr up (row 0 = top).
    var vectorscope: [UInt32]

    static let levels = 128
    static let vectorSize = 128
}

/// Computes scopes from a frame. The frame is first shrunk on the GPU with Core Image
/// (to `analysisWidth` pixels across), so the counting is cheap even at 4K60.
nonisolated enum ScopeAnalyzer {
    static let analysisWidth = 256
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Downsamples `image` and reads it back as encoded Rec.709 RGBA8.
    static func downsample(_ image: CIImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite else { return nil }
        let scale = min(1, CGFloat(analysisWidth) / extent.width)
        let width = max(1, Int((extent.width * scale).rounded()))
        let height = max(1, Int((extent.height * scale).rounded()))
        let small = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
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
        var waveform = [UInt32](repeating: 0, count: width * levels)
        var vectorscope = [UInt32](repeating: 0, count: vSize * vSize)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                histogram[0][Int(pixels[i])] += 1
                histogram[1][Int(pixels[i + 1])] += 1
                histogram[2][Int(pixels[i + 2])] += 1
                histogram[3][min(255, Int((luma * 255).rounded()))] += 1

                let level = min(levels - 1, Int(luma * Double(levels - 1) + 0.5))
                waveform[level * width + x] += 1

                // Rec.709 chroma, -0.5...0.5.
                let cb = (b - luma) / 1.8556, cr = (r - luma) / 1.5748
                let vx = min(vSize - 1, max(0, Int((cb + 0.5) * Double(vSize - 1) + 0.5)))
                let vy = min(vSize - 1, max(0, Int((0.5 - cr) * Double(vSize - 1) + 0.5)))
                vectorscope[vy * vSize + vx] += 1
            }
        }
        return ScopeData(histogram: histogram, waveform: waveform, waveformWidth: width, vectorscope: vectorscope)
    }

    /// Where a color lands on the vectorscope, in unit coordinates (0...1, y down).
    static func vectorPosition(r: Double, g: Double, b: Double) -> CGPoint {
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let cb = (b - luma) / 1.8556, cr = (r - luma) / 1.5748
        return CGPoint(x: cb + 0.5, y: 0.5 - cr)
    }

    /// A count grid as a grayscale-alpha image: brighter where more pixels land
    /// (log scaled so a few pixels still show).
    static func image(of counts: [UInt32], width: Int, height: Int, flipRows: Bool) -> CGImage? {
        guard width > 0, height > 0, let maxCount = counts.max(), maxCount > 0 else { return nil }
        let scale = 1 / log(1 + Double(maxCount))
        var bytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            let source = flipRows ? height - 1 - row : row
            for x in 0..<width {
                let c = counts[source * width + x]
                guard c > 0 else { continue }
                let v = 0.25 + 0.75 * log(1 + Double(c)) * scale
                bytes[row * width + x] = UInt8(min(255, v * 255))
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
