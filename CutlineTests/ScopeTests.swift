import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Cutline

struct ScopeTests {
    /// Pixels in encoded Rec.709 RGBA8, top row first.
    private func pixels(_ colors: [(UInt8, UInt8, UInt8)]) -> [UInt8] {
        colors.flatMap { [$0.0, $0.1, $0.2, 255] }
    }

    @Test func histogramCountsEachChannel() {
        let data = ScopeAnalyzer.analyze(pixels: pixels([(0, 128, 255), (0, 128, 255), (255, 0, 0)]), width: 3, height: 1)
        #expect(data.histogram[0][0] == 2 && data.histogram[0][255] == 1)
        #expect(data.histogram[1][128] == 2 && data.histogram[1][0] == 1)
        #expect(data.histogram[2][255] == 2)
        #expect(data.histogram.allSatisfy { $0.reduce(0, +) == 3 })
    }

    @Test func waveformPlacesBrightnessPerColumn() {
        // Left column black, right column white.
        let data = ScopeAnalyzer.analyze(pixels: pixels([(0, 0, 0), (255, 255, 255)]), width: 2, height: 1)
        #expect(data.waveform[0 * 2 + 0] == 1, "black at level 0 in column 0")
        #expect(data.waveform[(ScopeData.levels - 1) * 2 + 1] == 1, "white at the top level in column 1")
    }

    @Test func vectorscopePlacesHuesWhereTheWheelsDo() {
        // Grays sit in the center; red sits up and to the left, like on the wheels.
        let gray = ScopeAnalyzer.vectorPosition(r: 0.5, g: 0.5, b: 0.5)
        #expect(abs(gray.x - 0.5) < 1e-9 && abs(gray.y - 0.5) < 1e-9)
        let red = ScopeAnalyzer.vectorPosition(r: 0.75, g: 0, b: 0)
        #expect(red.x < 0.5 && red.y < 0.5)
        // The direction a wheel puck pushes is the direction the trace moves.
        let push = ColorWheel(x: 0.3, y: 0.5).chroma
        let moved = ScopeAnalyzer.vectorPosition(r: 0.5 + push.x, g: 0.5 + push.y, b: 0.5 + push.z)
        #expect(moved.x > 0.5 && moved.y < 0.5, "puck right and up → trace right and up")
        let data = ScopeAnalyzer.analyze(pixels: pixels([(191, 0, 0)]), width: 1, height: 1)
        let index = data.vectorscope.firstIndex { $0 > 0 }!
        let (row, column) = (index / ScopeData.vectorSize, index % ScopeData.vectorSize)
        #expect(column < ScopeData.vectorSize / 2 && row < ScopeData.vectorSize / 2)
    }

    @Test func framesAreDownsampledBeforeCounting() {
        let frame = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        let start = Date()
        let small = ScopeAnalyzer.downsample(frame)
        let data = ScopeAnalyzer.analyze(frame)
        let elapsed = Date().timeIntervalSince(start)
        #expect(small?.width == ScopeAnalyzer.analysisWidth && small?.height == 144)
        #expect(data.map { $0.histogram[3].reduce(0, +) } == UInt32(256 * 144))
        print("SCOPETIME 4K frame: \(elapsed * 1000) ms")
    }

    @Test func scopesSeeTheGrade() async throws {
        let media = try await PlaybackTests.media("Sunset")
        var state = ProjectState(settings: ProjectSettings(name: "T", width: 1920, height: 1080, frameRate: 30),
                                 videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [media]
        var clip = Clip(id: UUID(), mediaID: media.id, name: "Sunset", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        func frame(_ state: ProjectState) async throws -> CIImage {
            let output = try await CompositionBuilder.build(state, urls: [media.id: media.fileURL])
            let generator = AVAssetImageGenerator(asset: output.composition)
            generator.videoComposition = output.videoComposition
            return CIImage(cgImage: try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image)
        }
        let before = ScopeAnalyzer.analyze(try await frame(state))!
        clip.color.offset.master = -0.4
        state.tracks[0].clips = [clip]
        let after = ScopeAnalyzer.analyze(try await frame(state))!
        func meanLuma(_ d: ScopeData) -> Double {
            let bins = d.histogram[3]
            return Double(bins.enumerated().map { UInt64($0.offset) * UInt64($0.element) }.reduce(0, +)) / Double(bins.reduce(0, +))
        }
        #expect(meanLuma(after) < meanLuma(before) - 30, "a negative offset darkens the scopes too")
    }
}
