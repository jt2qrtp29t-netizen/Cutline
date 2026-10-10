import Foundation
import Testing
@testable import Cutline

struct EditingTests {
    let media = MediaItem(id: UUID(), name: "m", path: "/m.mov", duration: Time(seconds: 10),
                          width: 1920, height: 1080, frameRate: 30, hasAudio: true)

    func state(clipsAt starts: [Double], duration: Double = 4) -> ProjectState {
        var state = ProjectState(videoTracks: 2, audioTracks: 1)
        state.media = [media]
        for start in starts {
            var clip = TimelineEditing.makeClip(for: media, at: Time(seconds: start), fps: 30)
            clip.duration = Time(seconds: duration)
            TimelineEditing.insert(clip, onTrack: 0, in: &state)
        }
        return state
    }

    @Test func bladeSplitsIntoContiguousIndependentClips() throws {
        var s = state(clipsAt: [0])
        let original = s.tracks[0].clips[0]
        let created = TimelineEditing.blade(at: Time(seconds: 1.5), clips: [], in: &s)
        #expect(created.count == 1)
        let clips = s.tracks[0].clips
        #expect(clips.count == 2)
        #expect(clips[0].id == original.id && clips[1].id != original.id)
        #expect(clips[0].end == clips[1].start)
        #expect(clips[1].sourceStart == Time(seconds: 1.5))
        #expect(clips[0].duration + clips[1].duration == original.duration)
    }

    @Test func bladeOnlyTouchesSelectedClips() {
        var s = state(clipsAt: [0])
        var other = TimelineEditing.makeClip(for: media, at: .zero, fps: 30)
        other.duration = Time(seconds: 4)
        TimelineEditing.insert(other, onTrack: 1, in: &s)
        TimelineEditing.blade(at: Time(seconds: 2), clips: [other.id], in: &s)
        #expect(s.tracks[0].clips.count == 1)
        #expect(s.tracks[1].clips.count == 2)
    }

    @Test func bladeRespectsSpeed() {
        var s = state(clipsAt: [0])
        let id = s.tracks[0].clips[0].id
        TimelineEditing.setSpeed(2, for: id, in: &s)
        TimelineEditing.blade(at: Time(seconds: 1), clips: [], in: &s)
        #expect(s.tracks[0].clips[1].sourceStart == Time(seconds: 2))
    }

    @Test func insertOverwritesAndSplitsUnderlyingClip() {
        var s = state(clipsAt: [0], duration: 9)
        var middle = TimelineEditing.makeClip(for: media, at: Time(seconds: 3), fps: 30)
        middle.duration = Time(seconds: 2)
        TimelineEditing.insert(middle, onTrack: 0, in: &s)
        let clips = s.tracks[0].clips
        #expect(clips.map(\.start) == [.zero, Time(seconds: 3), Time(seconds: 5)])
        #expect(clips[2].sourceStart == Time(seconds: 5))
        #expect(clips[0].end == Time(seconds: 3))
    }

    @Test func trimIsLimitedByMediaAndNeighbours() {
        var s = state(clipsAt: [0, 6])
        let first = s.tracks[0].clips[0].id
        TimelineEditing.trim(first, edge: .trailing, to: Time(seconds: 20), in: &s)
        #expect(s.clip(first)?.end == Time(seconds: 6), "stops at the next clip")
        TimelineEditing.trim(first, edge: .leading, to: Time(seconds: -3), in: &s)
        #expect(s.clip(first)?.start == .zero, "cannot extend before media start")
        let second = s.tracks[0].clips[1].id
        TimelineEditing.trim(second, edge: .trailing, to: Time(seconds: 30), in: &s)
        #expect(s.clip(second)?.sourceEnd == Time(seconds: 10), "cannot extend past media end")
    }

    @Test func moveAcrossTracksClampsToValidTracks() {
        var s = state(clipsAt: [0])
        let id = s.tracks[0].clips[0].id
        TimelineEditing.move([id], by: Time(seconds: 2), trackChange: .ordinalDelta(5), in: &s)
        #expect(s.trackIndex(ofClip: id) == 1)
        #expect(s.clip(id)?.start == Time(seconds: 2))
        TimelineEditing.move([id], by: Time(seconds: -10), trackChange: .ordinalDelta(0), in: &s)
        #expect(s.clip(id)?.start == .zero)
    }

    @Test func snapPicksNearestPoint() {
        let result = SnapEngine.snap(
            edges: [Time(seconds: 1.02), Time(seconds: 5)],
            to: [Time(seconds: 1), Time(seconds: 5.1)],
            threshold: Time(seconds: 0.2)
        )
        #expect(result?.target == Time(seconds: 1))
        #expect(result?.offset == Time(seconds: -0.02))
        #expect(SnapEngine.snap(edges: [Time(seconds: 3)], to: [Time(seconds: 1)], threshold: Time(seconds: 0.2)) == nil)
    }

    @Test func storeUndoRedoRestoresState() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = ProjectStore(state: state(clipsAt: [0]))
        store.undoManager = undo
        let before = store.state

        undo.beginUndoGrouping()
        store.edit("Blade") { TimelineEditing.blade(at: Time(seconds: 1), clips: [], in: &$0) }
        undo.endUndoGrouping()
        let after = store.state
        #expect(after.tracks[0].clips.count == 2)
        #expect(undo.undoActionName == "Blade")

        undo.undo()
        #expect(store.state == before)
        undo.redo()
        #expect(store.state == after)
    }

    @Test func liveEditCommitsAsSingleUndoStep() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let store = ProjectStore(state: state(clipsAt: [0]))
        store.undoManager = undo
        let before = store.state
        let id = before.tracks[0].clips[0].id

        store.beginLiveEdit()
        for step in 1...5 {
            store.liveEdit { TimelineEditing.move([id], by: Time(seconds: Double(step)), trackChange: .ordinalDelta(0), in: &$0) }
        }
        undo.beginUndoGrouping()
        store.commitLiveEdit("Move Clip")
        undo.endUndoGrouping()
        #expect(store.state.clip(id)?.start == Time(seconds: 5))

        undo.undo()
        #expect(store.state == before)
        #expect(!undo.canUndo)
    }

    @Test func placingVideoWithSoundCreatesUnlinkedVideoAndAudioClips() {
        var s = ProjectState(videoTracks: 2, audioTracks: 1)
        s.media = [media]
        let v2 = s.trackIndices(of: .video)[1]
        let created = TimelineEditing.place(media, at: Time(seconds: 1), onTrack: v2, in: &s)
        #expect(created.count == 2)
        #expect(s.tracks[v2].clips.count == 1)
        // V2 pairs with A2, which did not exist and is created.
        let audio = s.trackIndices(of: .audio)
        #expect(audio.count == 2)
        #expect(s.tracks[audio[1]].clips.count == 1)
        let video = s.tracks[v2].clips[0], sound = s.tracks[audio[1]].clips[0]
        #expect(video.id != sound.id && video.range == sound.range)

        // Unlinked: moving the picture leaves the sound where it was.
        TimelineEditing.move([video.id], by: Time(seconds: 2), trackChange: .ordinalDelta(0), in: &s)
        #expect(s.clip(video.id)?.start == Time(seconds: 3))
        #expect(s.clip(sound.id)?.start == Time(seconds: 1))
    }

    @Test func audioOnlyMediaGoesToAnAudioTrack() {
        var s = ProjectState(videoTracks: 1, audioTracks: 1)
        let song = MediaItem(id: UUID(), name: "song", path: "/s.wav", duration: Time(seconds: 3),
                             width: 0, height: 0, frameRate: 0, hasVideo: false, hasAudio: true)
        s.media = [song]
        TimelineEditing.place(song, at: .zero, onTrack: s.trackIndices(of: .video)[0], in: &s)
        #expect(s.tracks[s.trackIndices(of: .video)[0]].clips.isEmpty)
        #expect(s.tracks[s.trackIndices(of: .audio)[0]].clips.count == 1)
    }

    @Test func lockedTracksRejectEdits() {
        var s = state(clipsAt: [0])
        let id = s.tracks[0].clips[0].id
        s.tracks[0].isLocked = true
        let before = s
        TimelineEditing.move([id], by: Time(seconds: 2), trackChange: .ordinalDelta(0), in: &s)
        TimelineEditing.trim(id, edge: .trailing, to: Time(seconds: 1), in: &s)
        TimelineEditing.blade(at: Time(seconds: 1), clips: [], in: &s)
        TimelineEditing.delete([id], in: &s)
        #expect(s == before)
        #expect(TimelineEditing.place(media, at: .zero, onTrack: 0, in: &s).isEmpty)

        // Moving another clip onto a locked track is refused; it stays put.
        s.tracks[0].isLocked = false
        var other = TimelineEditing.makeClip(for: media, at: Time(seconds: 6), fps: 30)
        other.duration = Time(seconds: 1)
        TimelineEditing.insert(other, onTrack: 1, in: &s)
        s.tracks[0].isLocked = true
        TimelineEditing.move([other.id], by: .zero, trackChange: .ordinalDelta(-1), in: &s)
        #expect(s.trackIndex(ofClip: other.id) == 1)
    }

    @Test func versionOneProjectsGainSeparateAudio() throws {
        let mediaID = UUID()
        let json = """
        {"version":1,"settings":{"name":"Old","width":1920,"height":1080,"frameRate":30},
         "media":[{"id":"\(mediaID)","name":"m","path":"/m.mov","duration":6000,"width":1280,"height":720,"frameRate":30,"hasAudio":true}],
         "tracks":[{"id":"\(UUID())","name":"V1","clips":[{"id":"\(UUID())","mediaID":"\(mediaID)","name":"m","start":600,"duration":1200,"sourceStart":0,"speed":1,
           "transform":{"positionX":0,"positionY":0,"scale":1},"opacity":1,"color":{"exposure":0,"brightness":0,"contrast":1,"saturation":1}}]}],
         "markers":[]}
        """
        let s = try ProjectState.decode(Data(json.utf8))
        #expect(s.version == ProjectState.currentVersion)
        #expect(s.tracks[0].kind == .video && s.media[0].hasVideo)
        let audio = s.trackIndices(of: .audio)
        #expect(audio.count == 1)
        #expect(s.tracks[audio[0]].clips.first?.start == Time(ticks: 600))
        #expect(s.tracks[audio[0]].clips.first?.id != s.tracks[0].clips.first?.id)
    }

    @Test func linkedClipsCutTogetherAndStayLinked() {
        var s = ProjectState(videoTracks: 1, audioTracks: 1)
        s.media = [media]
        let ids = Set(TimelineEditing.place(media, at: .zero, onTrack: 0, in: &s))
        TimelineEditing.link(ids, in: &s)
        #expect(Set(s.allClips.compactMap(\.linkID)).count == 1)

        let right = TimelineEditing.blade(at: Time(seconds: 2), clips: ids, in: &s)
        #expect(right.count == 2)
        let rightLinks = Set(right.compactMap { s.clip($0)?.linkID })
        #expect(rightLinks.count == 1, "right halves are linked to each other")
        #expect(rightLinks != Set(ids.compactMap { s.clip($0)?.linkID }), "and not to the left halves")
        #expect(s.linkedGroup(of: right[0]) == Set(right))

        TimelineEditing.unlink([right[0]], in: &s)
        #expect(right.allSatisfy { s.clip($0)?.linkID == nil })
        #expect(ids.allSatisfy { s.clip($0)?.linkID != nil })
    }

    @Test func movingLinkedGroupChangesTrackOnlyForDraggedKind() {
        var s = ProjectState(videoTracks: 2, audioTracks: 1)
        s.media = [media]
        let ids = Set(TimelineEditing.place(media, at: .zero, onTrack: 0, in: &s))
        TimelineEditing.move(ids, by: Time(seconds: 1), trackChange: .ordinalDelta(1), kind: .video, in: &s)
        for id in ids {
            #expect(s.clip(id)?.start == Time(seconds: 1))
        }
        let video = ids.first { s.track(ofClip: $0)?.kind == .video }!
        let audio = ids.first { s.track(ofClip: $0)?.kind == .audio }!
        #expect(s.trackIndex(ofClip: video) == s.trackIndices(of: .video)[1])
        #expect(s.trackIndex(ofClip: audio) == s.trackIndices(of: .audio)[0])
    }

    @Test func movingToNewTrackCreatesOne() {
        var s = state(clipsAt: [0])
        let id = s.tracks[0].clips[0].id
        let before = s.trackIndices(of: .video).count
        #expect(TimelineEditing.move([id], by: .zero, trackChange: .newTrack, in: &s))
        #expect(s.trackIndices(of: .video).count == before + 1)
        #expect(s.trackIndex(ofClip: id) == s.trackIndices(of: .video).last)
        #expect(s.tracks.last?.name == "V3")
    }

    @Test func lockedClipsCannotBeMovedCutOrOverwritten() {
        var s = state(clipsAt: [0, 5])
        let locked = s.tracks[0].clips[1].id
        let other = s.tracks[0].clips[0].id
        TimelineEditing.setLocked(true, clips: [locked], in: &s)
        let before = s
        TimelineEditing.move([locked], by: Time(seconds: 1), in: &s)
        TimelineEditing.blade(at: Time(seconds: 6), clips: [], in: &s)
        TimelineEditing.delete([locked], in: &s)
        TimelineEditing.setSpeed(2, for: locked, in: &s)
        #expect(s == before)

        // Dropping the other clip over the locked one is refused entirely.
        #expect(!TimelineEditing.move([other], by: Time(seconds: 4), in: &s))
        #expect(s == before)
        var newClip = TimelineEditing.makeClip(for: media, at: Time(seconds: 6), fps: 30)
        newClip.duration = Time(seconds: 1)
        #expect(!TimelineEditing.insert(newClip, onTrack: 0, in: &s))
    }

    @Test func setDurationMovesOutPointWithinLimits() {
        var s = state(clipsAt: [0, 6])
        let id = s.tracks[0].clips[0].id
        TimelineEditing.setDuration(Time(seconds: 2), for: id, in: &s)
        #expect(s.clip(id)?.duration == Time(seconds: 2))
        TimelineEditing.setDuration(Time(seconds: 20), for: id, in: &s)
        #expect(s.clip(id)?.end == Time(seconds: 6), "stops at the next clip")
    }

    @Test func parsesTimecodes() {
        #expect(Timecode.parse("00:00:05:15", fps: 30) == Time(seconds: 5.5))
        #expect(Timecode.parse("1:02:00", fps: 25) == Time(seconds: 62))
        #expect(Timecode.parse("2.5", fps: 30) == Time(seconds: 2.5))
        #expect(Timecode.parse("00:00:01:30", fps: 30) == nil)
        #expect(Timecode.parse("abc", fps: 30) == nil)
    }

    @Test func layoutStacksTracksDownwardWithNewTrackZones() {
        let s = ProjectState(videoTracks: 2, audioTracks: 1)
        let layout = TimelineLayout(pixelsPerSecond: 100, tracks: s.tracks, videoHeight: 60, audioHeight: 40,
                                    spacing: 2, zoneHeight: 20)
        #expect(layout.rows.map { s.tracks[$0.trackIndex].name } == ["V1", "V2", "A1", "T1"])
        let videoZone = layout.zone(for: .video)!
        #expect(layout.target(forY: 10, kind: .video) == .track(0))
        #expect(layout.target(forY: videoZone.y + 5, kind: .video) == .newTrack(.video))
        // An audio clip dragged up into the video area stays on the nearest audio track.
        #expect(layout.target(forY: 10, kind: .audio) == .track(2))
        #expect(layout.dropTarget(forY: videoZone.y + 5) == .newTrack(.video))
    }

    @Test func newProjectsHaveV1A1T1() {
        #expect(ProjectState().tracks.map(\.name) == ["V1", "A1", "T1"])
        #expect(ProjectState().tracks.map(\.kind) == [.video, .audio, .text])
    }

    @Test func mediaCannotGoOnTextTracks() {
        var s = ProjectState()
        s.media = [media]
        let text = s.trackIndices(of: .text)[0]
        #expect(TimelineEditing.place(media, at: .zero, onTrack: text, in: &s).isEmpty)
        #expect(TimelineEditing.place(media, at: .zero, on: .newTrack(.text), in: &s).isEmpty)
        #expect(s.allClips.isEmpty)
    }

    @Test func lookupsAreSafeForDeletedTracks() {
        var s = ProjectState()
        let clip = TimelineEditing.makeClip(for: media, at: .zero, fps: 30)
        s.tracks.remove(at: 2)
        #expect(!s.isTrackActive(5))
        #expect(!s.isClipActive(clip, onTrack: 5))
        #expect(s.ordinal(ofTrack: 5) == 0)
    }

    @Test func versionTwoTextClipsMoveToTextTracks() throws {
        // A v1.9 project: text on V2, no text tracks yet.
        var old = ProjectState(videoTracks: 2, audioTracks: 1, textTracks: 0)
        let text = Clip.text(at: .zero, duration: Time(seconds: 3))
        old.tracks[1].clips = [text]
        old.version = 2
        let migrated = try ProjectState.decode(old.encoded())
        #expect(migrated.version == ProjectState.currentVersion)
        #expect(migrated.tracks[1].clips.isEmpty, "text leaves the video track")
        let textTracks = migrated.trackIndices(of: .text)
        #expect(textTracks.count == 2, "V2's text goes to T2")
        #expect(migrated.trackIndex(ofClip: text.id) == textTracks[1])
    }
}
