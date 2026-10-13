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
            // Manim's colors are sRGB: say so, or players guess (an old TV standard).
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        // Frames come in as our own BGRA buffers (no pool needed).
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
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

    /// One frame as a BGRA buffer with straight (unpremultiplied) alpha, tagged sRGB.
    ///
    /// Manim's transparent PNGs store premultiplied color (a 50% white is saved as gray 128
    /// at alpha 128), though PNG means straight color. Their bytes are read as they are and
    /// unpremultiplied (to white 255 at alpha 128); drawing them with Core Graphics would
    /// premultiply them a second time and darken every soft edge.
    static func pixelBuffer(_ file: URL, width: Int, height: Int) throws -> CVReadOnlyPixelBuffer {
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
                    to[x * 4] = straight(b); to[x * 4 + 1] = straight(g); to[x * 4 + 2] = straight(r); to[x * 4 + 3] = UInt8(a)
                }
            }
            ok = true
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard ok else { throw ManimEngine.Failure.failed("A rendered frame wasn't in the expected format (8-bit RGBA).") }
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_StraightAlpha, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
    }
}
