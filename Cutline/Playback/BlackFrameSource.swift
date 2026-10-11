import AVFoundation

/// A tiny one-frame black movie, generated once into the caches folder. It is
/// stretched over the whole timeline so the player's clock runs for audio that
/// extends past the last video clip (empty edits alone don't give a track length).
nonisolated enum BlackFrameSource {
    static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cutline/black-frame-v1.mov")
    }

    static func videoTrack() async throws -> (asset: AVURLAsset, track: AVAssetTrack)? {
        if !FileManager.default.fileExists(atPath: url.path) {
            try await write(to: url)
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        return (asset, track)
    }

    private static func write(to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16,
        ])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        var frame = try CVMutablePixelBuffer(CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_32BGRA),
            size: CVImageSize(width: 16, height: 16)
        ))
        frame.accessUnsafeMutableRawPlaneBytes { planes in
            for plane in planes { plane.bytes.initializeMemory(as: UInt8.self, repeating: 0) }
        }
        // Offered without waiting (the awaiting append can stay suspended forever).
        let pixels = CVReadOnlyPixelBuffer(frame)
        var attempts = 0
        while try !receiver.appendImmediately(pixels, with: .zero) {
            attempts += 1
            guard writer.status != .failed, attempts < 2_500 else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            try await Task.sleep(for: .milliseconds(2))
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }
}
