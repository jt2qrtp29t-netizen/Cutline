import AVFoundation
import Foundation
import SwiftUI
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

        // Undo walks back each step: the four Position steps, the second unlock, the lock.
        for _ in 0..<5 { undo.undo() }
        #expect(!editor.state.clip(clip.id)!.hasSpeedRamp, "back to locked")
        undo.undo()
        #expect(editor.animationEnds(of: .speed, in: editor.state.clip(clip.id)!).end == 2, "back to the ramp to 200%")
        #expect(abs(editor.state.clip(clip.id)!.duration.seconds - 4 / 1.5) < 1e-3)
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
        // A handful of long pieces the player can decode straight through, not one per frame.
        let pieces = built.composition.tracks(withMediaType: .video).map(\.segments.count).max() ?? 0
        #expect(pieces <= 24, "\(pieces) pieces for a 4 s ramp")
        // Playback and export draw whole frames: check frames spread across the ramp.
        for k in stride(from: 6, to: 118, by: 7) {
            let t = Double(k) / 30
            let rendered = try frameIndex(try await ExportProbe.previewFrame(state, urls: urls, at: t))
            // The source frame in effect at that moment (as at a constant speed), from
            // straight pieces within 1/8 of a frame of the exact curve.
            let exact = clip.sourceTime(at: Time(seconds: t)).seconds * 30
            let allowed = Set([Int((exact - 0.125).rounded(.down)), Int((exact + 0.125).rounded(.down))])
            #expect(allowed.contains(rendered), "at \(t) s: frame \(rendered), expected \(allowed.sorted())")
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

@MainActor struct SpeedEditingTests {
    @Test func trimmingARampStopsAtTheEndsOfTheMedia() throws {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "m", path: "/m.mov", duration: Time(seconds: 10), width: 1920, height: 1080,
                              frameRate: 30, hasAudio: false)
        state.media = [media]
        var clip = Clip(id: UUID(), mediaID: media.id, name: "c", start: Time(seconds: 5), duration: Time(seconds: 2), sourceStart: Time(seconds: 2))
        clip.animation.keyframes[.speed] = [Keyframe(time: .zero, value: 2), Keyframe(time: Time(seconds: 2), value: 1)]
        state.tracks[0].clips = [clip]
        // Leading: 2 s of media before the in-point at 200% is 1 s of timeline.
        let leading = TimelineEditing.trimBounds(for: clip, edge: .leading, in: state)
        #expect(abs(leading.lowerBound.seconds - 4) < 1e-6)
        // Trailing: the curve reaches the media's end (10 s) exactly at the bound.
        let trailing = TimelineEditing.trimBounds(for: clip, edge: .trailing, in: state)
        var extended = clip
        extended.duration = trailing.upperBound - clip.start
        #expect(abs(extended.sourceEnd.seconds - 10) < 1e-3, "\(extended.sourceEnd.seconds)")
    }

    /// Speed and softness edits in the Playground stay there.
    @Test func thePlaygroundHasItsOwnSpeedAndSoftness() async throws {
        var state = ProjectState()
        state.id = UUID()
        let media = MediaItem(id: UUID(), name: "m", path: "/m.mov", duration: Time(seconds: 30), width: 1920, height: 1080,
                              frameRate: 30, hasAudio: false)
        state.media = [media]
        let clip = Clip(id: UUID(), mediaID: media.id, name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.playgroundFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        editor.sendToPlayground([clip.id])
        let sandbox = try #require(editor.playground?.editor)
        let copy = try #require(sandbox.state.tracks.flatMap(\.clips).first)
        sandbox.setSpeedEnd(1, of: copy.id)
        sandbox.setSpeedEnd(2, of: copy.id)
        sandbox.adjustClip(copy.id, actionName: "Softness") { $0.cropSoftness = 0.4 }
        let edited = try #require(sandbox.state.clip(copy.id))
        #expect(edited.hasSpeedRamp && edited.cropSoftness == 0.4 && edited.duration < Time(seconds: 4))
        #expect(editor.state == state, "nothing reaches the project")
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

@MainActor struct KeyframeLaneLayoutTests {
    /// Columns (in the lane's coordinates) where two renders of the lane differ.
    private func render(_ editor: EditorController, layout: TimelineLayout, visible: CGRect, width: CGFloat) throws -> CGImage {
        let lane = KeyframeLane(editor: editor, layout: layout, visibleRect: visible)
            .frame(width: width, height: 30)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: lane)
        renderer.scale = 1
        return try #require(renderer.cgImage)
    }

    /// A long clip far into the project, scrolled so it fills the view: its diamonds sit
    /// exactly under their times (they used to vanish when a clip was wider than the view).
    @Test(arguments: [Workspace.edit, .effects])
    func keyframesOfLongClipsLineUpWithTheTimeline(workspace: Workspace) throws {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "m", path: "/m.mov", duration: Time(seconds: 600), width: 1920, height: 1080,
                              frameRate: 30, hasAudio: false)
        state.media = [media]
        let short = Clip(id: UUID(), mediaID: media.id, name: "short", start: .zero, duration: Time(seconds: 3), sourceStart: .zero)
        var long = Clip(id: UUID(), mediaID: media.id, name: "long", start: Time(seconds: 60), duration: Time(seconds: 120), sourceStart: .zero)
        let property: AnimatableProperty = workspace == .edit ? .cropSoftness : .opacity
        long.animation.keyframes[property] = [Keyframe(time: Time(seconds: 10), value: 0.2), Keyframe(time: Time(seconds: 30), value: 0.5)]
        state.tracks[0].clips = [short, long]

        func lane(second: Double) throws -> (CGImage, Int) {
            var s = state
            s.updateClip(long.id) { $0.animation.keyframes[property]![1].time = Time(seconds: second) }
            let editor = EditorController(store: ProjectStore(state: s))
            editor.workspace = workspace
            editor.selection = [long.id]
            let layout = TimelineLayout(pixelsPerSecond: 50, tracks: s.tracks)
            // The view starts 5 s into the long clip and is 800 points wide.
            let visible = CGRect(x: layout.x(for: Time(seconds: 65)), y: 0, width: 800, height: 100)
            let offset = Int(Theme.Metrics.trackHeaderWidth) + 1
            let image = try render(editor, layout: layout, visible: visible, width: CGFloat(offset) + 800)
            return (image, Int((layout.x(for: Time(seconds: 60 + second)) - visible.minX).rounded()) + offset)
        }
        // The second keyframe at 75 s, then at 79 s: only the pixels around those spots change.
        let (first, x1) = try lane(second: 15)
        let (second, x2) = try lane(second: 19)
        var changed: [Int] = []
        for x in 0..<first.width {
            for y in stride(from: 4, to: 26, by: 2) {
                let p = try TextRenderTests.pixel(first, x: x, y: y), q = try TextRenderTests.pixel(second, x: x, y: y)
                if abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b) > 30 { changed.append(x); break }
            }
        }
        #expect(!changed.isEmpty, "the diamonds are drawn")
        #expect(changed.allSatisfy { abs($0 - x1) <= 8 || abs($0 - x2) <= 8 }, "at \(x1) and \(x2): \(Set(changed).sorted())")
        #expect(changed.contains { abs($0 - x1) <= 2 } && changed.contains { abs($0 - x2) <= 2 })
    }
}

@MainActor struct LaneDeleteTests {
    @Test func deleteRemovesTheSelectedLaneKeyframeInAnyTab() {
        var state = ProjectState()
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "c", start: .zero, duration: Time(seconds: 4), sourceStart: .zero)
        let soft = Keyframe(time: Time(seconds: 1), value: 0.3), soft2 = Keyframe(time: Time(seconds: 3), value: 0.6)
        let fade = Keyframe(time: Time(seconds: 1), value: 0.5)
        clip.animation.keyframes[.cropSoftness] = [soft, soft2]
        clip.animation.keyframes[.opacity] = [fade]
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.selection = [clip.id]

        // Edit tab: a softness diamond is selected, Delete removes it (not the clip).
        editor.workspace = .edit
        editor.selectedKeyframes = [KeyframeRef(clipID: clip.id, property: .cropSoftness, keyframeID: soft.id)]
        editor.deleteSelection()
        #expect(editor.state.clip(clip.id)?.animation.keyframes(for: .cropSoftness).map(\.id) == [soft2.id])
        #expect(editor.selectedKeyframes.isEmpty)

        // A keyframe selected in another tab's lane (opacity, Effects) isn't on screen in
        // Edit, so Delete there deletes the clip as usual.
        editor.selectedKeyframes = [KeyframeRef(clipID: clip.id, property: .opacity, keyframeID: fade.id)]
        #expect(editor.visibleSelectedKeyframes.isEmpty)
        editor.workspace = .effects
        #expect(!editor.visibleSelectedKeyframes.isEmpty)
        editor.workspace = .edit
        editor.deleteSelection()
        #expect(editor.state.clip(clip.id) == nil)
    }
}
