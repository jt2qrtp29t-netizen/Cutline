import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct OfflineMediaTests {
    let settings = ProjectSettings(name: "T", width: 1920, height: 1080, frameRate: 30)

    /// A copy of a test movie in a temporary folder, so it can be deleted.
    private func temporaryCopy(of name: String) async throws -> (MediaItem, URL) {
        let original = try await PlaybackTests.media(name)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("\(name).mov")
        try FileManager.default.copyItem(at: original.fileURL, to: url)
        var media = original
        media.id = UUID()
        media.path = url.path
        media.bookmark = nil
        return (media, url)
    }

    @Test func missingVideoShowsTheOfflineSlate() async throws {
        let (media, url) = try await temporaryCopy(of: "Ocean")
        try FileManager.default.removeItem(at: url)
        var state = ProjectState(settings: settings, videoTracks: 1, audioTracks: 0, textTracks: 0)
        state.media = [media]
        state.tracks[0].clips = [Clip(id: UUID(), mediaID: media.id, name: "Ocean", start: .zero,
                                      duration: Time(seconds: 2), sourceStart: .zero)]
        let output = try await CompositionBuilder.build(state, urls: [media.id: url])
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let p = try TextRenderTests.pixel(image, x: 100, y: 100)
        #expect(p.r > 100 && p.g < 60 && p.b < 60, "red slate instead of black: \(p)")
        // The label is white text in the middle.
        var bright = 0
        for x in stride(from: 700, to: 1220, by: 4) {
            let c = try TextRenderTests.pixel(image, x: x, y: 510)
            if c.r > 200 && c.g > 200 && c.b > 200 { bright += 1 }
        }
        #expect(bright > 5, "“Media Offline” is written on it")
    }

    @Test func availabilityFollowsTheFile() async throws {
        let (media, url) = try await temporaryCopy(of: "Ocean")
        let cache = MediaURLCache.shared
        #expect(cache.isAvailable(media))

        let moved = url.deletingLastPathComponent().appendingPathComponent("moved.mov")
        try FileManager.default.moveItem(at: url, to: moved)
        nonisolated final class Received: @unchecked Sendable { var ids: Set<UUID> = [] }
        let received = Received()
        // Posted synchronously from `recheck()`, on this thread.
        let observer = NotificationCenter.default.addObserver(forName: .mediaAvailabilityChanged, object: nil, queue: nil) { note in
            received.ids.formUnion(note.object as? Set<UUID> ?? [])
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        cache.recheck()
        #expect(!cache.isAvailable(media) && received.ids.contains(media.id), "offline once the file is gone")

        try FileManager.default.moveItem(at: moved, to: url)
        received.ids = []
        cache.recheck()
        #expect(cache.isAvailable(media) && received.ids.contains(media.id), "back online when it returns")
    }

    @Test func relinkingPointsTheMediaAtTheNewFile() async throws {
        let (media, url) = try await temporaryCopy(of: "Ocean")
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try FileManager.default.moveItem(at: url, to: elsewhere)
        var state = ProjectState(settings: settings)
        state.media = [media]
        state.tracks[0].clips = [Clip(id: UUID(), mediaID: media.id, name: "Ocean", start: .zero,
                                      duration: Time(seconds: 2), sourceStart: .zero)]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        MediaURLCache.shared.recheck()
        #expect(editor.offlineMedia.map(\.id) == [media.id])

        undo.beginUndoGrouping()
        await editor.relink([media.id: elsewhere])
        undo.endUndoGrouping()
        #expect(editor.state.mediaItem(media.id)?.path == elsewhere.path)
        #expect(editor.offlineMedia.isEmpty)
        #expect(editor.alert == nil)

        // An audio file can't stand in for a video.
        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try PlaybackTests.writeTone(to: tone, format: kAudioFormatLinearPCM, seconds: 1)
        undo.beginUndoGrouping()
        await editor.relink([media.id: tone])
        undo.endUndoGrouping()
        #expect(editor.state.mediaItem(media.id)?.path == elsewhere.path)
        #expect(editor.alert != nil)
    }
}
