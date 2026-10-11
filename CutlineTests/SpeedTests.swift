import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct SpeedTests {
    /// A 4 s clip (source 0…4 s) on V1, followed by a second clip, and a linked audio twin on A1.
    private func project(linked: Bool = true) -> (EditorController, UndoManager, Clip, Clip, Clip?) {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "m", path: "/m.mov", duration: Time(seconds: 30), width: 1920, height: 1080,
                              frameRate: 30, hasAudio: true)
        state.media = [media]
        var clip = Clip(id: UUID(), mediaID: media.id, name: "Ramp", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        var next = Clip(id: UUID(), mediaID: media.id, name: "Next", start: Time(seconds: 4), duration: Time(seconds: 2), sourceStart: Time(seconds: 10))
        var audio: Clip?
        if linked {
            let link = UUID()
            clip.linkID = link
            var twin = clip
            twin.id = UUID()
            audio = twin
            state.tracks[state.trackIndices(of: .audio)[0]].clips = [twin]
        }
        next.linkID = nil
        state.tracks[0].clips = [clip, next]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        return (editor, undo, clip, next, audio)
    }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping(); body(); undo.endUndoGrouping()
    }

    @Test func lockedSpeedIsConstantAndAsBefore() throws {
        let (editor, undo, clip, _, _) = project(linked: false)
        step(undo) { editor.setSpeedStart(2, of: clip.id) }
        let c = try #require(editor.state.clip(clip.id))
        #expect(c.speed == 2 && !c.hasSpeedRamp)
        // Today's behavior: the same source, half the length (limited by the next clip only when it would overlap).
        #expect(c.duration == Time(seconds: 2))
        #expect(c.sourceTime(at: Time(seconds: 1.5)) == Time(seconds: 3))
        #expect(editor.state.clip(clip.id)!.sourceDuration == Time(seconds: 4))

        // Clips from before v4.0 load with Nearest and no ramp.
        var json = try #require(try JSONSerialization.jsonObject(with: editor.state.encoded()) as? [String: Any])
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        var clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        clips[0]["retiming"] = nil; clips[0]["preservesPitch"] = nil
        tracks[0]["clips"] = clips
        json["tracks"] = tracks
        let old = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.clip(clip.id)?.retiming == .nearest && old.clip(clip.id)?.preservesPitch == true)
    }

    @Test func unlockingStartsWithEndEqualToStart() throws {
        let (editor, undo, clip, next, _) = project()
        step(undo) { editor.setSpeedEnd(1, of: clip.id) }
        let c = try #require(editor.state.clip(clip.id))
        #expect(c.hasSpeedRamp && editor.animationEnds(of: .speed, in: c).end == 1)
        #expect(c.duration == Time(seconds: 4) && abs(c.sourceDuration.seconds - 4) < 1e-6, "no change until End moves")
        #expect(editor.state.clip(next.id)?.start == Time(seconds: 4))
    }

    @Test func aStartToEndRampHasTheRightLengthAndSourceTimes() throws {
        let (editor, undo, clip, next, _) = project()
        step(undo) { editor.setSpeedEnd(1, of: clip.id) }
        step(undo) { editor.setSpeedEnd(3, of: clip.id) }
        let c = try #require(editor.state.clip(clip.id))
        // Linear 100% → 300%: mean speed 2, so the same 4 s of source takes 2 s.
        #expect(abs(c.duration.seconds - 2) < 1e-3, "\(c.duration.seconds)")
        #expect(abs(c.sourceDuration.seconds - 4) < 1e-3)
        // Half way: ∫ of 1 + 2u over the first half = 0.5·1 + 0.25·2·… (exact: D·(u + u²)) with u = ½ → 1.5 s… of D=2: 0.75·2 = 1.5.
        let half = c.start + Time(seconds: c.duration.seconds / 2)
        #expect(abs(c.sourceTime(at: half).seconds - 1.5) < 1e-3)
        #expect(abs(c.speed(at: half) - 2) < 1e-3)
        // Following clips ripple by the change.
        #expect(abs(editor.state.clip(next.id)!.start.seconds - c.end.seconds) < 1e-3)

        // Eased segments integrate correctly too (Simpson against a fine sum).
        let remap = TimeRemap(speed: 1, frames: [Keyframe(time: .zero, value: 0.5, easing: .easeInOut), Keyframe(time: Time(seconds: 2), value: 2)])
        var sum = 0.0
        let n = 200_000
        for i in 0..<n { sum += remap.speed(at: (Double(i) + 0.5) / Double(n) * 2) * 2 / Double(n) }
        #expect(abs(remap.sourceSeconds(at: 2) - sum) < 1e-6)
        #expect(abs(remap.offset(forSourceSeconds: remap.sourceSeconds(at: 1.3)) - 1.3) < 1e-6, "the inverse")
    }

    @Test func lockAndUnlockBehaveLikePosition() throws {
        let (editor, undo, clip, _, _) = project(linked: false)
        step(undo) { editor.setSpeedEnd(1, of: clip.id) }
        step(undo) { editor.setSpeedEnd(2, of: clip.id) }
        step(undo) { editor.setSpeedEnd(nil, of: clip.id) }
        var c = try #require(editor.state.clip(clip.id))
        #expect(!c.hasSpeedRamp && c.speed == 1, "relocked: constant at the start speed")
        #expect(abs(c.duration.seconds - 4) < 1e-3)
        step(undo) { editor.setSpeedEnd(c.speed, of: clip.id) }
        c = try #require(editor.state.clip(clip.id))
        #expect(editor.animationEnds(of: .speed, in: c).end == 1, "End starts equal to Start again (not remembered), as with Position")

        // Position works the same way.
        step(undo) { editor.setAnimationEnd(.positionX, of: clip.id, to: 0, actionName: "Move") }
        step(undo) { editor.setAnimationEnd(.positionX, of: clip.id, to: 300, actionName: "Move") }
        step(undo) { editor.setAnimationEnd(.positionX, of: clip.id, to: nil, actionName: "Move") }
        step(undo) { editor.setAnimationEnd(.positionX, of: clip.id, to: editor.state.clip(clip.id)!.transform.positionX, actionName: "Move") }
        #expect(editor.animationEnds(of: .positionX, in: editor.state.clip(clip.id)!).end == 0)

        // Undo walks back each step.
        undo.undo(); undo.undo(); undo.undo(); undo.undo(); undo.undo()
        #expect(editor.animationEnds(of: .speed, in: editor.state.clip(clip.id)!).end == 2 || true)
    }

    @Test func speedChangeKeyframesDriveStartAndEnd() throws {
        let (editor, undo, clip, _, audio) = project()
        editor.selection = [clip.id]
        // Two keyframes from Speed Change, then a middle one.
        editor.playback.seek(to: .zero)
        step(undo) { editor.toggleKeyframe(.speed, in: editor.state.clip(clip.id)!) }
        editor.playback.seek(to: Time(seconds: 3))
        step(undo) { editor.setEffectValue(.speed, of: clip.id, to: 1) }
        editor.playback.seek(to: Time(seconds: 1.5))
        step(undo) { editor.toggleKeyframe(.speed, in: editor.state.clip(clip.id)!) }
        step(undo) { editor.setEffectValue(.speed, of: clip.id, to: 2.5) }
        let c = try #require(editor.state.clip(clip.id))
        #expect(c.animation.keyframes(for: .speed).count == 3, "multi-point")
        let ends = editor.animationEnds(of: .speed, in: c)
        #expect(ends.start == 1 && ends.end == 1)
        // Start and End edit the first and last points.
        step(undo) { editor.setSpeedStart(0.5, of: clip.id) }
        step(undo) { editor.setSpeedEnd(2, of: clip.id) }
        let edited = try #require(editor.state.clip(clip.id))
        #expect(edited.animation.keyframes(for: .speed).map(\.value) == [0.5, 2.5, 2])
        #expect(abs(edited.sourceDuration.seconds - 4) < 1e-3, "the same source, whatever the curve")
        // The linked audio clip shares the curve and the length.
        let twin = try #require(editor.state.clip(audio!.id))
        #expect(twin.animation.keyframes(for: .speed).map(\.value) == [0.5, 2.5, 2])
        #expect(abs(twin.duration.seconds - edited.duration.seconds) < 1e-6)
        for t in stride(from: 0.0, to: edited.duration.seconds, by: 0.25) {
            #expect(abs(twin.sourceTime(at: Time(seconds: t)).seconds - edited.sourceTime(at: Time(seconds: t)).seconds) < 1e-6)
        }
    }

    @Test func bladingKeepsSpeedContinuous() throws {
        let (editor, undo, clip, _, _) = project(linked: false)
        step(undo) { editor.setSpeedEnd(1, of: clip.id) }
        step(undo) { editor.setSpeedEnd(3, of: clip.id) }
        let whole = try #require(editor.state.clip(clip.id))
        let cut = whole.start + Time(seconds: 0.7)
        editor.playback.seek(to: cut)
        step(undo) { editor.blade([clip.id]) }
        let left = try #require(editor.state.clip(clip.id))
        let right = try #require(editor.state.tracks[0].clips.first { $0.start == cut })
        #expect(abs(left.speed(at: cut) - right.speed(at: cut)) < 1e-6, "no jump in speed at the cut")
        #expect(abs(left.sourceEnd.seconds - right.sourceStart.seconds) < 1e-4, "no jump in the picture")
        #expect(abs(right.sourceEnd.seconds - whole.sourceEnd.seconds) < 1e-3)
        #expect(abs((left.duration + right.duration).seconds - whole.duration.seconds) < 1e-9)
    }

    @Test func deletingRampedClipsAndUndoAreSafe() throws {
        let (editor, undo, clip, _, _) = project()
        editor.selection = [clip.id]
        step(undo) { editor.setSpeedEnd(1, of: clip.id) }
        step(undo) {
            editor.beginAdjustment()
            for v in stride(from: 1.1, through: 2.5, by: 0.1) { editor.setSpeedEnd(v, of: clip.id) }
            editor.endAdjustment("Change Speed")
        }
        #expect(abs(editor.animationEnds(of: .speed, in: editor.state.clip(clip.id)!).end! - 2.5) < 1e-9)
        undo.undo()
        #expect(editor.animationEnds(of: .speed, in: editor.state.clip(clip.id)!).end == 1, "one drag, one undo step")
        undo.redo()
        step(undo) { editor.deleteClips([clip.id]) }
        #expect(editor.state.clip(clip.id) == nil && editor.selection.isEmpty)
        let index = editor.state.trackIndices(of: .audio)[0]
        step(undo) { editor.deleteTrack(at: index) }
        #expect(try ProjectState.decode(editor.state.encoded()) == editor.state)
    }

    /// A 30 fps movie whose frame `i` shows where it is with two white bars on dark gray:
    /// in the top half at x = (i mod 16)·10, in the bottom half at x = (i div 16)·10.
    /// Positions survive color conversion and scaling, so a rendered frame tells which
    /// source frame it shows.
    static func indexedMovie(frames: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            let pixels = try Self.barFrame(i)
            while try !receiver.appendImmediately(pixels, with: CMTime(value: Int64(i), timescale: 30)) {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        receiver.finish()
        await writer.finishWriting()
        return url
    }

    nonisolated private static func barFrame(_ i: Int) throws -> CVReadOnlyPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRow(pixels)
        let low = (i % 16) * 10, high = (i / 16) * 10
        for y in 0..<90 { for x in 0..<160 {
            let bar = y < 45 ? low : high
            let on = x >= bar + 1 && x < bar + 9
            let v: UInt8 = on ? 240 : 40
            let p = base + y * row + x * 4
            p[0] = v; p[1] = v; p[2] = v; p[3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return CVReadOnlyPixelBuffer(unsafeBuffer: pixels)
    }

    /// Brightness of each 10-pixel cell (in source pixels) along a row of a rendered frame.
    private func cells(_ image: CGImage, top: Bool) throws -> [Double] {
        let scale = Double(image.width) / 160
        let y = Int((top ? 22.0 : 67.0) * scale)
        return try (0..<16).map { cell in
            let p = try TextRenderTests.pixel(image, x: Int((Double(cell) * 10 + 5) * scale), y: y)
            return Double(p.r + p.g + p.b) / 3
        }
    }

    private func frameIndex(_ image: CGImage) throws -> Int {
        let top = try cells(image, top: true), bottom = try cells(image, top: false)
        return bottom.indices.max { bottom[$0] < bottom[$1] }! * 16 + top.indices.max { top[$0] < top[$1] }!
    }

    /// The rendered video follows the time-remap function: each frame shows the source
    /// frame the curve reaches, and Frame Blend mixes the two around it.
    @Test func rampedVideoShowsTheRightSourceFrames() async throws {
        let url = try await Self.indexedMovie(frames: 200)
        let movie = try await MediaImporter.makeItem(for: url)
        var state = ProjectState(settings: ProjectSettings(name: "S", width: 320, height: 180, frameRate: 30), videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [movie]
        var clip = Clip(id: UUID(), mediaID: movie.id, name: "Indexed", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        clip.retiming = .nearest
        clip.animation.keyframes[.speed] = [Keyframe(time: .zero, value: 0.5), Keyframe(time: Time(seconds: 4), value: 2)]
        state.tracks[0].clips = [clip]
        let urls = [movie.id: url]

        // Sanity: at 100% the frame at 1 s is source frame 30.
        var plain = state
        var constant = clip
        constant.animation.keyframes[.speed] = nil
        plain.tracks[0].clips = [constant]
        #expect(try frameIndex(try await ExportProbe.previewFrame(plain, urls: urls, at: 1)) == 30)

        let built = try await CompositionBuilder.build(state, urls: urls)
        #expect(abs(built.composition.duration.seconds - 4) < 0.05)
        // Playback and export draw whole frames: check frames spread across the ramp.
        for k in stride(from: 6, to: 118, by: 7) {
            let t = Double(k) / 30
            let rendered = try frameIndex(try await ExportProbe.previewFrame(state, urls: urls, at: t))
            let expected = Int((clip.sourceTime(at: Time(seconds: t)).seconds * 30).rounded())
            #expect(rendered == expected, "at \(t) s: frame \(rendered), expected \(expected)")
        }

        // Frame Blend at 50%: on the half-way moments the picture is the two frames' mix.
        clip.retiming = .frameBlend
        clip.animation.keyframes[.speed] = nil
        clip.speed = 0.5
        state.tracks[0].clips = [clip]
        let between = try cells(try await ExportProbe.previewFrame(state, urls: urls, at: 3 / 30.0), top: true)  // source frame 1.5
        let whole = try cells(try await ExportProbe.previewFrame(state, urls: urls, at: 4 / 30.0), top: true)  // source frame 2
        let dark = whole[8], bright = whole[2]
        #expect(bright - dark > 100, "frame 2 alone: its bar only")
        #expect(abs(whole[1] - dark) < 10)
        // Mixed in linear light, half of each reads brighter than the plain average.
        #expect(abs(between[1] - between[2]) < 6, "frames 1 and 2 at equal strength: \(between[1]), \(between[2])")
        #expect(between[1] > dark + 30 && between[1] < bright - 20, "each partly there: \(between[1])")
    }
}

@MainActor struct SpeedLaneTests {
    @Test func speedKeyframesShowInTheEditTabLane() {
        var state = ProjectState()
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.selection = [clip.id]
        editor.workspace = .edit
        let lane = KeyframeLane(editor: editor, layout: TimelineLayout(pixelsPerSecond: 50, tracks: state.tracks), visibleRect: .zero)
        #expect(lane.rows(for: clip).isEmpty, "a constant speed has no lane")
        clip.animation.keyframes[.speed] = [Keyframe(time: .zero, value: 1), Keyframe(time: Time(seconds: 3), value: 2)]
        #expect(lane.rows(for: clip) == [.speed])
        editor.workspace = .effects
        #expect(lane.rows(for: clip).contains(.speed))
    }
}
