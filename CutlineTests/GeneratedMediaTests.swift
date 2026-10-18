import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct GeneratedMediaTests {
    private func library() -> GeneratedMediaLibrary {
        GeneratedMediaLibrary(folder: ExportProbe.folder().appendingPathComponent("Generated-\(UUID().uuidString)"))
    }

    private func frameTimes(_ url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let provider = reader.sampleProvider(for: output)
        try reader.startOrThrow()
        var times: [CMTime] = []
        while let sample = try await provider.next() { times.append(sample.presentationTimeStamp) }
        return times.sorted { CMTimeCompare($0, $1) < 0 }
    }

    private func codec(_ url: URL) async throws -> FourCharCode {
        let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        return CMFormatDescriptionGetMediaSubType(description)
    }

    @Test func copiesKeepEveryFrameTimeAtTheirSize() async throws {
        let ocean = try await PlaybackTests.media("Ocean")
        let folder = ExportProbe.folder()
        let original = try await frameTimes(ocean.fileURL)
        for kind in GeneratedMediaKind.allCases {
            let url = folder.appendingPathComponent("copy-\(kind.rawValue)-\(UUID()).mov")
            try await MediaTranscoder.transcode(ocean.fileURL, to: url, kind: kind, cancellation: ExportCancellation()) { _ in }
            #expect(try await frameTimes(url) == original, "\(kind): every frame at the same time")
            let track = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
            let size = try await track.load(.naturalSize)
            #expect(size == (kind == .optimized ? CGSize(width: 1280, height: 720) : CGSize(width: 640, height: 360)))
            #expect(try await codec(url) == (kind == .optimized ? kCMVideoCodecType_AppleProRes422 : kCMVideoCodecType_AppleProRes422Proxy))
            let duration = try await AVURLAsset(url: url).load(.duration)
            #expect(abs(duration.seconds - ocean.duration.seconds) < 0.02)
        }
    }

    @Test func proxiesFrameTheShotLikeTheOriginal() async throws {
        let sunset = try await PlaybackTests.media("Sunset")
        let proxyURL = ExportProbe.folder().appendingPathComponent("proxy-\(UUID()).mov")
        try await MediaTranscoder.transcode(sunset.fileURL, to: proxyURL, kind: .proxy, cancellation: ExportCancellation()) { _ in }
        var state = ProjectState(settings: ProjectSettings(name: "P", width: 1280, height: 720, frameRate: 30),
                                 videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [sunset]
        var clip = Clip(id: UUID(), mediaID: sunset.id, name: "Sunset", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        clip.transform.scale = 0.6
        clip.transform.positionX = 200
        clip.crop.left = 0.2
        state.tracks[0].clips = [clip]
        let original = try await ExportProbe.previewFrame(state, urls: [sunset.id: sunset.fileURL], at: 1)
        let proxy = try await ExportProbe.previewFrame(state, urls: [sunset.id: proxyURL], at: 1)
        // Same size, place and crop; only a little softer.
        #expect(try ExportProbe.difference(original, proxy) < 6)
        #expect(proxy.width == 1280 && proxy.height == 720)
    }

    @Test func playbackPicksTheCopyItAsksForAndExportsUseOriginals() async throws {
        let lib = library()
        let ocean = try await PlaybackTests.media("Ocean")
        #expect(lib.status(of: ocean, kind: .proxy) == .none)
        #expect(lib.playbackURL(for: ocean, choice: .proxy) == nil, "nothing made yet: the original")

        lib.create(.optimized, for: [ocean])
        #expect(lib.status(of: ocean, kind: .optimized) == .queued || lib.status(of: ocean, kind: .optimized) != .none)
        await lib.waitUntilIdle()
        #expect(lib.status(of: ocean, kind: .optimized) == .ready)
        let optimized = try #require(lib.fileURL(for: ocean, kind: .optimized))
        #expect(lib.playbackURL(for: ocean, choice: .original) == nil)
        #expect(lib.playbackURL(for: ocean, choice: .optimized) == optimized)
        #expect(lib.playbackURL(for: ocean, choice: .proxy) == optimized, "no proxy yet: optimized is next best")

        lib.create(.proxy, for: [ocean])
        await lib.waitUntilIdle()
        let proxy = try #require(lib.fileURL(for: ocean, kind: .proxy))
        #expect(lib.playbackURL(for: ocean, choice: .proxy) == proxy)
        #expect(lib.diskUsage() > 0)

        // Exports always read the original file.
        let (editor, _, _) = try await editorWith(ocean)
        let job = try #require(try editor.makeExportJobs(source: .edit, fileName: "x", folder: ExportProbe.folder()).first)
        #expect(job.snapshot.urls[ocean.id] == ocean.fileURL)

        lib.delete(.proxy, for: [ocean])
        #expect(lib.status(of: ocean, kind: .proxy) == .none)
        #expect(!FileManager.default.fileExists(atPath: proxy.path))
        lib.deleteAll()
        #expect(lib.status(of: ocean, kind: .optimized) == .none && lib.diskUsage() == 0)
    }

    @Test func aChangedOriginalNeedsANewCopy() async throws {
        let copy = ExportProbe.folder().appendingPathComponent("changing-\(UUID()).mov")
        try FileManager.default.copyItem(at: try await PlaybackTests.media("Sunset").fileURL, to: copy)
        let media = try await MediaImporter.makeItem(for: copy)
        let lib = library()
        lib.create(.proxy, for: [media])
        await lib.waitUntilIdle()
        #expect(lib.status(of: media, kind: .proxy) == .ready)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: copy.path)
        MediaURLCache.shared.recheck()
        #expect(lib.status(of: media, kind: .proxy) == .none, "the old copy doesn't match the edited file")
    }

    @Test func cancelingLeavesNoFiles() async throws {
        let ocean = try await PlaybackTests.media("Ocean")
        let lib = library()
        lib.create(.optimized, for: [ocean])
        try await Task.sleep(for: .milliseconds(30))
        lib.delete(.optimized, for: [ocean])
        await lib.waitUntilIdle()
        #expect(lib.status(of: ocean, kind: .optimized) == .none)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: lib.folder.path)) ?? []
        #expect(left.isEmpty, "\(left)")
    }

    private func editorWith(_ media: MediaItem) async throws -> (EditorController, MediaItem, Clip) {
        var state = ProjectState(settings: ProjectSettings(name: "G", width: 640, height: 360, frameRate: 30),
                                 videoTracks: 1, audioTracks: 1, textTracks: 0)
        state.media = [media]
        let clip = Clip(id: UUID(), mediaID: media.id, name: media.name, start: .zero, duration: Time(seconds: 1), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        return (EditorController(store: ProjectStore(state: state)), media, clip)
    }
}
