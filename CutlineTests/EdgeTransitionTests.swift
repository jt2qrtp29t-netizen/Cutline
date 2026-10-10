import AVFoundation
import Foundation
import Testing
@testable import Cutline

struct EdgeTransitionTests {
    let settings = ProjectSettings(name: "T", width: 1920, height: 1080, frameRate: 30)

    private func clips() -> (ProjectState, Clip, Clip) {
        var state = ProjectState()
        let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: Time(seconds: 1), duration: Time(seconds: 4), sourceStart: .zero)
        let b = Clip(id: UUID(), mediaID: UUID(), name: "b", start: Time(seconds: 5), duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [a, b]
        return (state, a, b)
    }

    @Test func openEdgesTakeTransitionsButCutSidesDoNot() {
        var (state, a, b) = clips()
        #expect(state.addTransition(.crossDissolve, between: nil, and: a.id) != nil, "start of the first clip")
        #expect(state.addTransition(.dipToBlack, between: b.id, and: nil) != nil, "end of the last clip")
        #expect(state.addTransition(.zoom, between: a.id, and: nil) == nil, "a's end is a cut, not an open edge")
        #expect(state.addTransition(.zoom, between: nil, and: b.id) == nil)

        let placed = state.tracks[0].placedTransitions()
        #expect(placed.count == 2)
        #expect(placed[0].range == TimeRange(start: Time(seconds: 1), end: Time(seconds: 2.25)), "plays inside the clip")
        #expect(placed[1].range == TimeRange(start: Time(seconds: 7.75), end: Time(seconds: 9)))
        #expect(placed[0].description == "Start of a" && placed[1].description == "End of b")
        #expect(state.tracks[0].transitionHandles(for: a.id) == (.zero, .zero), "no extra media needed")
    }

    @Test func dropTargetsFindOpenEdges() {
        let (state, a, b) = clips()
        let tolerance = Time(seconds: 0.3)
        let start = state.cut(onTrack: 0, near: Time(seconds: 1.1), tolerance: tolerance)
        #expect(start?.outgoing == nil && start?.incoming?.id == a.id && start?.time == Time(seconds: 1))
        let end = state.cut(onTrack: 0, near: Time(seconds: 9.2), tolerance: tolerance)
        #expect(end?.outgoing?.id == b.id && end?.incoming == nil)
        let cut = state.cut(onTrack: 0, near: Time(seconds: 5), tolerance: tolerance)
        #expect(cut?.outgoing?.id == a.id && cut?.incoming?.id == b.id)
    }

    @Test func edgeTransitionsAreDroppedWhenSomethingTouchesTheEdge() {
        var (state, a, b) = clips()
        state.addTransition(.crossDissolve, between: b.id, and: nil)
        let c = Clip(id: UUID(), mediaID: UUID(), name: "c", start: Time(seconds: 9), duration: Time(seconds: 1), sourceStart: .zero)
        state.tracks[0].clips.append(c)
        state.pruneTransitions()
        #expect(state.tracks[0].transitions.isEmpty)
        _ = a
    }

    @Test func edgeTransitionsShareShortClips() {
        var state = ProjectState()
        let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero, duration: Time(seconds: 1), sourceStart: .zero)
        state.tracks[0].clips = [a]
        state.addTransition(.crossDissolve, between: nil, and: a.id, duration: Time(seconds: 1))
        state.addTransition(.crossDissolve, between: a.id, and: nil, duration: Time(seconds: 1))
        let ranges = state.tracks[0].placedTransitions().map(\.range)
        #expect(ranges.count == 2 && !ranges[0].overlaps(ranges[1]), "fade in and out each get half: \(ranges)")
    }

    // MARK: Rendering

    private func frame(_ state: ProjectState, urls: [UUID: URL], at seconds: Double) async throws -> (r: Int, g: Int, b: Int) {
        let output = try await CompositionBuilder.build(state, urls: urls)
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let p = try TextRenderTests.pixel(image, x: 200, y: 150)
        return (p.r, p.g, p.b)
    }

    @Test func fadeInFromBlackAtTheStartOfTheFirstClip() async throws {
        let media = try await PlaybackTests.media("Sunset")
        var state = ProjectState(settings: settings, videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [media]
        let clip = Clip(id: UUID(), mediaID: media.id, name: "Sunset", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        state.addTransition(.crossDissolve, between: nil, and: clip.id, duration: Time(seconds: 2))
        let urls = [media.id: media.fileURL]
        let start = try await frame(state, urls: urls, at: 0)
        let middle = try await frame(state, urls: urls, at: 1)
        let after = try await frame(state, urls: urls, at: 3)
        #expect(start.r < 15, "black at the start: \(start)")
        #expect(middle.r > start.r + 20 && middle.r < after.r - 20, "halfway up: \(middle) of \(after)")
    }

    @Test func slideOutAtTheEndOfTheLastClip() async throws {
        let media = try await PlaybackTests.media("Sunset")
        var state = ProjectState(settings: settings, videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [media]
        let clip = Clip(id: UUID(), mediaID: media.id, name: "Sunset", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        state.addTransition(.slideLeft, between: clip.id, and: nil, duration: Time(seconds: 2))
        // Three quarters through, the clip has mostly left to the left: the top-left is still clip,
        // the right side already black.
        let output = try await CompositionBuilder.build(state, urls: [media.id: media.fileURL])
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 3.5, preferredTimescale: 600)).image
        let left = try TextRenderTests.pixel(image, x: 100, y: 150), right = try TextRenderTests.pixel(image, x: 1700, y: 150)
        #expect(left.r > 60, "clip still on the left: \(left)")
        #expect(right.r < 15 && right.g < 15 && right.b < 15, "black where it has left: \(right)")
    }
}
