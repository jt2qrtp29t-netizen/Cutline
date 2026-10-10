import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct VariantTests {
    private func session(with clip: Clip, media: [MediaItem] = []) -> PlaygroundSession {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        let session = PlaygroundSession(key: "v", projectSettings: ProjectSettings(name: "T", width: 1920, height: 1080, frameRate: 30),
                                        folder: folder)
        session.undoManager.groupsByEvent = false
        session.undoManager.beginUndoGrouping()
        session.editor.store.edit("Setup") { state in
            state.media = media
            state.tracks[0].clips = [clip]
        }
        session.undoManager.endUndoGrouping()
        return session
    }

    private func step(_ s: PlaygroundSession, _ body: () -> Void) {
        s.undoManager.beginUndoGrouping()
        body()
        s.undoManager.endUndoGrouping()
    }

    @Test func variantsCompareOneAtATimeOrSideBySide() {
        let clip = Clip(id: UUID(), mediaID: UUID(), name: "Shot", start: .zero, duration: Time(seconds: 3), sourceStart: .zero)
        let s = session(with: clip)
        var b: UUID?
        step(s) { b = s.makeVariant(of: clip.id) }
        var c: UUID?
        step(s) { c = s.makeVariant(of: b!) }
        let group = s.variantGroup(containing: clip.id)!
        #expect(group.clipIDs == [clip.id, b!, c!] && group.active == 2)
        #expect(s.editor.state.clip(c!)?.name == "Shot (C)" && s.editor.state.clip(c!)?.start == .zero)
        #expect(s.editor.state.trackIndices(of: .video).count == 3, "each variant on its own track")

        // One at a time: only the active variant is drawn; the clips themselves aren't changed.
        s.showVariant(1, in: group.id)
        let drawn = s.editor.playback.prepared(s.editor.state)
        #expect(drawn.clip(b!)?.isMuted == false && drawn.clip(clip.id)?.isMuted == true && drawn.clip(c!)?.isMuted == true)
        #expect(s.editor.state.clip(clip.id)?.isMuted == false)

        // Side by side: thirds.
        s.setCompare(.split, for: group.id)
        let split = s.editor.playback.prepared(s.editor.state)
        #expect(abs(split.clip(b!)!.crop.left - 1.0 / 3) < 1e-9 && abs(split.clip(b!)!.crop.right - 1.0 / 3) < 1e-9)
        #expect(split.clip(clip.id)!.crop.right > 0.66 && split.clip(c!)!.crop.left > 0.66)
    }

    @Test func keepingOneVariantDeletesTheOthersAsOneStep() {
        let clip = Clip(id: UUID(), mediaID: UUID(), name: "Shot", start: .zero, duration: Time(seconds: 3), sourceStart: .zero)
        let s = session(with: clip)
        var b: UUID?
        step(s) { b = s.makeVariant(of: clip.id) }
        let group = s.variantGroup(containing: clip.id)!
        step(s) { s.keepOnly(b!, in: group.id) }
        #expect(s.editor.state.allClips.map(\.id) == [b!] && s.variants.isEmpty)
        #expect(s.editor.state.trackIndices(of: .video).count == 1, "the emptied track is removed")
        s.undoManager.undo()
        #expect(s.editor.state.allClips.count == 2)
    }

    @Test func undoingAVariantDropsItFromTheComparison() {
        let clip = Clip(id: UUID(), mediaID: UUID(), name: "Shot", start: .zero, duration: Time(seconds: 3), sourceStart: .zero)
        let s = session(with: clip)
        step(s) { s.makeVariant(of: clip.id) }
        s.undoManager.undo()
        #expect(s.variantGroup(containing: clip.id) == nil, "a group of one isn't a comparison")
        #expect(s.editor.playback.prepared(s.editor.state).clip(clip.id)?.isMuted == false)
    }

    @Test func splitViewRendersEachVariantInItsSlice() async throws {
        let media = try await PlaybackTests.media("Sunset")
        let clip = Clip(id: UUID(), mediaID: media.id, name: "Sunset", start: .zero, duration: Time(seconds: 2), sourceStart: .zero)
        let s = session(with: clip, media: [media])
        var b: UUID?
        step(s) { b = s.makeVariant(of: clip.id) }
        step(s) { s.editor.store.edit("Grade B") { $0.updateClip(b!) { $0.color.saturation = 0 } } }   // B is gray
        s.setCompare(.split, for: s.variantGroup(containing: clip.id)!.id)

        let output = try await CompositionBuilder.build(s.editor.playback.prepared(s.editor.state), urls: [media.id: media.fileURL])
        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        let image = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let left = try TextRenderTests.pixel(image, x: 300, y: 150), right = try TextRenderTests.pixel(image, x: 1600, y: 150)
        #expect(left.r > left.b + 30, "A (left) keeps its color: \(left)")
        #expect(abs(right.r - right.b) < 12, "B (right) is desaturated: \(right)")
    }

    @Test func snapshotsRestoreAndSurviveSaving() {
        let clip = Clip(id: UUID(), mediaID: UUID(), name: "Shot", start: .zero, duration: Time(seconds: 3), sourceStart: .zero)
        let s = session(with: clip)
        s.saveSnapshot(named: "  Before tweaks ")
        step(s) { s.editor.store.edit("Tweak") { $0.updateClip(clip.id) { $0.color.contrast = 1.8 } } }
        step(s) { s.makeVariant(of: clip.id) }
        s.saveSnapshot(named: "")
        #expect(s.snapshots.map(\.name) == ["Snapshot 2", "Before tweaks"])

        step(s) { s.restore(s.snapshots[1]) }
        #expect(s.editor.state.clip(clip.id)?.color.contrast == 1 && s.editor.state.allClips.count == 1 && s.variants.isEmpty)
        s.undoManager.undo()
        #expect(s.editor.state.clip(clip.id)?.color.contrast == 1.8, "restoring is undoable")

        s.saveNow()
        let reopened = PlaygroundSession(key: s.key, projectSettings: .default, folder: s.folder)
        #expect(reopened.snapshots.map(\.name) == ["Snapshot 2", "Before tweaks"])
        #expect(reopened.snapshots[0].variants.count == 1)
    }
}
