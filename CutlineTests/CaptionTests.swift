import AVFoundation
import Foundation
import SwiftUI
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

        // Again: straight from the disk cache (it's there), the same words.
        #expect(Transcriber.cached(media.resolveURL(), mediaID: media.id, locale: Locale(identifier: "en_US")) != nil, "cached on disk")
        editor.transcribe(locale: Locale(identifier: "en_US"))
        await editor.waitForTranscription()
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
        // Split evenly: 4 words at 3 per caption make 2 + 2, not 3 + 1.
        #expect(texts(editor) == ["w0 w1 w2", "w3 w4 w5.", "w6 w7", "w8 w9", "w10 w11 w12", "w13 w14 w15"])
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

@MainActor struct TranscriptEditingTests {
    /// "one two three four. five six" then, after a pause, "seven eight", every 0.5 s from 1 s.
    private func project() -> (EditorController, UndoManager, UUID) {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "talk", path: "/talk.wav", duration: Time(seconds: 30), width: 0, height: 0,
                              frameRate: 0, hasAudio: true)
        state.media = [media]
        let texts = ["one", "two", "three", "four.", "five", "six", "seven", "eight"]
        var t = 1.0
        let words = texts.enumerated().map { k, text -> TranscriptWord in
            if k == 6 { t += 2 }
            defer { t += 0.5 }
            return TranscriptWord(text: text, start: t, end: t + 0.4)
        }
        state.transcripts[media.id] = Transcript(mediaID: media.id, locale: "en_US", words: words)
        state.tracks[state.trackIndices(of: .audio)[0]].clips = [Clip(id: UUID(), mediaID: media.id, name: "talk", start: .zero,
                                                                      duration: Time(seconds: 20), sourceStart: .zero)]
        state.appendCaptionTrack()
        let editor = EditorController(store: ProjectStore(state: state))
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.store.undoManager = undo
        return (editor, undo, media.id)
    }

    private func texts(_ editor: EditorController) -> [String] { editor.currentCaptions.map(\.text) }

    private func step(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping(); body(); undo.endUndoGrouping()
    }

    @Test func editingWordsAndCaptions() throws {
        let (editor, undo, mediaID) = project()
        #expect(texts(editor) == ["one two three four.", "five six", "seven eight"])
        let words = editor.currentCaptions.flatMap(\.words)

        step(undo) { editor.editWord(words[1], to: "TWO") }
        step(undo) { editor.setWordHidden(words[2], true) }
        #expect(texts(editor)[0] == "one TWO four.")
        #expect(editor.state.transcripts[mediaID]!.words[2].isHidden, "hidden, not deleted")

        step(undo) { editor.splitCaption(at: words[5]) }
        #expect(texts(editor) == ["one TWO four.", "five", "six", "seven eight"])
        step(undo) { editor.mergeWithPrevious(editor.currentCaptions[3]) }
        #expect(texts(editor) == ["one TWO four.", "five", "six seven eight"], "merged across the pause")

        // Same number of words: each keeps its timing.
        let last = editor.currentCaptions[2]
        step(undo) { editor.editCaption(last, to: "Six Seven Eight!") }
        #expect(texts(editor)[2] == "Six Seven Eight!")
        #expect(editor.currentCaptions[2].words.map(\.start) == last.words.map(\.start))
        // A different number: spread over the same span.
        let first = editor.currentCaptions[0]
        step(undo) { editor.editCaption(first, to: "Hello there") }
        let retyped = editor.currentCaptions[0]
        #expect(retyped.text == "Hello there")
        #expect(retyped.words.first?.start == first.words.first?.start && retyped.words.last?.end == first.words.last?.end)

        // Each change is one undo step, all the way back.
        for _ in 0..<6 { undo.undo() }
        #expect(texts(editor) == ["one two three four.", "five six", "seven eight"])
        #expect(try ProjectState.decode(editor.state.encoded()) == editor.state)
    }

    @Test func thePlayheadFindsItsCaptionAndWord() throws {
        let (editor, _, _) = project()
        let captions = editor.currentCaptions
        let at = try #require(editor.captionPosition(in: captions, at: Time(seconds: 2.1)))
        #expect(at.caption.text == "one two three four." && at.word?.text == "three")
        #expect(editor.captionPosition(in: captions, at: Time(seconds: 0.5)) == nil, "before the first word")
        #expect(editor.captionPosition(in: captions, at: Time(seconds: 30)) == nil)
    }

    @Test func theCaptionsTabSitsBetweenAudioAndPlayground() {
        #expect(Workspace.allCases == [.edit, .effects, .color, .audio, .captions, .playground, .export])
        #expect(Workspace.allCases.firstIndex(of: .captions) == 4, "⌘5")
        let editor = EditorController(store: ProjectStore(state: ProjectState()))
        editor.transcribeForCaptions()
        #expect(editor.captionTrackIndices.count == 1, "transcribing from the tab makes a caption track")
    }

    @Test func theTranscriptPanelDraws() throws {
        let (editor, _, _) = project()
        editor.playback.seek(to: Time(seconds: 2.1))
        let renderer = ImageRenderer(content: TranscriptPanel(editor: editor).frame(width: 400, height: 300)
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == 400 && image.height == 300)
    }
}

@MainActor struct CaptionRenderingTests {
    /// A 4 s tone on A1, its "transcript" two captions: "hello there" (0.5–1.5 s) and
    /// "general kenobi" (2–3 s), a caption track over it.
    private func project(_ style: CaptionStyle = CaptionPreset.boldCenter.style) async throws -> (ProjectState, [UUID: URL]) {
        let url = try AudioTestKit.tone(seconds: 4, amplitude: 0.1, sameInBoth: true)
        var (state, _) = try await AudioTestKit.project([url])
        let media = try #require(state.media.first)
        state.transcripts[media.id] = Transcript(mediaID: media.id, locale: "en_US", words: [
            TranscriptWord(text: "hello", start: 0.5, end: 0.9), TranscriptWord(text: "there.", start: 1.0, end: 1.5),
            TranscriptWord(text: "general", start: 2.0, end: 2.5), TranscriptWord(text: "kenobi", start: 2.5, end: 3.0),
        ])
        let index = state.appendCaptionTrack()
        state.tracks[index].captions?.style = style
        state.tracks[index].captions?.minDuration = 0
        return (state, [media.id: url])
    }

    /// Bright pixels (text) and highlight-colored pixels in a frame.
    private func count(_ image: CGImage) throws -> (bright: Int, yellow: Int) {
        var bright = 0, yellow = 0
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let p = try TextRenderTests.pixel(image, x: x, y: y)
                if p.r > 200 && p.g > 200 && p.b > 200 { bright += 1 }
                if p.r > 200 && p.g > 150 && p.b < 110 { yellow += 1 }
            }
        }
        return (bright, yellow)
    }

    @Test func burnedInCaptionsShowWhenTheyAreSpoken() async throws {
        var (state, urls) = try await project()
        state.settings = ProjectSettings(name: "C", width: 640, height: 360, frameRate: 30)
        let during = try count(try await ExportProbe.previewFrame(state, urls: urls, at: 1.0))
        let between = try count(try await ExportProbe.previewFrame(state, urls: urls, at: 1.75))
        #expect(during.bright > 40, "text on screen: \(during)")
        #expect(between.bright == 0, "nothing between captions: \(between)")
        // Not burned in, or the track hidden: nothing drawn.
        var off = state
        off.tracks[off.trackIndices(of: .caption)[0]].captions?.isBurnedIn = false
        #expect(try count(try await ExportProbe.previewFrame(off, urls: urls, at: 1.0)).bright == 0)
        var hidden = state
        hidden.tracks[hidden.trackIndices(of: .caption)[0]].isMuted = true
        #expect(try count(try await ExportProbe.previewFrame(hidden, urls: urls, at: 1.0)).bright == 0)
    }

    @Test func karaokeHighlightsTheSpokenWord() async throws {
        var (state, urls) = try await project(CaptionPreset.karaoke.style)
        state.settings = ProjectSettings(name: "C", width: 640, height: 360, frameRate: 30)
        let first = try count(try await ExportProbe.previewFrame(state, urls: urls, at: 2.2))   // "GENERAL" highlighted
        let second = try count(try await ExportProbe.previewFrame(state, urls: urls, at: 2.7))  // "KENOBI" highlighted
        #expect(first.yellow > 10 && second.yellow > 10, "\(first) \(second)")
        #expect(first.bright > 10 && second.bright > 10, "the other word stays white")
        // Without highlighting, no yellow at all.
        var plain = state
        plain.tracks[plain.trackIndices(of: .caption)[0]].captions?.style.highlightsWord = false
        #expect(try count(try await ExportProbe.previewFrame(plain, urls: urls, at: 2.2)).yellow == 0)
    }

    @Test func captionsScaleWithTheFramesShorterSide() throws {
        let words = [CaptionWord(wordID: UUID(), mediaID: UUID(), text: "same", start: .zero, end: Time(seconds: 1), startsCaption: false)]
        let overlay = CaptionOverlay(style: CaptionStyle(), captions: [Caption(words: words, start: .zero, end: Time(seconds: 1))])
        let wide = try #require(CaptionRenderer.image(for: overlay, at: Time(seconds: 0.5), renderSize: CGSize(width: 1920, height: 1080)))
        let tall = try #require(CaptionRenderer.image(for: overlay, at: Time(seconds: 0.5), renderSize: CGSize(width: 1080, height: 1920)))
        #expect(wide.extent.size == tall.extent.size, "vertical exports keep the caption size")
        let half = try #require(CaptionRenderer.image(for: overlay, at: Time(seconds: 0.5), renderSize: CGSize(width: 960, height: 540)))
        #expect(abs(half.extent.height * 2 - wide.extent.height) <= 6, "half size (a fixed 2 px margin aside)")
        // Centered, at the style's height.
        #expect(abs(wide.extent.midX - 960) < 2 && abs(wide.extent.midY - 1080 * (1 - 0.82)) < 2)
    }

    @Test func subtitlesAreValidSubRip() {
        let w = { (t: String, s: Double, e: Double) in
            CaptionWord(wordID: UUID(), mediaID: UUID(), text: t, start: Time(seconds: s), end: Time(seconds: e), startsCaption: false)
        }
        let captions = [Caption(words: [w("Hello", 1, 1.5), w("there.", 1.5, 2)], start: Time(seconds: 1), end: Time(seconds: 2)),
                        Caption(words: [w("Bye", 3661.25, 3662)], start: Time(seconds: 3661.25), end: Time(seconds: 3662.5))]
        #expect(SubtitleFile.srt(captions) == "1\n00:00:01,000 --> 00:00:02,000\nHello there.\n\n2\n01:01:01,250 --> 01:01:02,500\nBye\n")
        // Timed from an export range's start, clipped to it.
        let ranged = SubtitleFile.srt(captions, range: TimeRange(start: Time(seconds: 1.5), end: Time(seconds: 10)), uppercase: true)
        #expect(ranged == "1\n00:00:00,000 --> 00:00:00,500\nHELLO THERE.\n")
    }

    @Test func exportsBurnInMatchThePreviewAndSaveSubtitles() async throws {
        var (state, urls) = try await project()
        state.settings = ProjectSettings(name: "C", width: 640, height: 360, frameRate: 30)
        var settings = ExportPreset.proRes.applied(to: ExportSettings())
        settings.frameRate = 30
        settings.savesSubtitles = true
        let folder = ExportProbe.folder()
        func export(_ settings: ExportSettings, name: String) async throws -> URL {
            let range = ExportSnapshot.snapped(TimeRange(start: .zero, end: state.duration), fps: 30)
            let url = folder.appendingPathComponent("\(name).mov")
            _ = try await ExportRunner.run(ExportSnapshot(state: state, urls: urls, range: range, settings: settings), to: url,
                                           cancellation: ExportCancellation(), phase: { _ in }) { _, _ in }
            return url
        }
        let movie = try await export(settings, name: "captions")
        let exported = try await ExportProbe.frame(movie, at: 1.0)
        let preview = try await ExportProbe.previewFrame(state, urls: urls, at: 1.0)
        #expect(try ExportProbe.difference(exported, preview) < 4, "the export draws what the preview does")
        #expect(try count(exported).bright > 40)
        let srt = try String(contentsOf: folder.appendingPathComponent("captions.srt"), encoding: .utf8)
        #expect(srt.contains("00:00:00,500 --> ") && srt.contains("HELLO THERE."), "\(srt)")

        settings.burnsInCaptions = false
        settings.savesSubtitles = false
        let clean = try await export(settings, name: "clean")
        #expect(try count(try await ExportProbe.frame(clean, at: 1.0)).bright == 0, "not burned in")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("clean.srt").path))
    }

    @Test func thePlaygroundGetsTranscriptsAndCaptions() async throws {
        var (state, _) = try await project(CaptionPreset.lowerThird.style)
        state.id = UUID()
        let editor = EditorController(store: ProjectStore(state: state))
        editor.playgroundFolder = FileManager.default.temporaryDirectory.appendingPathComponent("pg-\(UUID().uuidString)")
        let clip = AudioTestKit.firstClip(state)
        editor.sendToPlayground([clip.id])
        let sandbox = try #require(editor.playground?.editor)
        #expect(sandbox.state.transcripts[clip.mediaID] == state.transcripts[clip.mediaID])
        let index = try #require(sandbox.state.trackIndices(of: .caption).first)
        #expect(sandbox.state.tracks[index].captions?.style == CaptionPreset.lowerThird.style)
        #expect(sandbox.state.captions(onTrack: index).map(\.text) == ["hello there.", "general kenobi"])
    }
}


@MainActor struct CaptionPolishTests {
    private func words(_ texts: [String], from start: Double = 1, step: Double = 0.3) -> [TranscriptWord] {
        texts.enumerated().map { k, t in TranscriptWord(text: t, start: start + Double(k) * step, end: start + Double(k) * step + 0.25) }
    }

    private func state(_ words: [TranscriptWord], clips: Int = 1, length: Double = 20) -> ProjectState {
        var state = ProjectState()
        let media = MediaItem(id: UUID(), name: "talk", path: "/talk.wav", duration: Time(seconds: length), width: 0, height: 0,
                              frameRate: 0, hasAudio: true)
        state.media = [media]
        state.transcripts[media.id] = Transcript(mediaID: media.id, locale: "en_US", words: words)
        let piece = length / Double(clips)
        state.tracks[state.trackIndices(of: .audio)[0]].clips = (0..<clips).map { k in
            Clip(id: UUID(), mediaID: media.id, name: "talk", start: Time(seconds: Double(k) * piece), duration: Time(seconds: piece),
                 sourceStart: Time(seconds: Double(k) * piece))
        }
        state.appendCaptionTrack()
        return state
    }

    @Test func longSentencesSplitEvenly() {
        let s = state(words(["and", "I", "have", "no", "idea", "what", "I'm", "doing."]))
        let index = s.trackIndices(of: .caption)[0]
        #expect(s.captions(onTrack: index).map(\.text) == ["and I have no", "idea what I'm doing."], "4 + 4, not 6 + 2")
        // Thirteen words: 5 + 4 + 4 (never more than six).
        let long = state(words((1...13).map { "w\($0)" }, step: 0.2))
        let groups = long.captions(onTrack: index).map(\.words.count)
        #expect(groups.reduce(0, +) == 13 && groups.allSatisfy { $0 <= 6 } && groups.max()! - groups.min()! <= 1, "\(groups)")
    }

    @Test func transcribingAgainAsksBeforeReplacingEdits() throws {
        var s = state(words(["hello", "there"]))
        let mediaID = try #require(s.media.first?.id)
        s.media[0].path = "/tmp/missing-\(UUID()).wav"
        let editor = EditorController(store: ProjectStore(state: s))
        // Untouched: no question (it just starts).
        #expect(editor.editedTranscripts(among: nil).isEmpty)
        // After a correction it asks first.
        editor.editWord(editor.currentCaptions[0].words[0], to: "Hello")
        #expect(editor.state.transcripts[mediaID]?.isEdited == true)
        editor.requestTranscription()
        #expect(editor.pendingTranscription != nil && !editor.isTranscribing, "waits for the answer")
        #expect(editor.editedTranscripts(among: [UUID()]).isEmpty, "other media isn't affected")
        #expect(try ProjectState.decode(editor.state.encoded()) == editor.state)
    }

    @Test func anHourOfSpeechStaysQuick() throws {
        // 9,000 words over an hour, cut into 300 clips.
        let text = (0..<9_000).map { "w\($0)" + ($0 % 12 == 11 ? "." : "") }
        let s = state(words(text, from: 0, step: 0.4), clips: 300, length: 3_600)
        let index = s.trackIndices(of: .caption)[0]
        let clock = ContinuousClock()
        let start = clock.now
        let captions = s.captions(onTrack: index)
        let elapsed = clock.now - start
        #expect(captions.flatMap(\.words).count == 9_000)
        #expect(elapsed < .milliseconds(500), "\(elapsed) (debug build)")

        // Redraws during playback reuse them until the project changes.
        let editor = EditorController(store: ProjectStore(state: s))
        _ = editor.currentCaptions
        let again = clock.now
        for _ in 0..<60 { _ = editor.currentCaptions }
        #expect(clock.now - again < .milliseconds(20), "a second of playback redraws")
        editor.editWord(editor.currentCaptions[0].words[0], to: "first")
        #expect(editor.currentCaptions[0].words[0].text == "first", "a change shows at once")
    }
}
