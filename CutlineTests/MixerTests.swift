import AVFoundation
import Foundation
import Testing
@testable import Cutline

@MainActor struct MixerTests {
    @Test func theFaderScaleReadsLikeAConsole() {
        #expect(abs(FaderScale.position(forDB: 0) - 0.76) < 1e-9, "0 dB three quarters up")
        #expect(FaderScale.position(forDB: 12) == 1 && FaderScale.position(forDB: -200) == 0)
        for db in stride(from: -90.0, through: 12, by: 1.5) {
            #expect(abs(FaderScale.db(forPosition: FaderScale.position(forDB: db)) - db) < 1e-9)
        }
        let positions = stride(from: -96.0, through: 12, by: 0.5).map(FaderScale.position)
        #expect(positions == positions.sorted(), "higher level, higher cap")
        #expect(FaderScale.label(0) == "0.0" && FaderScale.label(-6.04) == "−6.0" && FaderScale.label(3) == "+3.0")
        #expect(FaderScale.label(-96) == "−∞")
        #expect(PanControl.label(0) == "C" && PanControl.label(-0.3) == "L30" && PanControl.label(1) == "R100")
    }

    @Test func metersRiseAtOnceFallSmoothlyAndHoldPeaks() {
        var meter = MeterBallistics()
        meter.update(peak: 0.5, sawClip: false, elapsed: 1.0 / 30)
        #expect(abs(meter.level - -6.0206) < 1e-3, "jumps straight to a new peak")
        meter.update(peak: 0, sawClip: false, elapsed: 0.5)
        #expect(abs(meter.level - (-6.0206 - 12)) < 1e-3, "falls 24 dB per second")
        #expect(abs(meter.peakHold - -6.0206) < 1e-3, "the peak is held for a moment")
        meter.update(peak: 0, sawClip: false, elapsed: 1.2)
        #expect(meter.peakHold < -20, "and then lets go")
        meter.update(peak: 1.2, sawClip: true, elapsed: 0.1)
        #expect(meter.clipped)
        for _ in 0..<100 { meter.update(peak: 0, sawClip: false, elapsed: 0.1) }
        #expect(meter.clipped && meter.level == MeterBallistics.floorDB, "the clip light stays until cleared")
    }

    @Test func aFaderDragIsOneUndoStep() {
        var state = ProjectState()
        let a1 = state.trackIndices(of: .audio)[0]
        state.tracks[a1].audio.volumeDB = -2
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        let id = state.tracks[a1].id

        // Each gesture is one event, as in the app.
        func grouped(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        grouped {
            for db in stride(from: -2.0, through: -18, by: -1) { editor.adjustTrackAudio(.volume, to: db, track: id) }
            editor.endAudioAdjustment("Change Volume")
        }
        #expect(editor.state.tracks[a1].audio.volumeDB == -18)
        #expect(undo.undoActionName == "Change Volume")
        undo.undo()
        #expect(editor.state.tracks[a1].audio.volumeDB == -2, "the whole drag undoes at once")
        undo.redo()
        #expect(editor.state.tracks[a1].audio.volumeDB == -18)

        // Double-click: back to 0 dB, centered, each one step.
        grouped {
            editor.adjustTrackAudio(.pan, to: 0.7, track: id)
            editor.endAudioAdjustment("Change Pan")
        }
        grouped { editor.resetTrackAudio(.volume, track: id) }
        grouped { editor.resetTrackAudio(.pan, track: id) }
        #expect(editor.state.tracks[a1].audio.volumeDB == 0 && editor.state.tracks[a1].audio.pan == 0)
        undo.undo()
        #expect(editor.state.tracks[a1].audio.pan == 0.7)

        // Out-of-range values are clamped; the master works the same way.
        grouped {
            editor.adjustTrackAudio(.volume, to: 40, track: id)
            editor.endAudioAdjustment("Change Volume")
        }
        #expect(editor.state.tracks[a1].audio.volumeDB == AudioParameter.volume.range.upperBound)
        grouped {
            editor.adjustMasterVolume(to: -4)
            editor.adjustMasterVolume(to: -5)
            editor.endAudioAdjustment("Change Master Volume")
        }
        #expect(editor.state.audio.master.volumeDB == -5)
        undo.undo()
        #expect(editor.state.audio.master.volumeDB == 0)
    }

    @Test func anAnimatedFaderSetsAKeyframeAtThePlayhead() async throws {
        var state = ProjectState()
        let a1 = state.trackIndices(of: .audio)[0]
        state.tracks[a1].audio.keyframes["volume"] = [Keyframe(time: .zero, value: 0)]
        let editor = EditorController(store: ProjectStore(state: state))
        editor.playback.seek(to: Time(seconds: 2))
        editor.adjustTrackAudio(.volume, to: -9, track: state.tracks[a1].id)
        editor.endAudioAdjustment("Change Volume")
        let frames = try #require(editor.state.tracks[a1].audio.keyframes["volume"])
        #expect(frames.map(\.value) == [0, -9] && frames.last?.time == Time(seconds: 2))
        #expect(editor.state.tracks[a1].audio.volumeDB == 0, "the plain value is untouched")
        #expect(editor.trackAudioValue(.volume, track: state.tracks[a1].id) == -9)
    }

    /// The meters read what the graph actually played: a −6 dBFS tone reads −6 dB, a
    /// boosted one lights the clip light, and nothing is published while idle.
    @Test func metersShowWhatTheGraphPlays() async throws {
        var (state, sources) = try await AudioTestKit.project([try AudioTestKit.tone(amplitude: 0.5)], audioTracks: 2)
        let a1 = AudioTestKit.audioTrack(state), a2 = AudioTestKit.audioTrack(state, 1)
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: AudioGraphFormat.format, maximumFrameCount: 4096)
        let graph = AudioGraph(engine: engine)
        graph.prepareVoices(state, from: .zero) { sources[$0.id] }
        try engine.start()
        graph.start(at: .zero, hostTime: nil)
        let meters = MixerMeters(graph: graph)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        _ = try engine.renderOfflineWhenReady(4096, to: buffer)
        meters.tick()
        let voice = try #require(meters.tracks[state.tracks[a1].id])
        #expect(abs(voice.left.level - -6.02) < 0.1, "\(voice.left.level)")
        #expect(meters.tracks[state.tracks[a2].id]?.left.level == MeterBallistics.floorDB, "the empty track shows nothing")
        #expect(abs(meters.master.left.level - -6.02) < 0.1)
        #expect(!voice.left.clipped)

        state.updateClip(AudioTestKit.firstClip(state).id) { $0.gainDB = 12 }
        graph.update(state)
        _ = try engine.renderOfflineWhenReady(4096, to: buffer)
        meters.tick()
        #expect(meters.master.left.clipped, "a signal over full scale lights the clip light")
        meters.resetClip(track: nil)
        #expect(!meters.master.left.clipped)
        graph.removeVoices()
        engine.stop()

        // Silent and settled: further reads change nothing, so the views don't redraw.
        for _ in 0..<200 { meters.tick() }
        let settled = meters.tracks
        meters.tick()
        #expect(meters.tracks == settled)
    }
}
