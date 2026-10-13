import AVFoundation
import CoreImage
import CoreVideo

/// Custom compositor that stacks every visible clip with Core Image, applying
/// each clip's transform, opacity and color adjustments.
nonisolated class LayerCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Frames render on a few serial lanes in turn, so several are drawn at once (much
    /// faster exports). Lanes are dedicated serial queues rather than one concurrent
    /// queue: a render waits for the GPU, and blocking the shared worker pool with many
    /// renders at once can starve the work they wait on.
    private let lanes = (0..<3).map { DispatchQueue(label: "app.cutline.compositor.\($0)", qos: .userInteractive) }
    private let laneLock = NSLock()
    private var nextLane = 0
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    private static let pixelAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    /// Source frames come as the decoder makes them (YUV, 10-bit when the file is), which
    /// Core Image reads directly on the GPU: no conversion pass per frame (about twice as
    /// fast in 4K) and 10-bit footage keeps its precision. RGB is the fallback.
    static let sourceFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_32BGRA,
    ]
    /// The formats this compositor asks the decoders for (subclasses change them).
    class var requestedSourceFormats: [OSType] { sourceFormats }

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: Self.requestedSourceFormats,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
    }
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = LayerCompositor.pixelAttributes

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        laneLock.lock()
        let lane = lanes[nextLane]
        nextLane = (nextLane + 1) % lanes.count
        laneLock.unlock()
        lane.async { [self] in
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
            let time = Time(request.compositionTime)
            for layer in instruction.layers {
                let own = image(of: layer, request: request, renderSize: renderSize, time: time, keeping: &sources)
                guard let blend = layer.transition else {
                    if let own { output = own.composited(over: output) }
                    continue
                }
                let other = blend.incomingLayer.flatMap {
                    image(of: $0, request: request, renderSize: renderSize, time: time, keeping: &sources)
                }
                // A missing side (open edge, or no frame yet) blends with nothing.
                let (from, to) = blend.layerIsIncoming ? (CIImage.empty(), own ?? .empty()) : (own ?? .empty(), other ?? .empty())
                let mixed = Self.blend(blend.kind, from: from, to: to, progress: blend.progress(at: time), canvas: canvas)
                output = mixed.composited(over: output)
            }
            for overlay in instruction.captions {
                if let caption = CaptionRenderer.image(for: overlay, at: time, renderSize: renderSize) {
                    output = caption.composited(over: output)
                }
            }
        }

        let pixelBuffer = try request.renderContext.makeMutablePixelBuffer()
        pixelBuffer.withUnsafeBuffer { target in
            context.render(output.cropped(to: canvas), to: target, bounds: canvas, colorSpace: outputColorSpace)
        }
        request.finish(withComposedPixelBuffer: CVReadOnlyPixelBuffer(pixelBuffer))
        withExtendedLifetime(sources) {}
    }

    /// The processed image of one layer's clip at `time`: drawn text, or the clip's
    /// source frame. Source buffers are kept in `sources` until the frame is rendered.
    private func image(of layer: CompositorLayer, request: AVAsynchronousVideoCompositionRequest,
                       renderSize: CGSize, time: Time, keeping sources: inout [CVReadOnlyPixelBuffer]) -> CIImage? {
        if let text = layer.text {
            guard let image = TextRenderer.image(for: text) else { return nil }
            return Self.process(image, layer: layer, renderSize: renderSize, at: time)
        }
        if let generator = layer.clip.generator {
            let canvas = CGRect(origin: .zero, size: renderSize)
            guard let image = LabRenderer.generate(generator, canvas: canvas, time: (time - layer.clip.start).seconds) else { return nil }
            return Self.process(image, layer: layer, renderSize: renderSize, at: time)
        }
        if layer.isOffline {
            return Self.process(Self.offlineSlate(named: layer.clip.name, size: renderSize), layer: layer,
                                renderSize: renderSize, at: time)
        }
        guard let trackID = layer.trackID,
              let buffer = request.sourceReadOnlyPixelBuffer(byTrackID: trackID) else { return nil }
        sources.append(buffer)
        var image = buffer.withUnsafeBuffer { Self.image(from: $0) }
        // Frame Blend: mix in the next source frame by how far toward it this moment is.
        if let retime = layer.retime, let next = request.sourceReadOnlyPixelBuffer(byTrackID: retime.nextFrameTrackID) {
            let fraction = retime.fraction(at: time)
            if fraction > 0.001 {
                sources.append(next)
                let nextImage = next.withUnsafeBuffer { Self.image(from: $0) }
                image = image.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: nextImage, kCIInputTimeKey: fraction,
                ]).cropped(to: image.extent)
            }
        }
        return Self.process(image, layer: layer, renderSize: renderSize, at: time)
    }

    /// Stands in for a clip whose media file is missing: a red frame naming the clip.
    static func offlineSlate(named name: String, size: CGSize) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        var slate = CIImage(color: Theme.offlineSlateFill).cropped(to: canvas)
        let fontSize = max(size.height / 18, 12)
        for (line, scale, offset) in [("Media Offline", 1.0, 0.6), (name, 0.55, -1.0)] {
            guard let text = CIFilter(name: "CITextImageGenerator", parameters: [
                "inputText": line, "inputFontName": "HelveticaNeue-Bold", "inputFontSize": fontSize * scale,
                "inputScaleFactor": 1.0, "inputPadding": 0,
            ])?.outputImage else { continue }
            // The generator draws black text: invert it to white, keeping its alpha.
            let white = text.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
            ]).applyingFilter("CIPremultiply")
            let e = white.extent
            let x = canvas.midX - e.width / 2 - e.minX
            let y = canvas.midY + CGFloat(offset) * fontSize - e.height / 2 - e.minY
            slate = white.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: slate)
        }
        return slate.cropped(to: canvas)
    }

    /// Mixes the outgoing and incoming images of a transition. `progress` runs 0 → 1.
    static func blend(_ kind: TransitionKind, from a: CIImage, to b: CIImage, progress p: Double, canvas: CGRect) -> CIImage {
        let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: canvas)
        func onCanvas(_ image: CIImage) -> CIImage { image.composited(over: clear).cropped(to: canvas) }
        func dissolve(_ x: CIImage, _ y: CIImage, _ t: Double) -> CIImage {
            CIFilter(name: "CIDissolveTransition", parameters: [
                kCIInputImageKey: onCanvas(x), kCIInputTargetImageKey: onCanvas(y), kCIInputTimeKey: t,
            ])?.outputImage?.cropped(to: canvas) ?? onCanvas(y)
        }
        func darken(_ image: CIImage, _ factor: Double) -> CIImage {
            let f = CGFloat(factor.clamped(to: 0...1))
            return image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0),
            ])
        }
        func scaled(_ image: CIImage, _ factor: Double) -> CIImage {
            let c = CGPoint(x: canvas.midX, y: canvas.midY)
            return image.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                .concatenating(CGAffineTransform(scaleX: factor, y: factor))
                .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
        }
        // Slides and zooms ease in and out; dissolves stay linear, like most editors.
        let eased = p * p * (3 - 2 * p)
        let w = canvas.width, h = canvas.height

        switch kind {
        case .crossDissolve:
            return dissolve(a, b, p)
        case .dipToBlack:
            // Dimming keeps alpha, so a lower track doesn't show through. On an open
            // edge the whole transition is a fade from or to black.
            if a.extent.isEmpty { return onCanvas(darken(b, p)) }
            if b.extent.isEmpty { return onCanvas(darken(a, 1 - p)) }
            return p < 0.5 ? onCanvas(darken(a, 1 - p * 2)) : onCanvas(darken(b, p * 2 - 1))
        case .slideLeft, .slideRight, .slideUp, .slideDown:
            // The incoming clip pushes the outgoing one off the opposite edge.
            let (dx, dy): (CGFloat, CGFloat) = switch kind {
            case .slideLeft: (-w, 0)
            case .slideRight: (w, 0)
            case .slideUp: (0, h)
            default: (0, -h)
            }
            let e = CGFloat(eased)
            let outgoing = a.transformed(by: CGAffineTransform(translationX: dx * e, y: dy * e))
            let incoming = b.transformed(by: CGAffineTransform(translationX: -dx * (1 - e), y: -dy * (1 - e)))
            return onCanvas(incoming.composited(over: outgoing))
        case .zoom:
            // Push into the outgoing clip while the incoming one settles from slightly smaller.
            return dissolve(scaled(a, 1 + 0.6 * eased), scaled(b, 0.85 + 0.15 * eased), eased)
        }
    }

    /// Fades an image's edges to transparent over `softness` × half its smaller side: each
    /// edge eases (an S-curve) from clear at the edge to opaque inside; corners multiply.
    static func feathered(_ image: CIImage, softness: Double) -> CIImage {
        let rect = image.extent
        let width = softness * min(rect.width, rect.height) / 2
        guard width > 0.01 else { return image }
        let opaque = CIColor(red: 1, green: 1, blue: 1, alpha: 1), clear = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        func ramp(from edge: CGPoint, to inside: CGPoint) -> CIImage {
            CIImage(color: clear).applyingFilter("CISmoothLinearGradient", parameters: [
                "inputPoint0": CIVector(cgPoint: edge), "inputPoint1": CIVector(cgPoint: inside),
                "inputColor0": clear, "inputColor1": opaque,
            ]).cropped(to: rect)
        }
        let ramps = [
            ramp(from: CGPoint(x: rect.minX, y: rect.midY), to: CGPoint(x: rect.minX + width, y: rect.midY)),
            ramp(from: CGPoint(x: rect.maxX, y: rect.midY), to: CGPoint(x: rect.maxX - width, y: rect.midY)),
            ramp(from: CGPoint(x: rect.midX, y: rect.minY), to: CGPoint(x: rect.midX, y: rect.minY + width)),
            ramp(from: CGPoint(x: rect.midX, y: rect.maxY), to: CGPoint(x: rect.midX, y: rect.maxY - width)),
        ]
        // Multiply the four ramps' alphas into one mask.
        var mask = ramps[0]
        for next in ramps.dropFirst() {
            mask = next.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: mask])
        }
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
        return image.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: transparent, kCIInputMaskImageKey: mask.cropped(to: rect),
        ]).cropped(to: rect)
    }

    /// Orients, flips, crops, fits, positions, rotates and grades one layer in
    /// render (Core Image, y-up) space.
    static func process(_ source: CIImage, layer: CompositorLayer, renderSize: CGSize, at time: Time) -> CIImage {
        // Text and generators are already upright and drawn at frame size, so they aren't fitted.
        let isText = layer.text != nil || layer.clip.generator != nil
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

        // Feather the visible edges (after the crop, before placement and opacity).
        let softness = clip.value(of: .cropSoftness, at: time).clamped(to: 0...1)
        if softness > 0 {
            image = feathered(image, softness: softness)
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

        let grade = clip.grade(at: time)
        if !grade.isNeutral {
            image = ColorPipeline.apply(grade, to: image, lut: LUTLibrary.shared.lut(for: grade.lut))
        }
        if !clip.labs.isEmpty {
            image = LabRenderer.apply(clip.labs, to: image, canvas: CGRect(origin: .zero, size: renderSize),
                                      time: (time - clip.start).seconds)
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

extension LayerCompositor {
    /// A source frame as Core Image works with it. (Frames tagged straight alpha, like the
    /// ProRes 4444 animations, are premultiplied by Core Image itself from that tag.)
    static func image(from buffer: CVPixelBuffer) -> CIImage {
        CIImage(cvPixelBuffer: buffer)
    }
}

/// The compositor for timelines with transparent clips (rendered animations): frames come
/// as RGBA so their alpha survives (YUV has none). A little slower, so it's only used
/// when a clip needs it.
nonisolated final class AlphaLayerCompositor: LayerCompositor, @unchecked Sendable {
    override class var requestedSourceFormats: [OSType] { [kCVPixelFormatType_32BGRA] }
}
