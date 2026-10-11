import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Cutline

@MainActor struct ThumbnailFinderTests {
    static let photoA = URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")
    static let photoB = URL(fileURLWithPath: "/System/Library/CoreServices/StageManagerOnboarding.app/Contents/Resources/StageManager_LT.ca/assets/wallpaper.jpg")

    /// A 1280×720 30 fps movie of shots, `seconds` each: images drawn from `shots`.
    static func movie(_ shots: [CIImage], seconds: Double = 2) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1280, AVVideoHeightKey: 720,
        ])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        var frame = 0
        for shot in shots {
            let buffer = try Self.render(shot, context: context)
            for _ in 0..<Int(seconds * 30) {
                while try !receiver.appendImmediately(buffer, with: CMTime(value: Int64(frame), timescale: 30)) {
                    try await Task.sleep(for: .milliseconds(2))
                }
                frame += 1
            }
        }
        receiver.finish()
        await writer.finishWriting()
        return url
    }

    nonisolated static func render(_ image: CIImage, context: CIContext) throws -> CVReadOnlyPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        // Fill the frame (scaled to cover, centered).
        let scale = max(1280 / image.extent.width, 720 / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let placed = scaled.transformed(by: CGAffineTransform(translationX: (1280 - scaled.extent.width) / 2 - scaled.extent.minX,
                                                              y: (720 - scaled.extent.height) / 2 - scaled.extent.minY))
        context.render(placed.cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720)), to: pixels)
        return CVReadOnlyPixelBuffer(unsafeBuffer: pixels)
    }

    static func photo(_ url: URL) throws -> CIImage { try #require(CIImage(contentsOf: url)) }
    static func flat(_ gray: Double) -> CIImage {
        CIImage(color: CIColor(red: gray, green: gray, blue: gray)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    @Test func goodDistinctFramesComeFirst() async throws {
        let a = try Self.photo(Self.photoA), b = try Self.photo(Self.photoB)
        let blurred = a.clampedToExtent().applyingGaussianBlur(sigma: 40).cropped(to: a.extent)
        // Gray, photo A, gray, blurred A, photo B, gray.
        let url = try await Self.movie([Self.flat(0.5), a, Self.flat(0.3), blurred, b, Self.flat(0.6)])
        let candidates = try await ThumbnailFinder.candidates(in: url, samples: 36, keep: 6)
        func shot(_ c: ThumbnailCandidate) -> Int { Int(c.time / 2) }
        let shots = candidates.map(shot)
        print("THUMB", candidates.map { String(format: "shot %d t=%.1f score %.2f aesth %.2f utility %d", shot($0), $0.time, $0.score, $0.aesthetics, $0.isUtility ? 1 : 0) })
        // The two photos lead; flat frames and the blurred shot rank below them.
        #expect(Set(shots.prefix(2)) == [1, 4], "\(shots)")
        let photoScores = candidates.filter { [1, 4].contains(shot($0)) }.map(\.score)
        let otherScores = candidates.filter { ![1, 4].contains(shot($0)) }.map(\.score)
        #expect((photoScores.min() ?? 0) > (otherScores.max() ?? -1), "photos beat gray and blur")
        // No near-duplicates: one frame per shot at most.
        #expect(Set(shots).count == shots.count, "\(shots)")
        #expect(candidates.allSatisfy { $0.image.width == 1280 && $0.image.height == 720 })
    }

    @Test func loudAndExcitedMomentsCount() async throws {
        // 2 s quiet, then 2 s loud.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loud-\(UUID()).wav")
        do {
            // Closed (and its header finished) at the end of this scope, before reading.
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0,
                                                                    AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 192_000))
            buffer.frameLength = 192_000
            for i in 0..<192_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * (i < 96_000 ? 0.05 : 0.5)) }
            try file.write(from: buffer)
        }
        let curve = try await ThumbnailFinder.loudnessCurve(of: AVURLAsset(url: url), duration: 4)
        #expect(curve[1] < 0.2 && curve[5] > 0.95, "\(curve)")

        #expect(ThumbnailFinder.isExcited("NO WAY") && ThumbnailFinder.isExcited("let's go") && ThumbnailFinder.isExcited("yes!"))
        #expect(!ThumbnailFinder.isExcited("the") && !ThumbnailFinder.isExcited("okay"))
    }
}
