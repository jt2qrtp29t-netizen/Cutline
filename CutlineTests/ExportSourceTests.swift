import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct ExportSourceTests {
    /// A project with a Sunset clip on V1, and its Playground.
    private func project() async throws -> (EditorController, UndoManager, Clip) {
        let media = try await PlaybackTests.media("Sunset")
        var state = ProjectState(settings: ProjectSettings(name: "Trip", width: 640, height: 360, frameRate: 30),
                                 videoTracks: 1, audioTracks: 1, textTracks: 0)
        state.id = UUID()
        state.media = [media]
        let clip = Clip(id: UUID(), mediaID: media.id, name: "Sunset", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        state.tracks[0].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.playgroundFolder = ExportProbe.folder()
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        return (editor, undo, clip)
    }

    private func run(_ jobs: [ExportJob]) async throws {
        let queue = ExportQueue()
        queue.notifies = false
        jobs.forEach(queue.enqueue)
        let deadline = Date().addingTimeInterval(60)
        while queue.hasActiveJobs && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        for job in jobs { #expect(job.status == .done, "\(job.title): \(job.status)") }
    }

    @Test func playgroundExportsRenderTheSandboxAndNeverTouchTheProject() async throws {
        let (editor, undo, clip) = try await project()
        editor.sendToPlayground([clip.id])
        let sandbox = editor.playground!.editor
        let copy = sandbox.state.allClips[0]
        sandbox.store.edit("Gray") { $0.updateClip(copy.id) { $0.color.saturation = 0 } }
        editor.updateExportSettings(for: .playground) { $0 = ExportPreset.quickPreview.applied(to: $0) }

        let before = editor.state
        #expect(editor.defaultExportName(for: .playground).hasSuffix("-playground"))
        let folder = ExportProbe.folder()
        let jobs = try editor.makeExportJobs(source: .playground, fileName: editor.defaultExportName(for: .playground), folder: folder)
        #expect(jobs.count == 1 && jobs[0].isPlayground && jobs[0].destination.lastPathComponent.contains("-playground"))
        try await run(jobs)

        #expect(editor.state == before && !undo.canUndo, "the project, its settings and its history are untouched")
        let frame = try await ExportProbe.frame(jobs[0].destination, at: 1)
        let p = try TextRenderTests.pixel(frame, x: 100, y: 100)
        #expect(abs(p.r - p.b) < 10, "the gray Playground copy was exported, not the colorful original: \(p)")
    }

    @Test func variantsExportAloneOrEachAsItsOwnFile() async throws {
        let (editor, _, clip) = try await project()
        editor.sendToPlayground([clip.id])
        let playground = editor.playground!
        let a = playground.editor.state.allClips[0].id
        let b = playground.makeVariant(of: a)!
        _ = playground.makeVariant(of: b)
        playground.editor.selection = [b]

        let all = try editor.makeExportJobs(source: .playground, fileName: "Look", folder: ExportProbe.folder(), variants: .all)
        #expect(all.map(\.title) == ["Look-A", "Look-B", "Look-C"])
        for (index, job) in all.enumerated() {
            let group = job.snapshot.state
            let visible = group.allClips.filter { !$0.isMuted }
            #expect(visible.count == 1, "only variant \(index) is drawn")
        }
        let one = try editor.makeExportJobs(source: .playground, fileName: "Look", folder: ExportProbe.folder(), variants: .selected)
        #expect(one.map(\.title) == ["Look-B"])
        #expect(one[0].snapshot.state.clip(b)?.isMuted == false && one[0].snapshot.state.clip(a)?.isMuted == true)
    }

    @Test func rangesComeFromTheSourceTimeline() async throws {
        let (editor, _, clip) = try await project()
        editor.updateExportSettings(for: .edit) { $0.range = .selection }
        #expect(throws: ExportError.emptyTimeline) {
            try editor.makeExportJobs(source: .edit, fileName: "x", folder: ExportProbe.folder())
        }
        editor.selection = [clip.id]
        let jobs = try editor.makeExportJobs(source: .edit, fileName: "x", folder: ExportProbe.folder())
        #expect(jobs[0].snapshot.range == TimeRange(start: .zero, end: Time(seconds: 2)))

        editor.updateExportSettings(for: .edit) { s in
            s.range = .inOut
            s.inPoint = Time(seconds: 0.51)
            s.outPoint = Time(seconds: 1.5)
        }
        let ranged = try editor.makeExportJobs(source: .edit, fileName: "x", folder: ExportProbe.folder())
        #expect(ranged[0].snapshot.range.start == Time(seconds: 0.5), "snapped to a frame")
        #expect(ranged[0].snapshot.frameCount == 30)
    }

    @Test func missingMediaAndLUTsAreFlaggedBeforeExporting() async throws {
        let (editor, undo, clip) = try await project()
        #expect(editor.exportPreflightWarnings(for: .edit).isEmpty)
        undo.beginUndoGrouping()
        editor.store.edit("Setup") { state in
            state.media[0].path = "/nonexistent/\(UUID()).mov"
            state.media[0].bookmark = nil
            state.updateClip(clip.id) { $0.color.lut = LUTReference(name: "Gone", path: "/nonexistent/gone.cube") }
        }
        undo.endUndoGrouping()
        MediaURLCache.shared.invalidate()
        let warnings = editor.exportPreflightWarnings(for: .edit)
        #expect(warnings.count == 2, "\(warnings)")
        #expect(warnings.contains { $0.contains("Sunset") } && warnings.contains { $0.contains("Gone") })
    }
}
