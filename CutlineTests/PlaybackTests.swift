import AVFoundation
import Foundation
import Testing
@testable import Cutline

/// Builds real compositions from the sample clips and renders frames through
/// the custom compositor.
struct PlaybackTests {
    static let mediaFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SampleMedia")

    static func media(_ name: String) async throws -> MediaItem {
        try await MediaImporter.makeItem(for: mediaFolder.appendingPathComponent("\(name).mov"))
    }

    @Test func importReadsMetadata() async throws {
        let ocean = try await Self.media("Ocean")
        #expect(ocean.width == 1280 && ocean.height == 720)
        #expect(abs(ocean.duration.seconds - 12) < 0.1)
        #expect(ocean.hasAudio)
    }

    @Test func compositionRendersLayeredFrames() async throws {
        let ocean = try await Self.media("Ocean")
        let sunset = try await Self.media("Sunset")
        var state = ProjectState(settings: .init(name: "T", width: 1920, height: 1080, frameRate: 30), videoTracks: 2, audioTracks: 1)
        state.media = [ocean, sunset]
        TimelineEditing.insert(TimelineEditing.makeClip(for: ocean, at: .zero, fps: 30), onTrack: 0, in: &state)
        var top = TimelineEditing.makeClip(for: sunset, at: Time(seconds: 2), fps: 30)
        top.duration = Time(seconds: 2)
        top.transform.scale = 0.5
        top.crop.left = 0.5
        top.speed = 2
        TimelineEditing.insert(top, onTrack: 1, in: &state)
        // A gap after the ocean clip on V1 (12s..14s is empty) must render black.
        TimelineEditing.insert(TimelineEditing.makeClip(for: sunset, at: Time(seconds: 14), fps: 30), onTrack: 0, in: &state)

        let urls = Dictionary(uniqueKeysWithValues: state.media.map { ($0.id, $0.fileURL) })
        let output: CompositionBuilder.Output
        do { output = try await CompositionBuilder.build(state, urls: urls) } catch { Issue.record("build failed: \(error.localizedDescription)"); throw error }
        #expect(output.duration == Time(seconds: 22))
        #expect(abs(output.composition.duration.seconds - 22) < 0.05)

        let generator = AVAssetImageGenerator(asset: output.composition)
        generator.videoComposition = output.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let frame1: CGImage
        do { (frame1, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) } catch { Issue.record("image failed: \(error)"); throw error }
        #expect(frame1.width == 1920 && frame1.height == 1080)
        let center = try pixel(frame1, x: 960, y: 540)
        #expect(center.b > center.r, "ocean frame should be blue-ish: \(center)")

        // At 3s the half-size sunset clip sits in the middle, the ocean shows at the corner.
        let (frame3, _) = try await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600))
        let middle = try pixel(frame3, x: 960, y: 700)
        let corner = try pixel(frame3, x: 20, y: 20)
        #expect(middle.r > middle.b, "sunset layer should be on top: \(middle)")
        #expect(corner.b > corner.r, "ocean should show around the scaled layer: \(corner)")
        // The left half of the sunset layer is cropped away, revealing the ocean (sampled
        // below the ocean clip's burned-in timecode text).
        let cropped = try pixel(frame3, x: 700, y: 750)
        let kept = try pixel(frame3, x: 1200, y: 540)
        #expect(cropped.b > cropped.r, "cropped area shows the layer below: \(cropped)")
        #expect(kept.r > kept.b, "uncropped part of the layer remains: \(kept)")

        let (gap, _) = try await generator.image(at: CMTime(seconds: 13, preferredTimescale: 600))
        let black = try pixel(gap, x: 960, y: 540)
        #expect(black.r < 10 && black.g < 10 && black.b < 10)
    }

    @Test func playbackControllerPlaysSeeksAndRebuilds() async throws {
        let ocean = try await Self.media("Ocean")
        var state = ProjectState(settings: .default, videoTracks: 1, audioTracks: 1)
        state.media = [ocean]
        TimelineEditing.insert(TimelineEditing.makeClip(for: ocean, at: .zero, fps: 30), onTrack: 0, in: &state)

        let playback = PlaybackController()
        playback.update(with: state, isLiveEdit: false)
        try await waitUntil { playback.duration > .zero }
        #expect(playback.duration == Time(seconds: 12))

        playback.seek(to: Time(seconds: 2))
        #expect(playback.currentTime == Time(seconds: 2))
        try await waitUntil { abs(playback.player.currentTime().seconds - 2) < 0.01 }

        playback.play()
        try await waitUntil { playback.isPlaying }
        // Allow for a busy test machine: the playhead must advance, however long that takes to show.
        let deadline = Date().addingTimeInterval(12)
        while playback.currentTime <= Time(seconds: 2.2), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(playback.currentTime > Time(seconds: 2.2), "playhead advances during playback")
        playback.pause()
        try await waitUntil { !playback.isPlaying }

        // A structural edit rebuilds the composition and keeps the playhead.
        let paused = playback.currentTime
        state.updateClip(state.tracks[0].clips[0].id) { $0.duration = Time(seconds: 5) }
        playback.update(with: state, isLiveEdit: false)
        try await waitUntil { playback.duration == Time(seconds: 5) }
        #expect(playback.currentTime == paused)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline {
                Issue.record("timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test func compositionCarriesPictureOnlyAndCoversAudio() async throws {
        let ocean = try await Self.media("Ocean")
        var state = ProjectState(settings: .default, videoTracks: 1, audioTracks: 1)
        state.media = [ocean]
        TimelineEditing.place(ocean, at: .zero, onTrack: 0, in: &state)
        let audioIndex = state.trackIndices(of: .audio)[0]
        // Push the sound past the end of the picture: playback must still cover it.
        state.updateClip(state.tracks[audioIndex].clips[0].id) { $0.start = Time(seconds: 5) }

        let output = try await CompositionBuilder.build(state, urls: [ocean.id: ocean.fileURL])
        #expect(!output.composition.tracks.contains { $0.mediaType == .audio })
        #expect(abs(output.composition.duration.seconds - 17) < 0.05)
        #expect(output.duration == Time(seconds: 17))
    }

    @Test func voicePlanStartsMidClipAndDelaysLaterClips() {
        var clip = Clip(id: UUID(), mediaID: UUID(), name: "a", start: Time(seconds: 2),
                        duration: Time(seconds: 4), sourceStart: Time(seconds: 1))
        // Starting playback inside the clip skips into the source.
        let inside = AudioVoicePlan.make(for: clip, from: Time(seconds: 3), sampleRate: 1000, fileLength: 100_000)
        #expect(inside == AudioVoicePlan(startFrame: 2000, frameCount: 3000, delayFrames: 0))
        // Starting before it waits; at 2× speed the node consumes source twice as fast.
        clip.speed = 2
        let before = AudioVoicePlan.make(for: clip, from: .zero, sampleRate: 1000, fileLength: 100_000)
        #expect(before == AudioVoicePlan(startFrame: 1000, frameCount: 8000, delayFrames: 4000))
        #expect(AudioVoicePlan.make(for: clip, from: Time(seconds: 7), sampleRate: 1000, fileLength: 100_000) == nil)
    }

    /// Renders the audio tracks offline and returns left/right energy and the
    /// dominant frequency. Frequency is measured with a Schmitt trigger between the
    /// first and last detected cycles, so start-up latency doesn't skew it.
    private func renderAudio(_ state: ProjectState, seconds: Double = 1.5) throws -> (left: Double, right: Double, frequency: Double) {
        let rate = 44_100.0
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let renderer = AudioRenderer(engine: engine)
        renderer.start(state, at: .zero, hostTime: nil)
        defer { renderer.stop(); engine.stop() }

        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var left = 0.0, right = 0.0
        var sampleIndex = 0
        var isHigh = false
        var firstRise: Int?, lastRise = 0, rises = 0
        var remaining = Int(rate * seconds)
        while remaining > 0 {
            let frames = AVAudioFrameCount(min(4096, remaining))
            #expect(try engine.renderOfflineWhenReady(frames, to: buffer) == .success)
            let l = try #require(buffer.floatChannelData?[0]), r = try #require(buffer.floatChannelData?[1])
            for i in 0..<Int(buffer.frameLength) {
                left += Double(l[i] * l[i])
                right += Double(r[i] * r[i])
                let mono = l[i] + r[i]
                if !isHigh && mono > 0.05 {
                    isHigh = true
                    if firstRise == nil { firstRise = sampleIndex }
                    lastRise = sampleIndex
                    rises += 1
                } else if isHigh && mono < -0.05 {
                    isHigh = false
                }
                sampleIndex += 1
            }
            remaining -= Int(frames)
        }
        let span = Double(lastRise - (firstRise ?? lastRise)) / rate
        let frequency = span > 0 ? Double(rises - 1) / span : 0
        return (left, right, frequency)
    }

    private func toneProject(_ adjust: (inout Clip) -> Void = { _ in }) async throws -> ProjectState {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).wav")
        try Self.writeTone(to: url, format: kAudioFormatLinearPCM, seconds: 2)
        let tone = try await MediaImporter.makeItem(for: url)
        _ = await AudioSourceCache.shared.prepare(tone)
        var state = ProjectState(settings: .default, videoTracks: 1, audioTracks: 1)
        state.media = [tone]
        TimelineEditing.place(tone, at: .zero, onTrack: state.trackIndices(of: .audio)[0], in: &state)
        let id = state.tracks[state.trackIndices(of: .audio)[0]].clips[0].id
        state.updateClip(id, adjust)
        return state
    }

    @Test func audioPanPlacesSoundLeftOrRight() async throws {
        let left = try renderAudio(try await toneProject { $0.pan = -1 })
        #expect(left.left > 100 * max(left.right, 1e-9), "hard left: \(left)")
        let right = try renderAudio(try await toneProject { $0.pan = 1 })
        #expect(right.right > 100 * max(right.left, 1e-9), "hard right: \(right)")
        let center = try renderAudio(try await toneProject())
        #expect(abs(center.left - center.right) / center.left < 0.05)
    }

    @Test func audioPitchShiftsBySemitonesAndCents() async throws {
        let base = try renderAudio(try await toneProject()).frequency
        #expect(abs(base - 440) < 5, "unshifted tone is 440 Hz, measured \(base)")
        let octave = try renderAudio(try await toneProject { $0.pitchSemitones = 12 }).frequency
        #expect(abs(octave / 880 - 1) < 0.02, "+12 semitones doubles the frequency: \(octave) Hz")
        let lowered = try renderAudio(try await toneProject { $0.pitchSemitones = -7; $0.pitchCents = -50 }).frequency
        let expected = 440 * pow(2, -7.5 / 12)
        #expect(abs(lowered / expected - 1) < 0.02, "−7 st −50 ct: \(lowered) Hz vs \(expected) Hz")
    }

    @Test func mutedAndUnsoloedTracksAreSilent() async throws {
        var state = try await toneProject()
        let audio = state.trackIndices(of: .audio)[0]
        state.tracks[audio].isMuted = true
        #expect(try renderAudio(state).left < 1e-6)

        state.tracks[audio].isMuted = false
        let other = state.appendTrack(.audio)
        state.tracks[other].isSoloed = true
        #expect(!state.isTrackActive(audio))
        #expect(try renderAudio(state).left < 1e-6, "another audio track is soloed")
        #expect(state.isTrackActive(state.trackIndices(of: .video)[0]), "solo is per kind")
    }

    @Test func clipMuteAndSoloAffectOnlyThoseClips() async throws {
        // Two overlapping tone clips on two audio tracks: one hard left, one hard right.
        var state = try await toneProject { $0.pan = -1 }
        let firstTrack = state.trackIndices(of: .audio)[0]
        let leftClip = state.tracks[firstTrack].clips[0]
        var rightClip = leftClip
        rightClip.id = UUID()
        rightClip.pan = 1
        let secondTrack = state.appendTrack(.audio)
        TimelineEditing.insert(rightClip, onTrack: secondTrack, in: &state)

        let both = try renderAudio(state)
        #expect(both.left > 1 && both.right > 1)

        // Muting one clip silences only that clip; its track stays unmuted.
        state.updateClip(rightClip.id) { $0.isMuted = true }
        let muted = try renderAudio(state)
        #expect(muted.left > 1 && muted.right < 1e-6, "only the muted clip is silent: \(muted)")
        #expect(!state.tracks[secondTrack].isMuted)

        // Soloing one clip silences every other audio clip.
        state.updateClip(rightClip.id) { $0.isMuted = false; $0.isSoloed = true }
        let soloed = try renderAudio(state)
        #expect(soloed.right > 1 && soloed.left < 1e-6, "only the soloed clip plays: \(soloed)")
        #expect(state.isClipActive(state.clip(rightClip.id)!, onTrack: secondTrack))
        #expect(!state.isClipActive(state.clip(leftClip.id)!, onTrack: firstTrack))

        // A muted track still silences a soloed clip on it.
        state.tracks[secondTrack].isMuted = true
        #expect(!state.isClipActive(state.clip(rightClip.id)!, onTrack: secondTrack))
    }

    @Test func compositorFlipsAnimatesAndRotates() async throws {
        let ocean = try await Self.media("Ocean")
        var state = ProjectState(settings: .init(name: "T", width: 1920, height: 1080, frameRate: 30), videoTracks: 1, audioTracks: 0)
        state.media = [ocean]
        var clip = TimelineEditing.makeClip(for: ocean, at: .zero, fps: 30)
        clip.duration = Time(seconds: 10)
        clip.transform.scale = 0.25
        // Moves from the left side of the frame to the right over the clip.
        clip.animation.keyframes[.positionX] = [Keyframe(time: .zero, value: -600),
                                                Keyframe(time: Time(seconds: 10), value: 600)]
        TimelineEditing.insert(clip, onTrack: 0, in: &state)

        func frame(_ seconds: Double, _ state: ProjectState) async throws -> CGImage {
            let output = try await CompositionBuilder.build(state, urls: [ocean.id: ocean.fileURL])
            let generator = AVAssetImageGenerator(asset: output.composition)
            generator.videoComposition = output.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        }
        func isLit(_ image: CGImage, _ x: Int, _ y: Int) throws -> Bool {
            let p = try pixel(image, x: x, y: y)
            return p.r + p.g + p.b > 60
        }

        let early = try await frame(0, state)
        #expect(try isLit(early, 360, 540) && !isLit(early, 1560, 540), "starts on the left")
        let late = try await frame(9.9, state)
        #expect(try !isLit(late, 360, 540) && isLit(late, 1560, 540), "ends on the right")
        let middle = try await frame(5, state)
        #expect(try isLit(middle, 960, 540), "halfway it's centered")

        // Flip: the white bar in the test clip sits near the bottom-left of the source.
        state.updateClip(clip.id) { $0.transform = ClipTransform(); $0.animation = ClipAnimation() }
        let normal = try await frame(0.05, state)
        state.updateClip(clip.id) { $0.transform.flipVertical = true }
        let flipped = try await frame(0.05, state)
        let barNormal = try pixel(normal, x: 100, y: 1080 - 150)
        let barFlipped = try pixel(flipped, x: 100, y: 150)
        #expect(barNormal.r > 200 && barFlipped.r > 200, "bar moves to the top when flipped vertically: \(barNormal) \(barFlipped)")

        // Strong yaw narrows the picture, so the frame edge turns black.
        state.updateClip(clip.id) { $0.transform = ClipTransform(); $0.transform.yaw = 60 }
        let yawed = try await frame(1, state)
        #expect(try !isLit(yawed, 40, 540) && isLit(yawed, 960, 540))

        // A hidden clip shows nothing.
        state.updateClip(clip.id) { $0.isMuted = true }
        let hiddenClip = try await frame(1, state)
        #expect(try !isLit(hiddenClip, 960, 540))

        // A hidden video track shows nothing.
        state.updateClip(clip.id) { $0.isMuted = false }
        state.tracks[0].isMuted = true
        let hidden = try await frame(1, state)
        #expect(try !isLit(hidden, 960, 540))
    }

    @Test func scrubbingPlaysAShortGrainOfAudibleTracks() async throws {
        var state = try await toneProject { $0.pan = 1 }
        func renderScrub(_ state: ProjectState) throws -> (left: Double, right: Double) {
            let engine = AVAudioEngine()
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            let renderer = AudioRenderer(engine: engine)
            renderer.scrub(state, at: Time(seconds: 0.5))
            defer { renderer.stopScrubbing(); engine.stop() }
            var left = 0.0, right = 0.0
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
            for _ in 0..<3 {
                _ = try engine.renderOfflineWhenReady(4096, to: buffer)
                let l = try #require(buffer.floatChannelData?[0]), r = try #require(buffer.floatChannelData?[1])
                for i in 0..<Int(buffer.frameLength) {
                    left += Double(l[i] * l[i])
                    right += Double(r[i] * r[i])
                }
            }
            return (left, right)
        }
        let grain = try renderScrub(state)
        #expect(grain.right > 1, "scrubbing is audible: \(grain)")
        #expect(grain.right > 100 * max(grain.left, 1e-9), "and keeps the clip's pan")

        state.tracks[state.trackIndices(of: .audio)[0]].isMuted = true
        #expect(try renderScrub(state).right < 1e-6, "muted tracks stay silent while scrubbing")
    }

    @Test(arguments: [1.0, 0.5, 2.0])
    func scrubbingKeepsNormalPitchAtAnyDragSpeed(dragSpeed: Double) async throws {
        let state = try await toneProject()
        let rate = 44_100.0
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let renderer = AudioRenderer(engine: engine)
        defer { renderer.stopScrubbing(); engine.stop() }
        // Mouse updates arrive about every 16 ms.
        let block = AVAudioFrameCount(rate * 0.016)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block))
        var samples: [Float] = []
        for k in 0..<40 {
            renderer.scrub(state, at: Time(seconds: 0.2 + Double(k) * 0.016 * dragSpeed))
            _ = try engine.renderOfflineWhenReady(block, to: buffer)
            let left = try #require(buffer.floatChannelData?[0])
            samples += UnsafeBufferPointer(start: left, count: Int(buffer.frameLength))
        }
        let steady: [Float] = Array(samples.dropFirst(Int(block) * 5))
        var rises = 0, high = false, first: Int?, last = 0
        for (i, x) in steady.enumerated() {
            if !high && x > 0.05 { high = true; rises += 1; first = first ?? i; last = i }
            else if high && x < -0.05 { high = false }
        }
        let frequency = Double(rises - 1) / (Double(last - (first ?? last)) / rate)
        // Pitch never bends: no swoops however fast or slowly the playhead moves.
        #expect(abs(frequency - 440) < 12, "dragging at \(dragSpeed)×: \(frequency) Hz")
    }

    @Test func scrubbingAtNormalSpeedSoundsCleanAndStopsWhenStill() async throws {
        let state = try await toneProject()
        let rate = 44_100.0
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let renderer = AudioRenderer(engine: engine)
        defer { renderer.stopScrubbing(); engine.stop() }
        let block = AVAudioFrameCount(rate / 100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block))

        // Drag the playhead forward at real-time speed: 10 ms of timeline per 10 ms.
        var samples: [Float] = []
        for k in 0..<80 {
            renderer.scrub(state, at: Time(seconds: 0.3 + Double(k) * 0.01))
            _ = try engine.renderOfflineWhenReady(block, to: buffer)
            let left = try #require(buffer.floatChannelData?[0])
            samples += UnsafeBufferPointer(start: left, count: Int(buffer.frameLength))
        }
        let warmup = Int(block) * 20
        let steady: [Float] = Array(samples.dropFirst(warmup))

        // Same pitch as normal playback (no muffling or pitch wobble).
        var rises = 0, high = false, first: Int?, last = 0
        for (i, x) in steady.enumerated() {
            if !high && x > 0.05 { high = true; rises += 1; first = first ?? i; last = i }
            else if high && x < -0.05 { high = false }
        }
        let frequency = Double(rises - 1) / (Double(last - (first ?? last)) / rate)
        #expect(abs(frequency - 440) < 10, "scrubbing at normal speed plays the tone at its pitch: \(frequency) Hz")

        // Steady level: no flutter from overlapping or chopped-up pieces.
        let size = Int(block)
        var levels: [Float] = []
        for start in stride(from: 0, to: steady.count - size, by: size) {
            var sum: Float = 0
            for x in steady[start..<start + size] { sum += x * x }
            levels.append((sum / Float(size)).squareRoot())
        }
        let ratio = (levels.min() ?? 0) / max(levels.max() ?? 1, 1e-9)
        #expect(ratio > 0.85, "level stays steady while dragging: min/max \(ratio)")
        let jump = zip(steady, steady.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(jump < 0.06, "no clicks: largest sample jump \(jump)")

        // Holding the playhead still fades to silence.
        var tail: [Float] = []
        for _ in 0..<30 {
            _ = try engine.renderOfflineWhenReady(block, to: buffer)
            let left = try #require(buffer.floatChannelData?[0])
            tail += UnsafeBufferPointer(start: left, count: Int(buffer.frameLength))
        }
        let quiet = tail.suffix(Int(block) * 10).map { abs($0) }.max() ?? 1
        #expect(quiet < 1e-3, "silent when the playhead is still: \(quiet)")
    }

    @Test func spaceTogglesPlayAndPauseImmediately() async throws {
        let ocean = try await Self.media("Ocean")
        var state = ProjectState(settings: .default, videoTracks: 1, audioTracks: 1)
        state.media = [ocean]
        TimelineEditing.place(ocean, at: .zero, onTrack: 0, in: &state)
        let playback = PlaybackController()
        playback.update(with: state, isLiveEdit: false)
        try await waitUntil { playback.duration > .zero }

        playback.togglePlayback()
        #expect(playback.isPlaying, "playing state is set right away")
        try await Task.sleep(for: .milliseconds(300))
        playback.togglePlayback()
        #expect(!playback.isPlaying)
        try await Task.sleep(for: .milliseconds(100))
        #expect(playback.player.rate == 0, "the second press pauses instead of restarting")
        #expect(!playback.audio.isPlaying)
        playback.togglePlayback()
        #expect(playback.isPlaying)
        playback.pause()
    }

    @Test func dropPreviewExpiresWhenUpdatesStop() async throws {
        let editor = EditorController(store: ProjectStore())
        editor.showDropPreview(DropPreview(target: .track(0), time: .zero))
        #expect(editor.dropPreview != nil)
        try await Task.sleep(for: .milliseconds(300))
        editor.showDropPreview(DropPreview(target: .track(0), time: Time(seconds: 1)))
        try await Task.sleep(for: .milliseconds(400))
        #expect(editor.dropPreview != nil, "refreshed updates keep it alive")
        // It expires on its own (allowing for a busy test machine).
        let deadline = Date().addingTimeInterval(6)
        while editor.dropPreview != nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(editor.dropPreview == nil, "a drag that ended elsewhere leaves no ghost behind")
    }

    @Test func trackHeightsDriveLayout() {
        var state = ProjectState(videoTracks: 1, audioTracks: 1)
        state.tracks[0].height = 120
        let layout = TimelineLayout(pixelsPerSecond: 10, tracks: state.tracks, videoHeight: 64, audioHeight: 48,
                                    spacing: 2, zoneHeight: 20)
        #expect(layout.row(forTrack: 0)?.height == 120)
        #expect(abs((layout.row(forTrack: 1)?.y ?? 0) - 144) < 0.001)
    }

    @Test(arguments: [
        ("wav", kAudioFormatLinearPCM),
        ("aiff", kAudioFormatLinearPCM),
        ("caf", kAudioFormatAppleLossless),
        ("m4a", kAudioFormatMPEG4AAC),
        ("flac", kAudioFormatFLAC),
    ])
    func importsAudioFormats(fileExtension: String, format: AudioFormatID) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tone-\(UUID()).\(fileExtension)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeTone(to: url, format: format, seconds: 1.5)

        let item = try await MediaImporter.makeItem(for: url)
        #expect(!item.hasVideo && item.hasAudio)
        #expect(abs(item.duration.seconds - 1.5) < 0.1)

        let peaks = try await waitForPeaks(item)
        #expect(abs(Double(peaks.count) - 150) < 10)
        #expect(peaks.max() == 1)
    }

    private func waitForPeaks(_ item: MediaItem) async throws -> [Float] {
        var peaks: [Float]?
        try await waitUntil {
            peaks = WaveformCache.shared.peaks(for: item, url: item.fileURL)
            return peaks != nil
        }
        return peaks ?? []
    }

    static func writeTone(to url: URL, format: AudioFormatID, seconds: Double) throws {
        let rate = 44100.0
        var settings: [String: Any] = [AVFormatIDKey: format, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1]
        if format == kAudioFormatLinearPCM {
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = url.pathExtension == "aiff"
        }
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(frames) { channel[i] = Float(sin(2 * .pi * 440 * Double(i) / rate) * 0.5) }
        try file.write(from: buffer)
    }

    @Test func appearanceOnlyChangesKeepTimingSignature() {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "m", path: "/m.mov", duration: Time(seconds: 5), width: 10, height: 10, frameRate: 30, hasAudio: false)
        state.media = [media]
        let clip = TimelineEditing.makeClip(for: media, at: .zero, fps: 30)
        TimelineEditing.insert(clip, onTrack: 0, in: &state)
        let before = TimingSignature(state)
        state.updateClip(clip.id) { $0.opacity = 0.3; $0.color.saturation = 0 }
        #expect(TimingSignature(state) == before)
        state.updateClip(clip.id) { $0.start = Time(seconds: 1) }
        #expect(TimingSignature(state) != before)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]))
    }
}

extension AVAudioEngine {
    /// Offline rendering, waiting while the players haven't read ahead yet (a busy Mac).
    func renderOfflineWhenReady(_ frames: AVAudioFrameCount, to buffer: AVAudioPCMBuffer) throws -> AVAudioEngineManualRenderingStatus {
        var status = try renderOffline(frames, to: buffer)
        var retries = 0
        while status == .cannotDoInCurrentContext && retries < 5_000 {
            Thread.sleep(forTimeInterval: 0.002)
            status = try renderOffline(frames, to: buffer)
            retries += 1
        }
        return status
    }
}
