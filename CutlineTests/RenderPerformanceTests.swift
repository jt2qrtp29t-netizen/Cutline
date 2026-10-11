import AVFoundation
import CoreImage
import Testing
@testable import Cutline

@MainActor struct RenderPerformanceTests {
    /// A ProRes 4444 movie whose left half is transparent and right half opaque white.
    private func alphaMovie() async throws -> URL {
        let url = ExportProbe.folder().appendingPathComponent("alpha-\(UUID()).mov")
        let frame = try Self.halfTransparentFrame()
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<30 { try await receiver.append(frame, with: CMTime(value: Int64(i), timescale: 30)) }
        receiver.finish()
        await writer.finishWriting()
        return url
    }

    nonisolated private static func halfTransparentFrame() throws -> CVReadOnlyPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 320, y: 0, width: 320, height: 360))
        let clear = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 640, height: 360))
        CIContext().render(white.composited(over: clear), to: pixels)
        return CVReadOnlyPixelBuffer(unsafeBuffer: pixels)
    }

    /// Source frames now come as the decoder's own YUV, so the alpha in a ProRes 4444
    /// clip must still let the clip below show through.
    @Test func transparentClipsStillShowTheLayerBelow() async throws {
        let sunset = try await PlaybackTests.media("Sunset")
        let alphaURL = try await alphaMovie()
        let overlay = try await MediaImporter.makeItem(for: alphaURL)
        var state = ProjectState(settings: ProjectSettings(name: "A", width: 640, height: 360, frameRate: 30),
                                 videoTracks: 2, audioTracks: 0, textTracks: 0)
        state.media = [sunset, overlay]
        let below = Clip(id: UUID(), mediaID: sunset.id, name: "Sunset", start: .zero, duration: Time(seconds: 1), sourceStart: .zero)
        let above = Clip(id: UUID(), mediaID: overlay.id, name: "Alpha", start: .zero, duration: Time(seconds: 1), sourceStart: .zero)
        let videoTracks = state.trackIndices(of: .video)
        state.tracks[videoTracks[0]].clips = [below]
        let urls = [sunset.id: sunset.fileURL, overlay.id: alphaURL]
        let alone = try await ExportProbe.previewFrame(state, urls: urls, at: 0.5)
        state.tracks[videoTracks[1]].clips = [above]
        let stacked = try await ExportProbe.previewFrame(state, urls: urls, at: 0.5)

        // Left: the overlay is transparent, so the sunset shows exactly as without it.
        for y in [60, 180, 300] {
            let a = try TextRenderTests.pixel(alone, x: 100, y: y), b = try TextRenderTests.pixel(stacked, x: 100, y: y)
            #expect(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) <= 6, "\(a) vs \(b)")
        }
        // Right: opaque white covers it.
        let right = try TextRenderTests.pixel(stacked, x: 500, y: 180)
        #expect(right.r > 245 && right.g > 245 && right.b > 245, "\(right)")
    }
}
