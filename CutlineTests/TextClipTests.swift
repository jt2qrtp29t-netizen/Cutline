import AVFoundation
import Foundation
import Testing
@testable import Cutline

struct TextClipTests {
    @Test func textRendersAndMovesInTheComposition() async throws {
        var state = ProjectState(settings: .init(name: "T", width: 1920, height: 1080, frameRate: 30),
                                 videoTracks: 1, audioTracks: 0)
        var clip = Clip.text(at: .zero, duration: Time(seconds: 4))
        clip.text = TextRenderTests.style { $0.color = RGBAColor(red: 0, green: 1, blue: 0) }
        TimelineEditing.insert(clip, onTrack: 0, in: &state)

        func frame() async throws -> CGImage {
            let output = try await CompositionBuilder.build(state, urls: [:])
            #expect(abs(output.composition.duration.seconds - 4) < 0.05, "a text-only timeline plays")
            let generator = AVAssetImageGenerator(asset: output.composition)
            generator.videoComposition = output.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        }

        let centered = try await frame()
        #expect(try TextRenderTests.pixel(centered, x: 960, y: 540).g > 200, "drawn at the center")
        #expect(try TextRenderTests.pixel(centered, x: 1360, y: 540).g < 30)

        state.updateClip(clip.id) { $0.transform.positionX = 400 }
        let moved = try await frame()
        #expect(try TextRenderTests.pixel(moved, x: 1360, y: 540).g > 200, "X position moves the text")
        #expect(try TextRenderTests.pixel(moved, x: 960, y: 540).g < 30)
    }

    @Test func textTracksDrawAboveVideo() async throws {
        let ocean = try await PlaybackTests.media("Ocean")
        var state = ProjectState(settings: .init(name: "T", width: 1920, height: 1080, frameRate: 30))
        state.media = [ocean]
        TimelineEditing.place(ocean, at: .zero, onTrack: 0, in: &state)
        var clip = Clip.text(at: .zero, duration: Time(seconds: 4))
        clip.text = TextRenderTests.style { $0.color = RGBAColor(red: 0, green: 1, blue: 0) }
        TimelineEditing.insert(clip, onTrack: state.trackIndices(of: .text)[0], in: &state)

        let output = try await CompositionBuilder.build(state, urls: [ocean.id: ocean.fileURL])
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let center = try TextRenderTests.pixel(frame, x: 960, y: 540)
        #expect(center.g > 200 && center.r < 60, "text on T1 covers the video: \(center)")
        #expect(try TextRenderTests.pixel(frame, x: 100, y: 100).b > 60, "video shows elsewhere")
    }

    @Test @MainActor func fontListIncludesDownloadableFamilies() {
        let all = FontCatalog.allFamilies()
        let installed = all.filter(\.isInstalled)
        #expect(installed.count == FontCatalog.families().count)
        #expect(all.count > installed.count, "Apple's downloadable fonts are listed too")
        #expect(installed.contains { $0.name == "Helvetica" })
    }

    @Test func textClipsAreNotLimitedByMediaLength() {
        var state = ProjectState(videoTracks: 1, audioTracks: 0)
        let clip = Clip.text(at: .zero, duration: Time(seconds: 5))
        TimelineEditing.insert(clip, onTrack: 0, in: &state)
        TimelineEditing.setDuration(Time(seconds: 60), for: clip.id, in: &state)
        #expect(state.clip(clip.id)?.duration == Time(seconds: 60))
        TimelineEditing.setSpeed(2, for: clip.id, in: &state)
        #expect(state.clip(clip.id)?.speed == 1, "speed doesn't apply to text")
    }

    @Test func textStyleRoundTrips() throws {
        var state = ProjectState()
        var clip = Clip.text(at: .zero, duration: Time(seconds: 2))
        clip.text?.string = "Hello\nWorld"
        clip.text?.strokeEnabled = true
        clip.text?.strokePosition = .inside
        TimelineEditing.insert(clip, onTrack: 0, in: &state)
        #expect(try ProjectState.decode(state.encoded()) == state)
    }

    @Test func addTextGoesOnTextTracks() throws {
        var state = ProjectState(videoTracks: 1, audioTracks: 1)
        let media = MediaItem(id: UUID(), name: "m", path: "/m.mov", duration: Time(seconds: 10),
                              width: 1920, height: 1080, frameRate: 30, hasAudio: false)
        state.media = [media]
        TimelineEditing.place(media, at: .zero, onTrack: 0, in: &state)
        let editor = EditorController(store: ProjectStore(state: state))
        editor.addTextClip()

        let text = try #require(editor.state.allClips.first { $0.isText })
        #expect(editor.state.trackIndices(of: .video).count == 1, "no video track is added")
        #expect(editor.state.trackIndex(ofClip: text.id) == editor.state.trackIndices(of: .text)[0], "goes on T1")
        #expect(editor.selection == [text.id])
        #expect(editor.pendingTextFocus == text.id)

        // A second text at the same time goes on a new T2.
        editor.addTextClip()
        let texts = editor.state.trackIndices(of: .text)
        #expect(texts.count == 2 && editor.state.tracks[texts[1]].name == "T2")
        #expect(editor.state.tracks[texts[1]].clips.count == 1)
    }

    @Test func typingIsOneUndoStep() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        var state = ProjectState()
        let clip = Clip.text(at: .zero, duration: Time(seconds: 2))
        TimelineEditing.insert(clip, onTrack: 0, in: &state)
        let store = ProjectStore(state: state)
        store.undoManager = undo

        // The app's undo manager only opens a group when something is registered, so
        // only the first keystroke gets one; the coalesced ones register nothing.
        for (index, typed) in ["H", "He", "Hel", "Hell", "Hello"].enumerated() {
            if index == 0 { undo.beginUndoGrouping() }
            store.edit("Edit Text", coalescingKey: "text") { $0.updateClip(clip.id) { $0.text?.string = typed } }
            if index == 0 { undo.endUndoGrouping() }
        }
        #expect(store.state.clip(clip.id)?.text?.string == "Hello")
        let canUndo = undo.canUndo
        undo.undo()
        let after = store.state.clip(clip.id)?.text?.string ?? "nil"
        #expect(after == "Text", "one undo restores the original; got \(after), canUndo was \(canUndo)")
        undo.redo()
        #expect(store.state.clip(clip.id)?.text?.string == "Hello")
    }
}
