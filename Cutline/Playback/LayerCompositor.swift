import AVFoundation
import CoreImage
import CoreVideo

/// Custom compositor that stacks every visible clip with Core Image, applying
/// each clip's transform, opacity and color adjustments.
nonisolated final class LayerCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let renderQueue = DispatchQueue(label: "app.cutline.compositor", qos: .userInteractive)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = LayerCompositor.pixelAttributes
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = LayerCompositor.pixelAttributes

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [self] in
            do {
                try render(request)
            } catch {
                request.finish(with: error)
            }
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) throws {
        let renderSize = request.renderContext.size
        let canvas = CGRect(origin: .zero, size: renderSize)
        // Video black behind everything; gaps in the timeline render as black frames.
        var output = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: canvas)

        // Source buffers must outlive the render because CIImage references them lazily.
        var sources: [CVReadOnlyPixelBuffer] = []
        if let instruction = request.videoCompositionInstruction as? CompositorInstruction {
            for layer in instruction.layers {
                let time = Time(request.compositionTime)
                if let text = layer.text {
                    guard let image = TextRenderer.image(for: text) else { continue }
                    output = Self.process(image, layer: layer, renderSize: renderSize, at: time)
                        .composited(over: output)
                    continue
                }
                guard let trackID = layer.trackID,
                      let buffer = request.sourceReadOnlyPixelBuffer(byTrackID: trackID) else { continue }
                sources.append(buffer)
                let image = buffer.withUnsafeBuffer { CIImage(cvPixelBuffer: $0) }
                output = Self.process(image, layer: layer, renderSize: renderSize, at: time).composited(over: output)
            }
        }

        let pixelBuffer = try request.renderContext.makeMutablePixelBuffer()
        pixelBuffer.withUnsafeBuffer { target in
            context.render(output.cropped(to: canvas), to: target, bounds: canvas, colorSpace: outputColorSpace)
        }
        request.finish(withComposedPixelBuffer: CVReadOnlyPixelBuffer(pixelBuffer))
        withExtendedLifetime(sources) {}
    }

    /// Orients, flips, crops, fits, positions, rotates and grades one layer in
    /// render (Core Image, y-up) space.
    static func process(_ source: CIImage, layer: CompositorLayer, renderSize: CGSize, at time: Time) -> CIImage {
        // Text is already upright and drawn at project-pixel size, so it isn't fitted.
        let isText = layer.text != nil
        var image = isText ? source : source.oriented(orientation(for: layer.sourceTransform))
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        let size = image.extent.size
        guard size.width > 0, size.height > 0 else { return CIImage.empty() }
        let clip = layer.clip
        let transform = clip.transform
        // Every animated value comes from the one evaluation function.
        let values = clip.parameters(at: time)

        // Flip around the frame center before cropping, so crop edges refer to what's on screen.
        if transform.flipHorizontal || transform.flipVertical {
            let flip = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .scaledBy(x: transform.flipHorizontal ? -1 : 1, y: transform.flipVertical ? -1 : 1)
                .translatedBy(x: -size.width / 2, y: -size.height / 2)
            image = image.transformed(by: flip)
        }

        // Crop away edges but keep fitting/positioning based on the full frame, so
        // cropping reveals the layers below instead of re-framing the image.
        let crop = clip.crop
        if !crop.isEmpty {
            let left = size.width * crop.left
            let right = size.width * crop.right
            let top = size.height * crop.top
            let bottom = size.height * crop.bottom
            // Core Image is y-up, so the bottom inset is the rect's origin.
            let rect = CGRect(x: left, y: bottom,
                              width: max(size.width - left - right, 1),
                              height: max(size.height - top - bottom, 1))
            image = image.cropped(to: rect)
        }

        let fit = isText ? 1 : min(renderSize.width / size.width, renderSize.height / size.height)
        let scale = fit * values.scale
        // Scale and rotate around the image's center, then place that center on the
        // canvas. Inspector +Y moves the image down; Core Image's y axis points up.
        let center = CGPoint(x: renderSize.width / 2 + values.positionX, y: renderSize.height / 2 - values.positionY)
        let placement = CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: -values.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
        image = image.transformed(by: placement)

        if values.yaw != 0 || values.pitch != 0 {
            image = rotated3D(image, yaw: values.yaw, pitch: values.pitch, renderSize: renderSize)
        }

        let color = clip.color
        if color.exposure != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: color.exposure])
        }
        if color.brightness != 0 || color.contrast != 1 || color.saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: color.brightness,
                kCIInputContrastKey: color.contrast,
                kCIInputSaturationKey: color.saturation,
            ])
        }
        if values.opacity < 1 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(values.opacity, 0))),
            ])
        }
        return image
    }

    /// Rotates the image's rectangle in 3D around its center (yaw about the vertical
    /// axis, then pitch about the horizontal axis) and projects it back with a
    /// perspective camera, as a corner-pin.
    static func rotated3D(_ image: CIImage, yaw: Double, pitch: Double, renderSize: CGSize) -> CIImage {
        let rect = image.extent
        guard rect.width > 0, rect.height > 0, rect.width.isFinite else { return image }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let focal = Double(max(renderSize.width, renderSize.height)) * 1.5
        let y = yaw.clamped(to: -89...89) * .pi / 180
        let p = pitch.clamped(to: -89...89) * .pi / 180

        func project(_ corner: CGPoint) -> CGPoint {
            let dx = Double(corner.x - center.x), dy = Double(corner.y - center.y)
            // Yaw (around y), then pitch (around x). z points away from the viewer.
            let x1 = dx * cos(y), z1 = dx * sin(y)
            let y2 = dy * cos(p) - z1 * sin(p), z2 = dy * sin(p) + z1 * cos(p)
            let s = focal / max(focal + z2, 1)
            return CGPoint(x: center.x + CGFloat(x1 * s), y: center.y + CGFloat(y2 * s))
        }

        return image.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: project(CGPoint(x: rect.minX, y: rect.maxY))),
            "inputTopRight": CIVector(cgPoint: project(CGPoint(x: rect.maxX, y: rect.maxY))),
            "inputBottomRight": CIVector(cgPoint: project(CGPoint(x: rect.maxX, y: rect.minY))),
            "inputBottomLeft": CIVector(cgPoint: project(CGPoint(x: rect.minX, y: rect.minY))),
        ])
    }

    /// Maps a track's preferred transform (a multiple of 90°, possibly mirrored)
    /// to the equivalent image orientation.
    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        case (-1, 0, 0, 1): .upMirrored
        case (1, 0, 0, -1): .downMirrored
        case (0, 1, 1, 0): .leftMirrored
        case (0, -1, -1, 0): .rightMirrored
        default: .up
        }
    }
}
