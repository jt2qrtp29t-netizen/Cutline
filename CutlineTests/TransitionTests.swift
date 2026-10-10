import AVFoundation
import Foundation
import Testing
@testable import Cutline

struct TransitionTests {
    let settings = ProjectSettings(name: "T", width: 1920, height: 1080, frameRate: 30)

    /// Ocean (blue) on 0–4 s, then Sunset (orange) on 4–8 s, on V1.
    private func cutProject(oceanSource: Double = 0, sunsetSource: Double = 2, oceanLength: Double = 4) async throws
        -> (ProjectState, ocean: Clip, sunset: Clip, urls: [UUID: URL]) {
        let oceanMedia = try await PlaybackTests.media("Ocean")
        let sunsetMedia = try await PlaybackTests.media("Sunset")
        var state = ProjectState(settings: settings, videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [oceanMedia, sunsetMedia]
        let ocean = Clip(id: UUID(), mediaID: oceanMedia.id, name: "Ocean", start: .zero,
                         duration: Time(seconds: oceanLength), sourceStart: Time(seconds: oceanSource))
        let sunset = Clip(id: UUID(), mediaID: sunsetMedia.id, name: "Sunset", start: Time(seconds: oceanLength),
                          duration: Time(seconds: 4), sourceStart: Time(seconds: sunsetSource))
        state.tracks[0].clips = [ocean, sunset]
        return (state, ocean, sunset, [oceanMedia.id: oceanMedia.fileURL, sunsetMedia.id: sunsetMedia.fileURL])
    }

    private func frames(_ state: ProjectState, urls: [UUID: URL], at seconds: [Double]) async throws -> [CGImage] {
        let output = try await CompositionBuilder.build(state, urls: urls)
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [CGImage] = []
        for s in seconds {
            images.append(try await generator.image(at: CMTime(seconds: s, preferredTimescale: 600)).image)
        }
        return images
    }

    private func color(_ image: CGImage, x: Int = 200, y: Int = 150) throws -> (r: Int, g: Int, b: Int) {
        let p = try TextRenderTests.pixel(image, x: x, y: y)
        return (p.r, p.g, p.b)
    }

    // MARK: Rendering

    @Test func crossDissolveBlendsAcrossTheCut() async throws {
        var (state, ocean, sunset, urls) = try await cutProject()
        state.addTransition(.crossDissolve, between: ocean.id, and: sunset.id)
        let images = try await frames(state, urls: urls, at: [3.0, 4.0, 5.0])
        let before = try color(images[0]), middle = try color(images[1]), after = try color(images[2])
        #expect(before.b > before.r, "before the transition it's all Ocean: \(before)")
        #expect(after.r > after.b, "after it's all Sunset: \(after)")
        // Halfway, both clips contribute (Core Image mixes in linear light).
        #expect(middle.r > before.r + 10 && middle.r < after.r - 10, "red is between the two: \(middle)")
        #expect(middle.b > after.b + 10 && middle.b < before.b - 10, "blue is between the two: \(middle) before \(before) after \(after)")
    }

    @Test func dipToBlackIsBlackAtTheCut() async throws {
        var (state, ocean, sunset, urls) = try await cutProject()
        state.addTransition(.dipToBlack, between: ocean.id, and: sunset.id)
        let images = try await frames(state, urls: urls, at: [4.0, 3.75])
        let cut = try color(images[0])
        #expect(cut.r < 12 && cut.g < 12 && cut.b < 12, "black at the cut: \(cut)")
        let fading = try color(images[1])
        #expect(fading.b > 12, "Ocean is dimming, not yet black, before the cut: \(fading)")
    }

    @Test func slidePushesTheOutgoingClipAway() async throws {
        var (state, ocean, sunset, urls) = try await cutProject()
        state.addTransition(.slideLeft, between: ocean.id, and: sunset.id)
        let image = try await frames(state, urls: urls, at: [4.0])[0]
        let left = try color(image, x: 480), right = try color(image, x: 1700)
        #expect(left.b > left.r, "Ocean is on its way out on the left: \(left)")
        #expect(right.r > right.b, "Sunset comes in from the right: \(right)")
    }

    @Test func clipsWithoutSpareMediaHoldTheirEdgeFrames() async throws {
        // Ocean uses its whole 12 s and Sunset starts at its first frame: no handles at all.
        var (state, ocean, sunset, urls) = try await cutProject(oceanSource: 0, sunsetSource: 0, oceanLength: 12)
        state.updateClip(ocean.id) { $0.duration = Time(seconds: 12) }
        state.addTransition(.crossDissolve, between: ocean.id, and: sunset.id)
        let images = try await frames(state, urls: urls, at: [11.75, 12.25, 15])
        let late = try color(images[0]), early = try color(images[1])
        // Three quarters of the way through it's further toward Sunset than a quarter in.
        #expect(early.r > late.r + 5 && early.b < late.b - 20, "moves from Ocean toward Sunset: \(late) → \(early)")
        let after = try color(images[2])
        #expect(after.r > after.b)
    }

    // MARK: Model

    @Test func transitionsOnlyGoOnTouchingClips() {
        var state = ProjectState()
        let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        let b = Clip(id: UUID(), mediaID: UUID(), name: "b", start: Time(seconds: 3), duration: Time(seconds: 2), sourceStart: .zero)
        state.tracks[0].clips = [a, b]
        #expect(state.addTransition(.crossDissolve, between: a.id, and: b.id) == nil, "there's a gap")
        state.updateClip(b.id) { $0.start = Time(seconds: 2) }
        #expect(state.addTransition(.crossDissolve, between: a.id, and: b.id) != nil)
        #expect(state.cut(onTrack: 0, near: Time(seconds: 2.1), tolerance: Time(seconds: 0.2))?.incoming.id == b.id)
        // Audio tracks don't take transitions.
        state.tracks[1].clips = [a, b].map { var c = $0; c.id = UUID(); return c }
        #expect(state.addTransition(.crossDissolve, between: state.tracks[1].clips[0].id,
                                    and: state.tracks[1].clips[1].id) == nil)
    }

    @Test func effectiveDurationIsLimitedByTheClips() {
        var state = ProjectState()
        let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero, duration: Time(seconds: 0.5), sourceStart: .zero)
        let b = Clip(id: UUID(), mediaID: UUID(), name: "b", start: Time(seconds: 0.5), duration: Time(seconds: 3), sourceStart: .zero)
        state.tracks[0].clips = [a, b]
        state.addTransition(.zoom, between: a.id, and: b.id, duration: Time(seconds: 2))
        let placed = state.tracks[0].placedTransitions()
        #expect(placed.count == 1 && placed[0].duration == Time(seconds: 0.5))
        #expect(placed[0].range == TimeRange(start: Time(seconds: 0.25), end: Time(seconds: 0.75)))
    }

    @Test func editsKeepOrDropTransitionsAndUndoRestoresThem() {
        var state = ProjectState()
        let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        let b = Clip(id: UUID(), mediaID: UUID(), name: "b", start: Time(seconds: 4), duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [a, b]
        state.addTransition(.crossDissolve, between: a.id, and: b.id)
        let store = ProjectStore(state: state)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        // Blading the outgoing clip moves the transition to its right-hand piece.
        undo.beginUndoGrouping()
        var created: [UUID] = []
        store.edit("Blade") { created = TimelineEditing.blade(at: Time(seconds: 2), clips: [a.id], in: &$0) }
        undo.endUndoGrouping()
        let t = store.state.tracks[0].transitions
        #expect(t.count == 1 && t[0].outgoingClipID == created.first && t[0].incomingClipID == b.id)

        // Moving the incoming clip away drops it; undo brings it back.
        undo.beginUndoGrouping()
        store.edit("Move") { TimelineEditing.move([b.id], by: Time(seconds: 1), in: &$0) }
        undo.endUndoGrouping()
        #expect(store.state.tracks[0].transitions.isEmpty)
        undo.undo()
        #expect(store.state.tracks[0].transitions.count == 1)

        // Deleting a clip drops its transitions too.
        undo.beginUndoGrouping()
        store.edit("Delete") { TimelineEditing.delete([b.id], in: &$0) }
        undo.endUndoGrouping()
        #expect(store.state.tracks[0].transitions.isEmpty)
    }

    @Test func transitionsRoundTrip() throws {
        var state = ProjectState()
        let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        let b = Clip(id: UUID(), mediaID: UUID(), name: "b", start: Time(seconds: 4), duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [a, b]
        state.addTransition(.slideUp, between: a.id, and: b.id, duration: Time(seconds: 0.75))
        let decoded = try ProjectState.decode(state.encoded())
        #expect(decoded == state)
        #expect(decoded.tracks[0].transitions.first?.kind == .slideUp)
    }

    @Test func editorAddsTransitionsAsOneUndoStep() {
        var state = ProjectState()
        let a = Clip(id: UUID(), mediaID: UUID(), name: "a", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        let b = Clip(id: UUID(), mediaID: UUID(), name: "b", start: Time(seconds: 4), duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [a, b]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo

        #expect(editor.transitionTarget(onTrack: 0, near: Time(seconds: 2), tolerance: Time(seconds: 0.5)) == nil)
        let target = editor.transitionTarget(onTrack: 0, near: Time(seconds: 4.2), tolerance: Time(seconds: 0.5))
        #expect(target?.outgoingID == a.id && target?.incomingID == b.id)

        undo.beginUndoGrouping()
        editor.addTransition(.dipToBlack, at: target!)
        undo.endUndoGrouping()
        let id = editor.state.tracks[0].transitions.first?.id
        #expect(id != nil && editor.selectedTransition == id)
        #expect(undo.undoActionName == "Add Dip to Black")

        // Applying at the playhead replaces the transition on that cut.
        editor.playback.seek(to: Time(seconds: 3.5))
        undo.beginUndoGrouping()
        editor.applyTransitionAtPlayhead(.zoom)
        undo.endUndoGrouping()
        #expect(editor.state.tracks[0].transitions.map(\.kind) == [.zoom])

        // Selecting a clip deselects the transition; deleting it removes only it.
        editor.selection = [a.id]
        #expect(editor.selectedTransition == nil)
        undo.beginUndoGrouping()
        editor.deleteTransition(editor.state.tracks[0].transitions[0].id)
        undo.endUndoGrouping()
        #expect(editor.state.tracks[0].transitions.isEmpty && editor.state.tracks[0].clips.count == 2)
        undo.undo()
        #expect(editor.state.tracks[0].transitions.map(\.kind) == [.zoom])
    }
}
