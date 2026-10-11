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
