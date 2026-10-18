import AVFoundation
import CoreImage
import ImageIO

/// Makes a movie from rendered frames (PNGs): ProRes 4444, which keeps transparency, or
/// ProRes 422 without it.
nonisolated enum ManimMovieWriter {
    static func write(frames: [URL], fps: Double, width: Int, height: Int, alpha: Bool, to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: alpha ? AVVideoCodecType.proRes4444 : AVVideoCodecType.proRes422,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            // Sequoia edition: Manim's sRGB colors are converted to HD video's (Rec. 709) as
            // the frames are made, so playback has nothing to convert. Intel Macs convert
            // sRGB movies a little lighter than Apple silicon does; this way both agree.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        // Frames come in as our own BGRA buffers (no pool needed).
        let receiver = writer.pixelReceiver(for: input)
        try writer.startOrThrow()
        writer.startSession(atSourceTime: .zero)
        // Frame times in a timescale that holds fractional rates (29.97…) exactly enough.
        let timescale: CMTimeScale = 60_000
        for (index, file) in frames.enumerated() {
            try Task.checkCancellation()
            let buffer = try pixelBuffer(file, width: width, height: height)
            let time = CMTime(value: CMTimeValue((Double(index) / fps * Double(timescale)).rounded()), timescale: timescale)
            while try !receiver.appendImmediately(buffer, with: time) {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        receiver.finish()
        await writer.finishWriting()
        if writer.status != .completed {
            throw ManimEngine.Failure.failed("The animation's frames couldn't be made into a movie (\(writer.error?.localizedDescription ?? "unknown")).")
        }
    }

    /// sRGB levels (0…255) to the HD video (Rec. 709) levels that come out as the same
    /// colors, matched through the compositor's own path: a frame tagged Rec. 709, read by
    /// Core Image and drawn into the output's color space.
    static let hdtvLevels: [UInt8] = {
        let identity = (0...255).map { UInt8($0) }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB), let hdtv = CGColorSpace(name: CGColorSpace.itur_709) else { return identity }
        let context = CIContext(options: [.cacheIntermediates: false])
        /// Each level drawn into the output color space, its input read as `colorSpace`
        /// (or as the frame's Rec. 709 tags when nil).
        func drawn(as colorSpace: CGColorSpace?) -> [Int]? {
            var input: CVPixelBuffer?, output: CVPixelBuffer?
            CVPixelBufferCreate(nil, 256, 1, kCVPixelFormatType_32BGRA, nil, &input)
            CVPixelBufferCreate(nil, 256, 1, kCVPixelFormatType_32BGRA, nil, &output)
            guard let input, let output else { return nil }
            CVPixelBufferLockBaseAddress(input, [])
            guard let source = CVPixelBufferGetBaseAddress(input)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            for v in 0..<256 { source[v * 4] = UInt8(v); source[v * 4 + 1] = UInt8(v); source[v * 4 + 2] = UInt8(v); source[v * 4 + 3] = 255 }
            CVPixelBufferUnlockBaseAddress(input, [])
            let image: CIImage
            if let colorSpace {
                image = CIImage(cvPixelBuffer: input, options: [.colorSpace: colorSpace])
            } else {
                CVBufferSetAttachment(input, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(input, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                image = CIImage(cvPixelBuffer: input)
            }
            context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: 256, height: 1), colorSpace: hdtv)
            CVPixelBufferLockBaseAddress(output, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
            guard let result = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else { return nil }
            return (0..<256).map { Int(result[$0 * 4 + 1]) }
        }
        guard let wanted = drawn(as: srgb), let tagged = drawn(as: nil) else { return identity }
        return wanted.map { target in
            UInt8(tagged.indices.min { abs(tagged[$0] - target) < abs(tagged[$1] - target) } ?? 0)
        }
    }()

    /// One frame as a BGRA buffer with straight (unpremultiplied) alpha, in Rec. 709 levels.
    ///
    /// Manim's transparent PNGs store premultiplied color (a 50% white is saved as gray 128
    /// at alpha 128), though PNG means straight color. Their bytes are read as they are and
    /// unpremultiplied (to white 255 at alpha 128); drawing them with Core Graphics would
    /// premultiply them a second time and darken every soft edge.
    static func pixelBuffer(_ file: URL, width: Int, height: Int) throws -> ReadOnlyPixels {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ManimEngine.Failure.failed("A rendered frame couldn't be read.")
        }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let buffer = made else { throw ManimEngine.Failure.failed("Out of memory for the animation's frames.") }
        let rgba = image.bitsPerComponent == 8 && image.bitsPerPixel == 32 && image.width == width && image.height == height
            && [.last, .premultipliedLast].contains(image.alphaInfo)
            && image.bitmapInfo.intersection(.byteOrderMask) != .byteOrder32Little
        let levels = hdtvLevels
        CVPixelBufferLockBaseAddress(buffer, [])
        var ok = false
        if rgba, let data = image.dataProvider?.data, let pixels = CFDataGetBytePtr(data),
           let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) {
            let sourceRow = image.bytesPerRow, targetRow = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                let from = pixels + y * sourceRow, to = base + y * targetRow
                for x in 0..<width {
                    let r = Int(from[x * 4]), g = Int(from[x * 4 + 1]), b = Int(from[x * 4 + 2]), a = Int(from[x * 4 + 3])
                    // Premultiplied → straight.
                    func straight(_ c: Int) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (c * 255 + a / 2) / a)) }
                    to[x * 4] = levels[Int(straight(b))]; to[x * 4 + 1] = levels[Int(straight(g))]
                    to[x * 4 + 2] = levels[Int(straight(r))]; to[x * 4 + 3] = UInt8(a)
                }
            }
            ok = true
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard ok else { throw ManimEngine.Failure.failed("A rendered frame wasn't in the expected format (8-bit RGBA).") }
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return ReadOnlyPixels(buffer: buffer)
    }
}
