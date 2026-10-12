import AVFoundation
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
