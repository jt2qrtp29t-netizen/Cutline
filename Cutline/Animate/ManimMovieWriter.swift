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

    /// One PNG drawn into a premultiplied BGRA buffer (transparent where the PNG is).
    static func pixelBuffer(_ file: URL, width: Int, height: Int) throws -> CVReadOnlyPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ManimEngine.Failure.failed("A rendered frame couldn't be read.")
        }
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
        guard let buffer = made else { throw ManimEngine.Failure.failed("Out of memory for the animation's frames.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let drawn: Bool
        if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            drawn = true
        } else {
            drawn = false
        }
        // Unlocked before it's handed on.
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drawn else { throw ManimEngine.Failure.failed("A rendered frame couldn't be drawn.") }
        return CVReadOnlyPixelBuffer(unsafeBuffer: buffer)
    }
}
