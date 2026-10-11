import CoreImage
import CoreVideo

/// Hands a running export's frames to the screen as they're encoded, like a render
/// viewer: a few times a second, scaled down off the export's thread, skipping frames
/// while the previous one is still being prepared, so the export barely slows down.
nonisolated final class ExportFrameTap: @unchecked Sendable {
    /// Shown frames per second.
    static let framesPerSecond = 12.0
    /// Longest side of a shown frame, in pixels.
    static let maximumSize = 1280.0

    private let lock = NSLock()
    private var lastOffer: UInt64 = 0
    private var busy = false
    private let queue = DispatchQueue(label: "app.cutline.export-preview", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false, .priorityRequestLow: true])
    private let deliver: @Sendable (CGImage, Int) -> Void
    private let outputSize: CGSize
    private let fills: Bool

    /// - Parameters:
    ///   - outputSize: the exported frame size; shown frames are framed like the file
    ///     (cropped to fill it, or letterboxed to fit it, as the encoder does).
    ///   - deliver: gets each shown frame and its index in the export (from any thread).
    init(outputSize: CGSize, fills: Bool, deliver: @escaping @Sendable (CGImage, Int) -> Void) {
        self.outputSize = outputSize
        self.fills = fills
        self.deliver = deliver
    }

    /// `source` scaled and placed as it appears in the file, at most `maximumSize` across.
    func framed(_ source: CIImage) -> CIImage {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0, outputSize.width > 0, outputSize.height > 0 else { return source }
        let shrink = min(1, Self.maximumSize / max(outputSize.width, outputSize.height))
        let target = CGRect(x: 0, y: 0, width: (outputSize.width * shrink).rounded(), height: (outputSize.height * shrink).rounded())
        let scaleX = target.width / extent.width, scaleY = target.height / extent.height
        let scale = fills ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let placed = source
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let offset = CGAffineTransform(translationX: (target.width - extent.width * scale) / 2,
                                       y: (target.height - extent.height * scale) / 2)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: target)
        return placed.transformed(by: offset).composited(over: black).cropped(to: target)
    }

    /// Offers the frame just encoded. Returns at once; most frames are skipped.
    func offer(_ pixels: CVReadOnlyPixelBuffer, index: Int, isLast: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        let due = isLast || now &- lastOffer >= UInt64(1_000_000_000 / Self.framesPerSecond)
        guard due, !busy || isLast else {
            lock.unlock()
            return
        }
        busy = true
        lastOffer = now
        lock.unlock()

        let frame = FrameBox(pixels: pixels)
        queue.async { [self] in
            let image = frame.pixels.withUnsafeBuffer { buffer -> CGImage? in
                let shown = framed(CIImage(cvPixelBuffer: buffer))
                return context.createCGImage(shown, from: shown.extent,
                                             format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
            }
            lock.withLock { busy = false }
            if let image { deliver(image, index) }
        }
    }

    private struct FrameBox: @unchecked Sendable {
        let pixels: CVReadOnlyPixelBuffer
    }
}
