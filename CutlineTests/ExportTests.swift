import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import Cutline

/// Reading exported files back.
enum ExportProbe {
    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The file's top-level boxes in order ("ftyp", "moov", "mdat"…).
    static func topLevelBoxes(_ url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        var offset = 0
        var names: [String] = []
        while offset + 8 <= data.count {
            var size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            names.append(String(decoding: data[offset + 4..<offset + 8], as: UTF8.self))
            if size == 1 { size = data[offset + 8..<offset + 16].reduce(0) { $0 << 8 | Int($1) } }
            if size == 0 { break }
            offset += size
        }
        return names
    }

    static func frameCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: nil))
        try reader.start()
        var count = 0
        while let sample = try await provider.next() {
            count += sample.withUnsafeSampleBuffer { CMSampleBufferGetNumSamples($0) }
        }
        return count
    }

    /// RMS of the decoded audio track (0 if there is none).
    static func audioLevel(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let reader = try AVAssetReader(asset: asset)
        let provider = reader.outputProvider(for: AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
        ]))
        try reader.start()
        var sum = 0.0, count = 0
        while let sample = try await provider.next() {
            let values: [Float] = sample.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
                let length = CMBlockBufferGetDataLength(block)
                var floats = [Float](repeating: 0, count: length / 4)
                _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
                return floats
            }
            for v in values { sum += Double(v * v) }
            count += values.count
        }
        return count > 0 ? (sum / Double(count)).squareRoot() : 0
    }

    static func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    static func previewFrame(_ state: ProjectState, urls: [UUID: URL], at seconds: Double) async throws -> CGImage {
        let output = try await CompositionBuilder.build(state, urls: urls)
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// Mean difference per channel (0...255) over a grid of points.
    static func difference(_ a: CGImage, _ b: CGImage) throws -> Double {
        var total = 0.0, n = 0
        for gx in 1...8 {
            for gy in 1...6 {
                let x = a.width * gx / 9, y = a.height * gy / 7
                let p = try TextRenderTests.pixel(a, x: x, y: y)
                let q = try TextRenderTests.pixel(b, x: b.width * gx / 9, y: b.height * gy / 7)
                total += Double(abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)) / 3
                n += 1
            }
        }
        return total / Double(n)
    }
}

@MainActor struct ExportTests {
    let settings30 = ProjectSettings(name: "Export", width: 640, height: 360, frameRate: 30)

    private func sunsetProject(seconds: Double = 2) async throws -> (ProjectState, [UUID: URL], Clip) {
        let media = try await PlaybackTests.media("Sunset")
        var state = ProjectState(settings: settings30, videoTracks: 1, audioTracks: 1, textTracks: 0)
        state.media = [media]
        let clip = Clip(id: UUID(), mediaID: media.id, name: "Sunset", start: .zero, duration: Time(seconds: seconds), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        return (state, [media.id: media.fileURL], clip)
    }

    private func snapshot(_ state: ProjectState, urls: [UUID: URL], settings: ExportSettings = ExportSettings(),
                          range: TimeRange? = nil) -> ExportSnapshot {
        let fps = settings.frameRate(for: state.settings)
        let r = ExportSnapshot.snapped(range ?? TimeRange(start: .zero, end: state.duration), fps: fps)
        return ExportSnapshot(state: state, urls: urls, range: r, settings: settings)
    }

    private func export(_ snapshot: ExportSnapshot, name: String = "out") async throws -> ExportResult {
        let url = ExportProbe.folder().appendingPathComponent("\(name).\(snapshot.settings.effectiveContainer.fileExtension)")
        return try await ExportRunner.run(snapshot, to: url, cancellation: ExportCancellation()) { _, _ in }
    }

    @Test func frameCountAndDurationMatchTheTimeline() async throws {
        let (state, urls, _) = try await sunsetProject(seconds: 2)
        var settings = ExportPreset.quickPreview.applied(to: ExportSettings())
        settings.frameRate = 30
        let result = try await export(snapshot(state, urls: urls, settings: settings))
        #expect(try await ExportProbe.frameCount(result.url) == 60)
        let duration = try await AVURLAsset(url: result.url).load(.duration)
        #expect(abs(duration.seconds - 2) < 0.001, "\(duration.seconds)")
        #expect(result.frames == 60 && result.warnings.isEmpty)

        // A different output rate renders every output frame (no drops or doubles).
        settings.frameRate = 24
        let at24 = try await export(snapshot(state, urls: urls, settings: settings), name: "24")
        #expect(try await ExportProbe.frameCount(at24.url) == 48)
        // An in/out range is exactly as long as asked, starting on a frame.
        let ranged = try await export(snapshot(state, urls: urls, settings: settings,
                                               range: TimeRange(start: Time(seconds: 0.5), end: Time(seconds: 1.25))), name: "range")
        #expect(try await ExportProbe.frameCount(ranged.url) == 18)
        let size = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video).first!.load(.naturalSize)
        #expect(size == CGSize(width: 960, height: 540), "Quick Preview size")
    }

    @Test func theAudioMixIsInTheFile() async throws {
        // A tone on A1 under a video clip.
        let toneURL = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).wav")
        try PlaybackTests.writeTone(to: toneURL, format: kAudioFormatLinearPCM, seconds: 2)
        let tone = try await MediaImporter.makeItem(for: toneURL)
        var (state, urls, _) = try await sunsetProject(seconds: 2)
        state.media.append(tone)
        TimelineEditing.place(tone, at: .zero, onTrack: state.trackIndices(of: .audio)[0], in: &state)
        urls[tone.id] = toneURL
        let loud = try await export(snapshot(state, urls: urls, settings: ExportPreset.quickPreview.applied(to: ExportSettings())))
        let level = try await ExportProbe.audioLevel(loud.url)
        #expect(level > 0.05, "audible: \(level)")
        let audioDuration = try await AVURLAsset(url: loud.url).loadTracks(withMediaType: .audio).first!.load(.timeRange).duration.seconds
        #expect(abs(audioDuration - 2) < 0.05, "no audio drift: \(audioDuration)")

        // Muted, it's silent but still there; mute is honored like in playback.
        let toneClip = state.tracks[state.trackIndices(of: .audio)[0]].clips[0].id
        state.updateClip(toneClip) { $0.isMuted = true }
        let muted = try await export(snapshot(state, urls: urls, settings: ExportPreset.quickPreview.applied(to: ExportSettings())), name: "muted")
        #expect(try await ExportProbe.audioLevel(muted.url) < 0.001)
        #expect(try await AVURLAsset(url: muted.url).loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func exportedFramesMatchThePreview() async throws {
        var (state, urls, clip) = try await sunsetProject(seconds: 2)
        state.updateClip(clip.id) { c in
            c.color.offset.master = -0.1
            c.color.gain = ColorWheel(x: 0.2, y: 0.1, master: 0.2)
            c.color.curves.master = ToneCurve(points: [CurvePoint(x: 0, y: 0.05), CurvePoint(x: 0.5, y: 0.6), CurvePoint(x: 1, y: 1)])
            c.animation.setKeyframe(.scale, at: .zero, value: 1)
            c.animation.setKeyframe(.scale, at: Time(seconds: 2), value: 1.4)
            c.animation.setKeyframe(.saturation, at: .zero, value: 1.4)
            c.animation.setKeyframe(.saturation, at: Time(seconds: 2), value: 0.6)
            c.labs = [LabEffect(experimentID: "rgbSplit", values: ["amount": 10, "glitch": 0.6, "speed": 6])]
        }
        var settings = ExportPreset.proRes.applied(to: ExportSettings())
        settings.frameRate = 30
        let result = try await export(snapshot(state, urls: urls, settings: settings))
        for seconds in [0.5, 1.0, 1.5] {
            let preview = try await ExportProbe.previewFrame(state, urls: urls, at: seconds)
            let exported = try await ExportProbe.frame(result.url, at: seconds)
            let diff = try ExportProbe.difference(preview, exported)
            #expect(diff < 4, "frame at \(seconds) s differs by \(diff)")
        }
    }

    @Test func aFailingShaderExportsWithAWarning() async throws {
        var (state, urls, clip) = try await sunsetProject(seconds: 1)
        var shader = LabEffect(experimentID: "customShader")
        shader.source = "this is not metal"
        state.updateClip(clip.id) { $0.labs = [shader] }
        let result = try await export(snapshot(state, urls: urls, settings: ExportPreset.quickPreview.applied(to: ExportSettings())))
        #expect(FileManager.default.fileExists(atPath: result.url.path))
        #expect(result.warnings.count == 1 && result.warnings[0].contains("Custom Shader"), "\(result.warnings)")
        // The frame is the clip without the shader.
        var plain = state
        plain.updateClip(clip.id) { $0.labs = [] }
        let diff = try ExportProbe.difference(try await ExportProbe.previewFrame(plain, urls: urls, at: 0.5),
                                              try await ExportProbe.frame(result.url, at: 0.5))
        #expect(diff < 6)
    }

    @Test func theSnapshotIgnoresLaterEdits() async throws {
        var (state, urls, clip) = try await sunsetProject(seconds: 1)
        let frozen = snapshot(state, urls: urls, settings: ExportPreset.quickPreview.applied(to: ExportSettings()))
        // Delete the clip (and its track) after pressing Export.
        state.tracks.remove(at: 0)
        _ = clip
        let result = try await export(frozen)
        let image = try await ExportProbe.frame(result.url, at: 0.5)
        let p = try TextRenderTests.pixel(image, x: 100, y: 100)
        #expect(p.r > 60, "the exported frame still shows the clip: \(p)")
    }

    @Test func emptyTimelinesGiveAClearError() async throws {
        let state = ProjectState(settings: settings30)
        let empty = ExportSnapshot(state: state, urls: [:], range: TimeRange(start: .zero, end: .zero), settings: ExportSettings())
        await #expect(throws: ExportError.emptyTimeline) { try await self.export(empty) }
        #expect(ExportSettings().timeRange(timelineDuration: state.duration, selection: []) == nil)
    }

    /// Regression: many frames rendering at once (several exports, or exporting while
    /// playing) once exhausted the shared worker threads and froze every export.
    @Test func manySimultaneousExportsAllFinish() async throws {
        let (state, urls, clip) = try await sunsetProject(seconds: 1)
        var graded = state
        graded.updateClip(clip.id) { $0.color.saturation = 1.4 }
        let snapshots = (0..<12).map { i in snapshot(i.isMultiple(of: 2) ? state : graded, urls: urls) }
        let folder = ExportProbe.folder()
        let finished = try await withThrowingTaskGroup(of: Int.self) { group in
            for (i, snapshot) in snapshots.enumerated() {
                group.addTask {
                    try await ExportRunner.run(snapshot, to: folder.appendingPathComponent("many\(i).mp4"),
                                               cancellation: ExportCancellation()) { _, _ in }.frames
                }
            }
            // A deadline instead of hanging the whole test run.
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                return -1
            }
            var done = 0
            for try await frames in group {
                if frames < 0 { break }
                #expect(frames == 30)
                done += 1
                if done == snapshots.count { break }
            }
            group.cancelAll()
            return done
        }
        #expect(finished == 12, "every export finished")
    }

    @Test func theLiveViewSeesTheFramesBeingExported() async throws {
        let (state, urls, clip) = try await sunsetProject(seconds: 2)
        var graded = state
        graded.updateClip(clip.id) { $0.color.saturation = 0 }  // gray: easy to check
        var settings = ExportPreset.quickPreview.applied(to: ExportSettings())
        settings.frameRate = 30
        let snapshot = snapshot(graded, urls: urls, settings: settings)
        let collected = LiveFrames()
        let tap = ExportFrameTap(outputSize: CGSize(width: 960, height: 540), fills: true) { image, index in
            collected.add(image, index)
        }
        let url = ExportProbe.folder().appendingPathComponent("live.mp4")
        _ = try await ExportRunner.run(snapshot, to: url, cancellation: ExportCancellation(), frameTap: tap) { _, _ in }
        try await Task.sleep(for: .milliseconds(300))  // the last frame is prepared off the export's thread

        let frames = collected.frames
        #expect(!frames.isEmpty)
        #expect(frames.count < 60, "only a few frames a second are shown: \(frames.count)")
        let last = try #require(frames.max { $0.index < $1.index })
        #expect(last.index == 59, "the final frame is always shown")
        #expect(last.image.width == 960 && last.image.height == 540)
        // It's the exported picture (graded gray), the same as in the file.
        let inFile = try await ExportProbe.frame(url, at: 59.0 / 30)
        #expect(try ExportProbe.difference(last.image, inFile) < 4)
        let p = try TextRenderTests.pixel(last.image, x: 480, y: 270)
        #expect(abs(p.r - p.g) < 6 && abs(p.g - p.b) < 6, "\(p)")
    }

    @Test func liveFramesAreFramedLikeTheFile() throws {
        let wide = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        // Vertical, filled: cropped to 9:16, red all over.
        let filled = ExportFrameTap(outputSize: CGSize(width: 1080, height: 1920), fills: true) { _, _ in }.framed(wide)
        #expect(filled.extent.size == CGSize(width: 720, height: 1280))
        // Vertical, fitted: letterboxed, black above and below.
        let fitted = ExportFrameTap(outputSize: CGSize(width: 1080, height: 1920), fills: false) { _, _ in }.framed(wide)
        let image = try #require(CIContext().createCGImage(fitted, from: fitted.extent))
        let top = try TextRenderTests.pixel(image, x: 360, y: 40), middle = try TextRenderTests.pixel(image, x: 360, y: 640)
        #expect(top.r < 5 && middle.r > 250)
        // Never larger than needed.
        let small = ExportFrameTap(outputSize: CGSize(width: 640, height: 360), fills: true) { _, _ in }.framed(wide)
        #expect(small.extent.size == CGSize(width: 640, height: 360))
    }

    @Test func networkOptimizationPutsTheIndexFirst() async throws {
        let toneURL = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).wav")
        try PlaybackTests.writeTone(to: toneURL, format: kAudioFormatLinearPCM, seconds: 1)
        let tone = try await MediaImporter.makeItem(for: toneURL)
        var (state, urls, _) = try await sunsetProject(seconds: 1)
        state.media.append(tone)
        TimelineEditing.place(tone, at: .zero, onTrack: state.trackIndices(of: .audio)[0], in: &state)
        urls[tone.id] = toneURL
        var settings = ExportPreset.quickPreview.applied(to: ExportSettings())
        settings.frameRate = 30
        var optimizedFrame: CGImage?, plainFrame: CGImage?
        for optimized in [true, false] {
            settings.networkOptimized = optimized
            let result = try await export(snapshot(state, urls: urls, settings: settings), name: "net\(optimized)")
            let atoms = try ExportProbe.topLevelBoxes(result.url)
            let moov = try #require(atoms.firstIndex(of: "moov")), mdat = try #require(atoms.firstIndex(of: "mdat"))
            #expect((moov < mdat) == optimized, "\(atoms)")
            // Moving the index keeps every frame and sample where it belongs.
            #expect(try await ExportProbe.frameCount(result.url) == 30)
            #expect(try await ExportProbe.audioLevel(result.url) > 0.001)
            if optimized { optimizedFrame = try await ExportProbe.frame(result.url, at: 0.6) }
            else { plainFrame = try await ExportProbe.frame(result.url, at: 0.6) }
        }
        #expect(try ExportProbe.difference(try #require(optimizedFrame), try #require(plainFrame)) < 1)
    }

    @Test func writingIsAtomicAndCancelLeavesNothingBehind() async throws {
        let (state, urls, _) = try await sunsetProject(seconds: 2)
        let folder = ExportProbe.folder()
        let destination = folder.appendingPathComponent("keep.mp4")
        try Data("the old file".utf8).write(to: destination)

        // Canceled partway: the old file is untouched and nothing else is left in the folder.
        let cancellation = ExportCancellation()
        let snap = snapshot(state, urls: urls, settings: ExportPreset.quickPreview.applied(to: ExportSettings()))
        await #expect(throws: ExportError.cancelled) {
            _ = try await ExportRunner.run(snap, to: destination, cancellation: cancellation) { _, frames in
                if frames >= 10 { cancellation.cancel() }
            }
        }
        #expect(try String(contentsOf: destination, encoding: .utf8) == "the old file")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["keep.mp4"])

        // Finished: replaced in one step by a complete movie.
        let result = try await ExportRunner.run(snap, to: destination, cancellation: ExportCancellation()) { _, _ in }
        #expect(try await ExportProbe.frameCount(result.url) == 60)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["keep.mp4"])
    }
}

nonisolated private final class LiveFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(image: CGImage, index: Int)] = []
    var frames: [(image: CGImage, index: Int)] { lock.withLock { stored } }
    func add(_ image: CGImage, _ index: Int) { lock.withLock { stored.append((image, index)) } }
}
