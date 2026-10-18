import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct ExportQueueTests {
    private func job(_ name: String, seconds: Double = 1, folder: URL) async throws -> ExportJob {
        let media = try await PlaybackTests.media("Sunset")
        var state = ProjectState(settings: ProjectSettings(name: "Q", width: 640, height: 360, frameRate: 30),
                                 videoTracks: 1, audioTracks: 1, textTracks: 0)
        state.media = [media]
        state.tracks[0].clips = [Clip(id: UUID(), mediaID: media.id, name: "Sunset", start: .zero,
                                      duration: Time(seconds: seconds), sourceStart: .zero)]
        let settings = ExportPreset.quickPreview.applied(to: ExportSettings())
        let snapshot = ExportSnapshot(state: state, urls: [media.id: media.fileURL],
                                      range: ExportSnapshot.snapped(TimeRange(start: .zero, end: state.duration), fps: 30),
                                      settings: settings)
        return ExportJob(title: name, sourceName: "Edit", isPlayground: false, snapshot: snapshot,
                         destination: folder.appendingPathComponent("\(name).mp4"))
    }

    private func waitUntilIdle(_ queue: ExportQueue) async throws {
        let deadline = Date().addingTimeInterval(60)
        while queue.hasActiveJobs {
            #expect(Date() < deadline, "the queue should finish")
            if Date() >= deadline { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func jobsRunOneAfterAnotherInOrder() async throws {
        let folder = ExportProbe.folder()
        let queue = ExportQueue()
        queue.notifies = false
        let first = try await job("first", seconds: 1.5, folder: folder)
        let second = try await job("second", folder: folder)
        let third = try await job("third", folder: folder)
        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)
        #expect(first.status == .queued || first.status == .rendering)
        #expect(second.status == .queued && third.status == .queued, "only one runs at a time")
        queue.cancel(third)
        #expect(third.status == .canceled)

        try await waitUntilIdle(queue)
        #expect(first.status == .done && second.status == .done && third.status == .canceled)
        #expect(first.endDate! <= second.startDate!, "the second started after the first finished")
        #expect(first.progress == 1 && first.framesDone == 45)
        #expect(FileManager.default.fileExists(atPath: second.destination.path))
        #expect(!FileManager.default.fileExists(atPath: third.destination.path), "a canceled queued job never ran")
    }

    @Test func cancelingARunningExportRemovesItsPartialFile() async throws {
        let folder = ExportProbe.folder()
        let queue = ExportQueue()
        queue.notifies = false
        // Long enough to still be running when a busy test machine gets round to canceling it.
        let long = try await job("long", seconds: 120, folder: folder)
        queue.enqueue(long)
        // Wait until it's actually writing frames, then cancel.
        let deadline = Date().addingTimeInterval(30)
        while long.framesDone < 5 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(long.status == .rendering)
        queue.cancel(long)
        try await waitUntilIdle(queue)
        #expect(long.status == .canceled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty, "no partial file")

        // Finished jobs can be cleared from the list.
        queue.clearFinished()
        #expect(queue.jobs.isEmpty)
    }

    @Test func aFailedExportReportsWhy() async throws {
        let folder = ExportProbe.folder()
        let queue = ExportQueue()
        queue.notifies = false
        var empty = try await job("empty", folder: folder)
        empty = ExportJob(title: "empty", sourceName: "Edit", isPlayground: false,
                          snapshot: ExportSnapshot(state: ProjectState(), urls: [:], range: TimeRange(start: .zero, end: .zero),
                                                   settings: ExportSettings()),
                          destination: folder.appendingPathComponent("empty.mp4"))
        queue.enqueue(empty)
        try await waitUntilIdle(queue)
        #expect(empty.status == .failed(ExportError.emptyTimeline.localizedDescription))
    }
}
