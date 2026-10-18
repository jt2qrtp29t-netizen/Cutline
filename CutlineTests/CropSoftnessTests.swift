import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Cutline

@MainActor struct CropSoftnessTests {
    /// A 160×90 movie of one flat light gray (2 s at 30 fps).
    static func flatMovie() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("flat-\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        let receiver = writer.pixelReceiver(for: input)
        try writer.startOrThrow()
        writer.startSession(atSourceTime: .zero)
        let frame = try Self.flatFrame()
        for i in 0..<60 {
            while try !receiver.appendImmediately(frame, with: CMTime(value: Int64(i), timescale: 30)) {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        receiver.finish()
        await writer.finishWriting()
        return url
    }

    nonisolated private static func flatFrame() throws -> ReadOnlyPixels {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(CVPixelBufferGetBytesPerRow(pixels) * 90) { base[i] = i % 4 == 3 ? 255 : 220 }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        return ReadOnlyPixels(buffer: pixels)
    }

    private func project() async throws -> (ProjectState, [UUID: URL], Clip) {
        let url = try await Self.flatMovie()
        let movie = try await MediaImporter.makeItem(for: url)
        var state = ProjectState(settings: ProjectSettings(name: "S", width: 320, height: 180, frameRate: 30), videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [movie]
        let clip = Clip(id: UUID(), mediaID: movie.id, name: "Flat", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        return (state, [movie.id: url], clip)
    }

    private func brightness(_ image: CGImage, x: Int, y: Int) throws -> Double {
        let p = try TextRenderTests.pixel(image, x: x, y: y)
        return Double(p.r + p.g + p.b) / 3
    }

    @Test func zeroSoftnessLeavesEveryPixelAsBefore() async throws {
        var (state, urls, clip) = try await project()
        state.updateClip(clip.id) { $0.crop = CropInsets(top: 0.1, bottom: 0.1, left: 0.2, right: 0.1) }
        // As saved before v4.0 (no softness field at all).
        var json = try #require(try JSONSerialization.jsonObject(with: state.encoded()) as? [String: Any])
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        var clips = try #require(tracks[0]["clips"] as? [[String: Any]])
        clips[0]["cropSoftness"] = nil
        tracks[0]["clips"] = clips
        json["tracks"] = tracks
        let old = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        #expect(old.clip(clip.id)?.cropSoftness == 0)
        #expect(LayerCompositor.feathered(CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10)), softness: 0).extent.width == 10)

        let a = try await ExportProbe.previewFrame(state, urls: urls, at: 0.5)
        let b = try await ExportProbe.previewFrame(old, urls: urls, at: 0.5)
        var worst = 0
        for y in stride(from: 0, to: a.height, by: 3) {
            for x in stride(from: 0, to: a.width, by: 3) {
                let p = try TextRenderTests.pixel(a, x: x, y: y), q = try TextRenderTests.pixel(b, x: x, y: y)
                worst = max(worst, abs(p.r - q.r), abs(p.g - q.g), abs(p.b - q.b))
            }
        }
        #expect(worst == 0)
    }

    @Test func edgesFadeOutOverTheSoftWidth() async throws {
        var (state, urls, clip) = try await project()
        // No crop: the whole frame (320×180 on screen) feathers over 50% of 90 px = 45 px.
        state.updateClip(clip.id) { $0.cropSoftness = 0.5 }
        let image = try await ExportProbe.previewFrame(state, urls: urls, at: 0.5)
        let y = 90
        let full = try brightness(image, x: 160, y: y)
        #expect(full > 180, "the middle is untouched: \(full)")
        let profile = try [1, 10, 22, 34, 44, 60].map { try brightness(image, x: $0, y: y) }
        #expect(profile[0] < 25, "clear at the edge: \(profile)")
        for (a, b) in zip(profile, profile.dropFirst()) { #expect(a <= b + 1, "rising inward: \(profile)") }
        #expect(profile[2] > 40 && profile[2] < full - 20, "partly there half way in: \(profile)")
        #expect(abs(profile[5] - full) < 3, "opaque past the soft width: \(profile)")
        // The same on the right edge, and vertically.
        #expect(abs(try brightness(image, x: 318, y: y) - profile[0]) < 12)
        #expect(try brightness(image, x: 160, y: 1) < 25)

        // With a crop, the feather starts at the crop edge (left crop 25% = 80 px on screen).
        state.updateClip(clip.id) { $0.crop = CropInsets(left: 0.25) }
        let cropped = try await ExportProbe.previewFrame(state, urls: urls, at: 0.5)
        #expect(try brightness(cropped, x: 70, y: y) < 5, "cropped away")
        #expect(try brightness(cropped, x: 82, y: y) < full * 0.2, "nearly clear just inside the crop edge")
        #expect(try brightness(cropped, x: 102, y: y) < full * 0.85, "still fading 22 px in")
        #expect(abs(try brightness(cropped, x: 128, y: y) - full) < 3, "opaque past the soft width")
    }

    @Test func softnessIsKeyframedUndoableAndSaved() async throws {
        var (state, urls, clip) = try await project()
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        editor.selection = [clip.id]
        editor.playback.seek(to: .zero)
        undo.beginUndoGrouping(); editor.toggleKeyframe(.cropSoftness, in: editor.state.clip(clip.id)!); undo.endUndoGrouping()
        editor.playback.seek(to: Time(seconds: 1.5))
        undo.beginUndoGrouping()
        editor.beginAdjustment()
        for v in stride(from: 0.1, through: 0.8, by: 0.1) { editor.setEffectValue(.cropSoftness, of: clip.id, to: v) }
        editor.endAdjustment("Change Softness")
        undo.endUndoGrouping()
        let c = try #require(editor.state.clip(clip.id))
        #expect(c.animation.keyframes(for: .cropSoftness).map(\.value) == [0, 0.8])
        #expect(abs(c.value(of: .cropSoftness, at: Time(seconds: 0.75)) - 0.4) < 1e-9)
        #expect(!AnimatableProperty.grade.contains(.cropSoftness) && AnimatableProperty.cropSoftness.isEditAdjustment)

        // Rendered over time: sharp edge at the start, soft at 1.5 s.
        state = editor.state
        let early = try await ExportProbe.previewFrame(state, urls: urls, at: 0)
        let late = try await ExportProbe.previewFrame(state, urls: urls, at: 1.5)
        #expect(try brightness(early, x: 2, y: 90) > 180)
        #expect(try brightness(late, x: 2, y: 90) < 40)

        // Saved and loaded unchanged; one drag is one undo step.
        #expect(try ProjectState.decode(editor.state.encoded()) == editor.state)
        undo.undo()
        #expect(editor.state.clip(clip.id)?.animation.keyframes(for: .cropSoftness).count == 1)
        undo.undo()
        #expect(editor.state.clip(clip.id)?.isAnimated(.cropSoftness) == false)

        // Reset Crop clears softness and its keyframes.
        undo.redo(); undo.redo()
        undo.beginUndoGrouping()
        editor.adjustClip(clip.id, actionName: "Reset Crop") {
            $0.crop = .none; $0.cropSoftness = 0; $0.animation.keyframes[.cropSoftness] = nil
        }
        undo.endUndoGrouping()
        #expect(editor.state.clip(clip.id)?.isAnimated(.cropSoftness) == false)
    }
}
