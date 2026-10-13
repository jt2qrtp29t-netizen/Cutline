import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Cutline

@Suite(.serialized) @MainActor struct TemplateTests {
    static func render(_ settings: AnimationSettings, installation: ManimEngine.Installation, width: Int = 640, height: Int = 360) async throws -> URL {
        let request = ManimEngine.Request(script: TemplateProgram.script, scene: TemplateProgram.scene, width: width, height: height,
                                          frameRate: 30, parameters: settings.parameters(family: "Helvetica Neue", weight: "BOLD"))
        return try await ManimEngine.render(request, installation: installation)
    }

    @Test func everyTemplateRenders() async throws {
        guard let installation = await ManimEngine.find() else { print("MANIM not installed: skipped"); return }
        var frames: [(String, CGImage)] = []
        for template in AnimationTemplate.allCases {
            let settings = template.defaults
            do {
                let movie = try await Self.render(settings, installation: installation)
                let asset = AVURLAsset(url: movie)
                let duration = try await asset.load(.duration).seconds
                #expect(abs(duration - settings.duration) < 0.4, "\(template.title): \(duration) s, expected \(settings.duration)")
                let generator = AVAssetImageGenerator(asset: asset)
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let middle = template == .countdown ? 0.6 : settings.inTime + settings.hold * 0.5
                frames.append((template.title, try await generator.image(at: CMTime(seconds: middle, preferredTimescale: 600)).image))
            } catch {
                Issue.record("\(template.title) failed: \(error.localizedDescription)")
            }
        }
        // Contact sheet over gray, to look at.
        let w = 640, h = 360, cols = 4, rows = (frames.count + cols - 1) / cols
        let ctx = try #require(CGContext(data: nil, width: w * cols, height: (h + 24) * rows, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.35, green: 0.38, blue: 0.42, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w * cols, height: (h + 24) * rows))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (k, (name, image)) in frames.enumerated() {
            let x = (k % cols) * w, y = (rows - 1 - k / cols) * (h + 24)
            ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1)); ctx.stroke(CGRect(x: x, y: y + 24, width: w, height: h))
            ctx.draw(image, in: CGRect(x: x, y: y + 24, width: w, height: h))
            (name as NSString).draw(at: CGPoint(x: x + 6, y: y + 4), withAttributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.current = nil
        try NSBitmapImageRep(cgImage: try #require(ctx.makeImage())).representation(using: .png, properties: [:])!
            .write(to: URL(fileURLWithPath: "/private/tmp/claude-501/-Volumes-MySSD-Cutline/3c710dc4-d9c2-4b62-a646-1cd7cb82cc25/scratchpad/templates.png"))
    }
}

@MainActor struct AnimateTabTests {
    @Test func animateSitsBetweenCaptionsAndPlayground() {
        #expect(Workspace.allCases.firstIndex(of: .animate) == 5, "⌘6")
        #expect(Workspace.allCases.firstIndex(of: .playground) == 6 && Workspace.allCases.firstIndex(of: .export) == 7)
    }

    @Test func typefacesBecomeManimFonts() {
        let bold = AnimateSession.pango("Helvetica-Bold")
        #expect(bold.family == "Helvetica" && bold.weight == "BOLD" && !bold.italic)
        #expect(AnimateSession.pango("Helvetica-Oblique").italic)
        #expect(AnimateSession.pango("HelveticaNeue-Light").weight == "LIGHT")
        #expect(AnimateSession.pango("HelveticaNeue").weight == "NORMAL")
    }

    @Test func animationsGoAboveTheFootageAtThePlayhead() throws {
        var state = ProjectState(videoTracks: 1, audioTracks: 1, textTracks: 0)
        let footage = MediaItem(id: UUID(), name: "match", path: "/match.mov", duration: Time(seconds: 60), width: 1920, height: 1080,
                                frameRate: 30, hasAudio: false)
        state.media = [footage]
        state.tracks[0].clips = [Clip(id: UUID(), mediaID: footage.id, name: "match", start: .zero, duration: Time(seconds: 60), sourceStart: .zero)]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        editor.playback.seek(to: Time(seconds: 10))
        let animation = MediaItem(id: UUID(), name: "Title: GOAL!", path: "/anim.mov", duration: Time(seconds: 3), width: 1920, height: 1080,
                                  frameRate: 30, hasAudio: false)
        let source = AnimationSource(settings: AnimationTemplate.title.defaults)
        undo.beginUndoGrouping(); editor.placeAnimation(animation, source: source); undo.endUndoGrouping()
        let videos = editor.state.trackIndices(of: .video)
        #expect(videos.count == 2, "a new track above the footage")
        let placed = try #require(editor.state.tracks[videos[1]].clips.first)
        #expect(placed.start == Time(seconds: 10) && placed.animationSource == source && editor.selection == [placed.id])
        #expect(try ProjectState.decode(editor.state.encoded()) == editor.state, "the clip keeps its settings")
        // Another one later on: the top track is free there, so no new track.
        editor.playback.seek(to: Time(seconds: 30))
        undo.beginUndoGrouping(); editor.placeAnimation(animation, source: source); undo.endUndoGrouping()
        #expect(editor.state.trackIndices(of: .video).count == 2 && editor.state.tracks[videos[1]].clips.count == 2)
        undo.undo(); undo.undo()
        #expect(editor.state == state, "each was one undo step")
    }

    @Test func designToTimeline() async throws {
        guard await ManimEngine.find() != nil else { print("MANIM not installed: skipped"); return }
        var project = ProjectState(settings: ProjectSettings(name: "A", width: 640, height: 360, frameRate: 30), videoTracks: 1, audioTracks: 0, textTracks: 0)
        project.id = UUID()
        let editor = EditorController(store: ProjectStore(state: project))
        let session = editor.animateSession
        // Waits for the first preview.
        let deadline = ContinuousClock.now + .seconds(60)
        while session.previewURL == nil, ContinuousClock.now < deadline {
            if case .failed(let message) = session.phase { Issue.record("\(message)"); return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let preview = try #require(session.previewURL)
        let previewSize = try await AVURLAsset(url: preview).loadTracks(withMediaType: .video).first!.load(.naturalSize)
        #expect(previewSize == CGSize(width: 320, height: 180), "previews are quarter size")
        session.settings.text = "2 – 1"
        session.addToTimeline(editor)
        let added = ContinuousClock.now + .seconds(60)
        while editor.state.allClips.isEmpty, ContinuousClock.now < added { try await Task.sleep(for: .milliseconds(100)) }
        let clip = try #require(editor.state.allClips.first)
        #expect(clip.animationSource?.settings?.text == "2 – 1")
        let media = try #require(editor.state.mediaItem(clip.mediaID))
        #expect(media.width == 640 && media.height == 360, "full size")
        #expect(abs(clip.duration.seconds - session.settings.duration) < 0.1)
    }
}
