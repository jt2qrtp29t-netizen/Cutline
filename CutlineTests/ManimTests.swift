import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Cutline

@Suite(.serialized) @MainActor struct ManimTests {
    static let script = """
    from manim import *
    import json, os

    class Title(Scene):
        def construct(self):
            text = Text("GOAL", weight=BOLD, font_size=120, color=YELLOW)
            self.play(FadeIn(text), run_time=0.5)
            self.wait(0.2)

    class FromParameters(Scene):
        def construct(self):
            values = json.load(open(os.environ["CUTLINE_PARAMETERS"]))
            self.play(Write(Text(values["text"], font_size=80)), run_time=0.4)

    class Slow(Scene):
        def construct(self):
            import time
            time.sleep(30)  # a long render (Manim itself is too quick to catch)
            self.play(Create(Square()), run_time=1)
    """

    @Test func scenesAreFoundInAScript() {
        #expect(ManimEngine.scenes(in: Self.script) == ["Title", "FromParameters", "Slow"])
        #expect(ManimEngine.scenes(in: "class Helper:\n    pass\nclass Intro(MovingCameraScene):\n    pass\nclass Graph(ThreeDScene, Mixin): pass") == ["Intro", "Graph"])
    }

    @Test func progressAndErrorsAreRead() {
        let p = ManimEngine.parseProgress("Animation 2: Write(Text('GOAL')):  45%|████▌     | 27/60 [00:01<00:01, 20.1it/s]")
        #expect(p?.animation == 2 && p?.fraction == 0.45)
        #expect(ManimEngine.parseProgress("INFO Rendered Title") == nil)
        let traceback = """
        ╭──────────────── Traceback (most recent call last) ────────────────╮
        │ /tmp/x/animation.py:7 in construct                                  │
        │ ❱  7 │         self.play(Writ(text))                                │
        ╰────────────────────────────────────────────────────────────────────╯
        NameError: name 'Writ' is not defined
        """
        #expect(ManimEngine.errorSummary(traceback) == "NameError: name 'Writ' is not defined (line 7)")
        // Previews are a quarter of the area, at most 30 fps.
        let preview = ManimEngine.Request(script: "", scene: "", width: 3840, height: 2160, frameRate: 60, quality: .preview).renderSize
        #expect(preview.width == 1920 && preview.height == 1080 && preview.fps == 30)
    }

    @Test func manimIsFoundOnThisMac() async throws {
        guard let installation = await ManimEngine.find() else { print("MANIM not installed: skipped"); return }
        #expect(installation.version.first?.isNumber == true, "\(installation.version)")
        #expect(FileManager.default.isExecutableFile(atPath: installation.executable.path))
    }

    @Test func rendersTransparentlyAndCaches() async throws {
        guard let installation = await ManimEngine.find() else { print("MANIM not installed: skipped"); return }
        let request = ManimEngine.Request(script: Self.script, scene: "Title", width: 320, height: 180, frameRate: 15)
        try? FileManager.default.removeItem(at: ManimEngine.cacheFolder.appendingPathComponent("\(ManimEngine.cacheKey(request, version: installation.version)).mov"))
        let clock = ContinuousClock(), start = clock.now
        let progress = ProgressLog()
        let movie = try await ManimEngine.render(request, installation: installation) { animation, fraction in progress.add(animation, fraction) }
        let first = clock.now - start
        let asset = AVURLAsset(url: movie)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 180))
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.7) < 0.2, "\(duration)")
        // Transparent: the corner is clear, the middle of the word isn't.
        let generator = AVAssetImageGenerator(asset: asset)
        let frame = try await generator.image(at: CMTime(seconds: 0.6, preferredTimescale: 600)).image
        #expect(frame.alphaInfo != .none && frame.alphaInfo != .noneSkipLast && frame.alphaInfo != .noneSkipFirst)
        let corner = try TextRenderTests.pixel(frame, x: 2, y: 2)
        #expect(corner.a == 0, "corner \(corner)")
        var opaque = 0
        for x in stride(from: 100, to: 220, by: 4) { if try TextRenderTests.pixel(frame, x: x, y: 90).a > 200 { opaque += 1 } }
        #expect(opaque > 3, "the word is drawn")
        #expect(progress.count > 0, "progress was reported")

        // The same request again: straight from the cache.
        let again = clock.now
        #expect(try await ManimEngine.render(request, installation: installation) == movie)
        #expect(clock.now - again < .milliseconds(200), "first render \(first)")
    }

    @Test func waitsLastAsLongAsWritten() async throws {
        guard let installation = await ManimEngine.find() else { print("MANIM not installed: skipped"); return }
        let script = "from manim import *\n\nclass Pause(Scene):\n    def construct(self):\n        self.play(FadeIn(Square()), run_time=0.5)\n        self.wait(2)\n        self.pause(1)\n"
        let movie = try await ManimEngine.render(.init(script: script, scene: "Pause", width: 320, height: 180, frameRate: 15), installation: installation)
        let duration = try await AVURLAsset(url: movie).load(.duration).seconds
        #expect(abs(duration - 3.5) < 0.15, "0.5 s fade + 2 s wait + 1 s pause: \(duration)")
    }

    @Test func templateValuesArriveAsData() async throws {
        guard let installation = await ManimEngine.find() else { print("MANIM not installed: skipped"); return }
        // Quotes and code-like text are just text.
        var request = ManimEngine.Request(script: Self.script, scene: "FromParameters", width: 320, height: 180, frameRate: 15)
        request.parameters = ["text": #"It's "2-1"); import os #"#]
        let movie = try await ManimEngine.render(request, installation: installation)
        #expect(FileManager.default.fileExists(atPath: movie.path))
        var other = request
        other.parameters = ["text": "Different"]
        #expect(ManimEngine.cacheKey(other, version: installation.version) != ManimEngine.cacheKey(request, version: installation.version))
    }

    @Test func errorsSayWhatAndWhere() async throws {
        guard let installation = await ManimEngine.find() else { print("MANIM not installed: skipped"); return }
        let broken = "from manim import *\n\nclass Broken(Scene):\n    def construct(self):\n        self.play(Writ(Text('x')))\n"
        do {
            _ = try await ManimEngine.render(.init(script: broken, scene: "Broken", width: 320, height: 180, frameRate: 15), installation: installation)
            Issue.record("should fail")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("NameError") && message.contains("Writ") && message.contains("line 5"), "\(message)")
        }
        await #expect(throws: ManimEngine.Failure.sceneNotFound("Missing")) {
            _ = try await ManimEngine.render(.init(script: broken, scene: "Missing", width: 320, height: 180, frameRate: 15), installation: installation)
        }
    }

    @Test func cancellingStopsManim() async throws {
        guard let installation = await ManimEngine.find() else { print("MANIM not installed: skipped"); return }
        let request = ManimEngine.Request(script: Self.script, scene: "Slow", width: 320, height: 180, frameRate: 15)
        let task = Task { try await ManimEngine.render(request, installation: installation) }
        try await Task.sleep(for: .seconds(3))
        let clock = ContinuousClock(), start = clock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(clock.now - start < .seconds(5), "stopped promptly")
    }
}

nonisolated final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Double)] = []
    func add(_ a: Int, _ f: Double) { lock.withLock { values.append((a, f)) } }
    var count: Int { lock.withLock { values.count } }
}

@MainActor struct TransparentClipTests {
    static let overlay = """
    from manim import *

    class Overlay(Scene):
        def construct(self):
            veil = Rectangle(width=config.frame_width / 2, height=config.frame_height, stroke_width=0)
            veil.set_fill(WHITE, opacity=0.5).to_edge(LEFT, buff=0)
            square = Square(side_length=2, stroke_width=0).set_fill(GREEN, opacity=1)
            self.add(veil, square)
            self.wait(1)
    """

    @Test func transparentClipsShowWhatsBelow() async throws {
        guard let installation = await ManimEngine.find() else { print("MANIM not installed: skipped"); return }
        let animation = try await ManimEngine.render(.init(script: Self.overlay, scene: "Overlay", width: 640, height: 360, frameRate: 30),
                                                     installation: installation)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
        let footage = try await ThumbnailFinderTests.movie([red], seconds: 2)
        let below = try await MediaImporter.makeItem(for: footage), above = try await MediaImporter.makeItem(for: animation)
        var state = ProjectState(settings: ProjectSettings(name: "A", width: 640, height: 360, frameRate: 30), videoTracks: 2, audioTracks: 0, textTracks: 0)
        state.media = [below, above]
        state.tracks[0].clips = [Clip(id: UUID(), mediaID: below.id, name: "red", start: .zero, duration: Time(seconds: 1), sourceStart: .zero)]
        state.tracks[1].clips = [Clip(id: UUID(), mediaID: above.id, name: "anim", start: .zero, duration: Time(seconds: 1), sourceStart: .zero)]
        let urls = [below.id: footage, above.id: animation]

        let built = try await CompositionBuilder.build(state, urls: urls)
        #expect(built.hasAlpha, "the animation's alpha is noticed")
        let frame = try await ExportProbe.previewFrame(state, urls: urls, at: 0.5)
        let clear = try TextRenderTests.pixel(frame, x: 600, y: 40)       // right edge: transparent → red
        let solid = try TextRenderTests.pixel(frame, x: 320, y: 180)      // center: the green square
        let veil = try TextRenderTests.pixel(frame, x: 40, y: 40)         // left: 50% white over red
        #expect(clear.r > 240 && clear.g < 15 && clear.b < 15, "transparent shows the clip below: \(clear)")

        // The yardstick: the same colors drawn by Cutline itself (a text block over the same
        // red): Manim's #83C167 and a 50% white must come out exactly like Cutline's.
        func block(_ color: RGBAColor) async throws -> (r: Int, g: Int, b: Int, a: Int) {
            var reference = state
            var text = Clip.text(at: .zero, duration: Time(seconds: 1))
            text.text?.string = "█"
            text.text?.size = 2_000
            text.text?.color = color
            reference.tracks[1].clips = []
            reference.tracks.append(Track(id: UUID(), name: "T1", kind: .text, clips: [text]))
            let image = try await ExportProbe.previewFrame(reference, urls: urls, at: 0.5)
            return try TextRenderTests.pixel(image, x: 320, y: 180)
        }
        let green = try await block(RGBAColor(red: 0x83 / 255.0, green: 0xC1 / 255.0, blue: 0x67 / 255.0, alpha: 1))
        let halfWhite = try await block(RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        print("ALPHA manim solid \(solid) veil \(veil) | cutline green \(green) half white \(halfWhite)")
        func close(_ a: (r: Int, g: Int, b: Int, a: Int), _ b: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
            abs(a.r - b.r) <= 4 && abs(a.g - b.g) <= 4 && abs(a.b - b.b) <= 4
        }
        #expect(close(solid, green), "Manim's colors match Cutline's: \(solid) vs \(green)")
        #expect(close(veil, halfWhite), "half-transparent blends like Cutline's own: \(veil) vs \(halfWhite)")

        // Exports draw it the same (ProRes, so no compression shifts the colors much).
        var settings = ExportPreset.proRes.applied(to: ExportSettings())
        settings.frameRate = 30
        let range = ExportSnapshot.snapped(TimeRange(start: .zero, end: Time(seconds: 1)), fps: 30)
        let exportURL = ExportProbe.folder().appendingPathComponent("alpha.mov")
        _ = try await ExportRunner.run(ExportSnapshot(state: state, urls: urls, range: range, settings: settings), to: exportURL,
                                       cancellation: ExportCancellation(), phase: { _ in }) { _, _ in }
        let exported = try await ExportProbe.frame(exportURL, at: 0.5)
        #expect(close(try TextRenderTests.pixel(exported, x: 40, y: 40), veil), "export matches the preview")
        #expect(close(try TextRenderTests.pixel(exported, x: 320, y: 180), solid))

        // Without transparent clips the faster compositor is kept.
        var plain = state
        plain.tracks[1].clips = []
        #expect(try await !CompositionBuilder.build(plain, urls: urls).hasAlpha)
    }
}
