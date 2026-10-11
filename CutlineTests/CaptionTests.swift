import AVFoundation
import Foundation
import Testing
@testable import Cutline

/// Speech for tests, spoken by macOS's built-in voice into a file.
enum SpeechKit {
    static func speak(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID()).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path))
        return url
    }

    /// Lowercased words without punctuation, for comparing what was heard.
    static func plain(_ words: [TranscriptWord]) -> [String] {
        words.map { $0.text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }.filter { !$0.isEmpty }
    }
}

@MainActor struct TranscriptionTests {
    @Test func speechBecomesTimedWords() async throws {
        // 1.5 s of silence, then the sentence.
        let url = try SpeechKit.speak("[[slnc 1500]] So this is the final boss and I have no idea what I'm doing.")
        let (state, _) = try await AudioTestKit.project([url])
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        editor.store.undoManager = undo
        editor.transcribe(locale: Locale(identifier: "en_US"))
        #expect(editor.isTranscribing)
        await editor.waitForTranscription()
        #expect(editor.transcriptionMessage == nil, "\(editor.transcriptionMessage ?? "")")

        let media = try #require(state.media.first)
        let transcript = try #require(editor.state.transcripts[media.id])
        let heard = SpeechKit.plain(transcript.words)
        #expect(heard == ["so", "this", "is", "the", "final", "boss", "and", "i", "have", "no", "idea", "what", "i'm", "doing"], "\(heard)")
        // Timed in the media's own time: the first word after the silence, all in order.
        let first = try #require(transcript.words.first)
        #expect(first.start > 1.3 && first.start < 1.9, "first word at \(first.start) s")
        for (a, b) in zip(transcript.words, transcript.words.dropFirst()) { #expect(a.start <= b.start && a.end <= b.end + 0.01) }
        #expect(transcript.words.allSatisfy { $0.end > $0.start && $0.end <= media.duration.seconds + 0.05 })

        // One undo step; saved and loaded as is.
        #expect(undo.undoActionName == "Transcribe \(media.name)")
        #expect(try ProjectState.decode(editor.state.encoded()) == editor.state)
        undo.undo()
        #expect(editor.state.transcripts.isEmpty)

        // Again: straight from the disk cache, the same words.
        let clock = ContinuousClock()
        let start = clock.now
        editor.transcribe(locale: Locale(identifier: "en_US"))
        await editor.waitForTranscription()
        #expect(clock.now - start < .seconds(2), "cached")
        #expect(SpeechKit.plain(editor.state.transcripts[media.id]?.words ?? []) == heard)
    }

    @Test func projectsWithoutTranscriptsLoad() throws {
        var json = try #require(try JSONSerialization.jsonObject(with: ProjectState().encoded()) as? [String: Any])
        json["transcripts"] = nil
        let state = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        #expect(state.transcripts.isEmpty)
    }

    @Test func nothingToTranscribeSaysSo() {
        let editor = EditorController(store: ProjectStore(state: ProjectState()))
        editor.transcribe()
        #expect(!editor.isTranscribing && editor.transcriptionMessage != nil)
    }
}

@MainActor struct CaptionTrackTests {
    /// Words "w0 … wN" every 0.4 s (0.3 s long) in the media's own time, with a long pause
    /// before word 10, and word 5 ending a sentence.
    private func project() -> (EditorController, UndoManager, Clip, UUID) {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "talk", path: "/talk.wav", duration: Time(seconds: 60), width: 0, height: 0,
                              frameRate: 0, hasAudio: true)
        state.media = [media]
        var words: [TranscriptWord] = []
        var t = 1.0
        for k in 0..<16 {
            if k == 10 { t += 1.5 }
            words.append(TranscriptWord(text: k == 5 ? "w\(k)." : "w\(k)", start: t, end: t + 0.3))
            t += 0.4
        }
        state.transcripts[media.id] = Transcript(mediaID: media.id, locale: "en_US", words: words)
        let clip = Clip(id: UUID(), mediaID: media.id, name: "talk", start: Time(seconds: 10), duration: Time(seconds: 20), sourceStart: .zero)
        state.tracks[state.trackIndices(of: .audio)[0]].clips = [clip]
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        undo.beginUndoGrouping()
        let track = editor.addCaptionTrack()!
        undo.endUndoGrouping()
        return (editor, undo, clip, track)
    }

    private func captions(_ editor: EditorController) -> [Caption] {
        editor.state.captions(onTrack: editor.captionTrackIndices[0])
    }

    private func texts(_ editor: EditorController) -> [String] { captions(editor).map(\.text) }

    @Test func wordsGroupIntoCaptions() throws {
        let (editor, undo, _, track) = project()
        // Default: up to 6 words, a new caption after a sentence and after the long pause.
        #expect(texts(editor) == ["w0 w1 w2 w3 w4 w5.", "w6 w7 w8 w9", "w10 w11 w12 w13 w14 w15"])
        let first = try #require(captions(editor).first)
        #expect(first.start == Time(seconds: 11), "the clip starts at 10 s, the word at 1 s of the media")
        for (a, b) in zip(captions(editor), captions(editor).dropFirst()) { #expect(a.end <= b.start, "never overlap") }

        // Fewer words per caption; a caption that would run too long splits.
        undo.beginUndoGrouping(); editor.adjustCaptions(track, actionName: "Words") { $0.maxWords = 3 }; undo.endUndoGrouping()
        #expect(texts(editor) == ["w0 w1 w2", "w3 w4 w5.", "w6 w7 w8", "w9", "w10 w11 w12", "w13 w14 w15"])
        undo.beginUndoGrouping(); editor.adjustCaptions(track, actionName: "Length") { $0.maxWords = 20; $0.maxDuration = 1.0; $0.splitsSentences = false }; undo.endUndoGrouping()
        #expect(captions(editor).allSatisfy { $0.words.last!.end - $0.words.first!.start <= Time(seconds: 1.0) })
        // Undo walks back each settings change.
        undo.undo(); undo.undo()
        #expect(texts(editor).count == 3)
        undo.undo()
        #expect(editor.captionTrackIndices.isEmpty, "adding the track is its own step")
    }

    @Test func transcriptEditsShapeTheCaptions() {
        let (editor, _, clip, _) = project()
        editor.store.edit("Edit") { state in
            state.transcripts[clip.mediaID]!.words[2].text = "BOSS"
            state.transcripts[clip.mediaID]!.words[3].isHidden = true
            state.transcripts[clip.mediaID]!.words[8].startsCaption = true
        }
        #expect(texts(editor) == ["w0 w1 BOSS w4 w5.", "w6 w7", "w8 w9", "w10 w11 w12 w13 w14 w15"])
    }

    @Test func captionsFollowTheirAudioThroughEdits() throws {
        let (editor, _, clip, _) = project()
        let before = captions(editor)
        let audio = AudioTestKit.audioTrack(editor.state)

        // Moving the clip moves its captions.
        editor.store.edit("Move") { $0.updateClip(clip.id) { $0.start = $0.start + Time(seconds: 5) } }
        #expect(zip(before, captions(editor)).allSatisfy { $1.start == $0.start + Time(seconds: 5) })

        // Trimming the start drops the words before the new in-point.
        editor.store.edit("Trim") { state in
            TimelineEditing.trim(clip.id, edge: .leading, to: Time(seconds: 15 + 3), in: &state)
        }
        #expect(captions(editor).first?.words.first?.text == "w5.", "\(texts(editor))")

        // Cutting keeps every word, on either side of the cut.
        editor.store.edit("Cut") { state in
            let c = state.tracks[audio].clips[0]
            state.tracks[audio].clips[0].duration = Time(seconds: 4)
            var right = c
            right.id = UUID()
            right.start = c.start + Time(seconds: 4)
            right.sourceStart = c.sourceTime(at: right.start)
            right.duration = c.duration - Time(seconds: 4)
            state.tracks[audio].clips.append(right)
        }
        #expect(captions(editor).flatMap(\.words).map(\.text) == ["w5.", "w6", "w7", "w8", "w9", "w10", "w11", "w12", "w13", "w14", "w15"])

        // At double speed words come twice as fast, through the same curve as the sound.
        editor.store.edit("Speed") { state in
            state.tracks[audio].clips = [clip]
            TimelineEditing.setSpeed(2, for: clip.id, in: &state)
        }
        let fast = try #require(captions(editor).first?.words.first)
        #expect(fast.start == Time(seconds: 10.5) && fast.end == Time(seconds: 10.65), "\(fast.start.seconds)")
        // And a ramp places each word where its sound plays.
        editor.store.edit("Ramp") { state in
            state.updateClip(clip.id) { c in
                c.animation.keyframes[.speed] = [Keyframe(time: .zero, value: 1), Keyframe(time: Time(seconds: 5), value: 2)]
            }
        }
        let ramped = try #require(editor.state.clip(clip.id))
        for word in captions(editor).flatMap(\.words).prefix(6) {
            let source = editor.state.transcripts[clip.mediaID]!.words.first { $0.id == word.wordID }!.start
            // Timeline times are whole ticks: within one tick of source at up to 2× speed.
            #expect(abs(ramped.sourceTime(at: word.start).seconds - source) <= 2.0 / Double(Time.ticksPerSecond) + 1e-9,
                    "\(word.text): at \(word.start.seconds) plays \(ramped.sourceTime(at: word.start).seconds), word at \(source); clip \(ramped.start.seconds) +\(ramped.duration.seconds) src \(ramped.sourceStart.seconds) speed \(ramped.speed) frames \(ramped.animation.keyframes(for: .speed).map { ($0.time.seconds, $0.value) })")
        }

        // Muted audio has no captions; a caption track can caption chosen tracks only.
        editor.store.edit("Mute") { $0.tracks[audio].isMuted = true }
        #expect(captions(editor).isEmpty)
        editor.store.edit("Unmute") { $0.tracks[audio].isMuted = false }
        let track = editor.state.tracks[editor.captionTrackIndices[0]].id
        editor.adjustCaptions(track, actionName: "Source") { $0.sourceTrackIDs = [UUID()] }
        #expect(captions(editor).isEmpty)
    }

    @Test func captionTracksSaveAndOldProjectsLoad() throws {
        let (editor, _, _, track) = project()
        editor.adjustCaptions(track, actionName: "Style") { $0.style.size = 80; $0.style.highlightsWord = true; $0.maxWords = 4 }
        let loaded = try ProjectState.decode(editor.state.encoded())
        #expect(loaded == editor.state)
        #expect(loaded.tracks.first { $0.id == track }?.kind == .caption)
        // A caption track saved without settings gets the defaults.
        var json = try #require(try JSONSerialization.jsonObject(with: editor.state.encoded()) as? [String: Any])
        var tracks = try #require(json["tracks"] as? [[String: Any]])
        let k = try #require(tracks.firstIndex { $0["kind"] as? String == "caption" })
        tracks[k]["captions"] = nil
        json["tracks"] = tracks
        let bare = try ProjectState.decode(JSONSerialization.data(withJSONObject: json))
        #expect(bare.tracks[k].captions == CaptionSettings())
        // Layout: caption rows come last, with no drop zone of their own.
        let layout = TimelineLayout(pixelsPerSecond: 50, tracks: editor.state.tracks)
        #expect(layout.rows.last?.kind == .caption && !layout.zones.contains { $0.kind == .caption })
        #expect(!TrackKind.caption.holdsClips && !TrackKind.caption.isVisual)
    }
}
