import Foundation

extension EditorController {
    var isTranscribing: Bool { transcriptionTask != nil }

    /// Transcribes media used on the audio tracks (all of it, or `mediaIDs`), one item at a
    /// time, on this Mac. Each finished transcript is added as its own undo step;
    /// re-transcribing replaces the old one. Cancel stops after the current item.
    func transcribe(_ mediaIDs: Set<UUID>? = nil, locale preferred: Locale? = nil) {
        guard transcriptionTask == nil else { return }
        let items = state.transcribableMedia.filter { mediaIDs?.contains($0.id) ?? true }
        guard !items.isEmpty else {
            transcriptionMessage = "There's no sound on the audio tracks to transcribe."
            return
        }
        transcriptionMessage = nil
        transcriptionProgress = Dictionary(uniqueKeysWithValues: items.map { ($0.id, 0) })
        transcriptionTask = Task { [weak self] in
            guard let locale = await Transcriber.locale(preferring: preferred ?? .current) else {
                self?.finishTranscription(message: "Speech recognition isn't available on this Mac.")
                return
            }
            for media in items {
                guard !Task.isCancelled else { break }
                let id = media.id
                guard let prepared = await AudioSourceCache.shared.preparedAudio(media) else {
                    self?.transcriptionProgress[id] = nil
                    continue
                }
                let report: @Sendable (Double) -> Void = { [weak self] value in
                    Task { @MainActor in self?.transcriptionProgress[id] = value }
                }
                do {
                    let words = try await Task.detached(priority: .userInitiated) {
                        try await Transcriber.transcribe(prepared.url, identity: media.resolveURL(), mediaID: id, locale: locale,
                                                         progress: report)
                    }.value
                    guard !Task.isCancelled else { break }
                    self?.store.edit("Transcribe \(media.name)") { state in
                        state.transcripts[id] = Transcript(mediaID: id, locale: locale.identifier, words: words)
                    }
                    self?.transcriptionProgress[id] = nil
                } catch {
                    self?.finishTranscription(message: "Couldn't transcribe \(media.name): \(error.localizedDescription)")
                    return
                }
            }
            self?.finishTranscription(message: nil)
        }
    }

    func cancelTranscription() {
        transcriptionTask?.cancel()
        finishTranscription(message: nil)
    }

    private func finishTranscription(message: String?) {
        transcriptionTask = nil
        transcriptionProgress = [:]
        if let message { transcriptionMessage = message }
    }

    /// Waits for a running transcription (tests).
    func waitForTranscription() async {
        while transcriptionTask != nil { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

// MARK: Caption tracks

extension EditorController {
    var captionTrackIndices: [Int] { state.trackIndices(of: .caption) }

    /// Adds a caption track captioning every audio track; returns its ID.
    @discardableResult
    func addCaptionTrack() -> UUID? {
        var id: UUID?
        store.edit("Add Caption Track") { state in
            let index = state.appendCaptionTrack()
            id = state.tracks[index].id
        }
        return id
    }

    /// Changes a caption track's settings (inside a begin/end pair it's one live change).
    func adjustCaptions(_ trackID: UUID, actionName: String, _ body: @escaping (inout CaptionSettings) -> Void) {
        guard let index = state.tracks.firstIndex(where: { $0.id == trackID }), state.tracks[index].captions != nil,
              !state.tracks[index].isLocked else { return }
        let apply: (inout ProjectState) -> Void = { state in
            guard let i = state.tracks.firstIndex(where: { $0.id == trackID }), var settings = state.tracks[i].captions else { return }
            body(&settings)
            settings.maxWords = settings.maxWords.clamped(to: CaptionSettings.wordRange)
            settings.maxDuration = settings.maxDuration.clamped(to: CaptionSettings.durationRange)
            settings.pauseSplit = settings.pauseSplit.clamped(to: CaptionSettings.pauseRange)
            state.tracks[i].captions = settings
        }
        if store.isLiveEditing { store.liveEdit(apply) } else { store.edit(actionName, apply) }
    }
}

// MARK: Transcript editing

extension EditorController {
    /// The caption track the Captions tab shows (the chosen one, or the first).
    var captionTrackID: UUID? {
        let ids = captionTrackIndices.map { state.tracks[$0].id }
        if let chosen = selectedCaptionTrackID, ids.contains(chosen) { return chosen }
        return ids.first
    }

    var captionTrackIndex: Int? {
        captionTrackID.flatMap { id in state.tracks.firstIndex { $0.id == id } }
    }

    /// The captions the Captions tab shows.
    var currentCaptions: [Caption] {
        captionTrackIndex.map { state.captions(onTrack: $0) } ?? []
    }

    /// Transcribes everything on the audio tracks and makes sure there's a caption track
    /// to show the result (the Captions tab's Transcribe button).
    func transcribeForCaptions(locale: Locale? = nil) {
        if captionTrackIndices.isEmpty { selectedCaptionTrackID = addCaptionTrack() }
        transcribe(locale: locale)
    }

    private func updateWord(_ word: CaptionWord, actionName: String, coalesce: Bool = false,
                            _ body: @escaping (inout TranscriptWord) -> Void) {
        store.edit(actionName, coalescingKey: coalesce ? "word/\(word.wordID)" : nil) { state in
            guard let index = state.transcripts[word.mediaID]?.words.firstIndex(where: { $0.id == word.wordID }) else { return }
            body(&state.transcripts[word.mediaID]!.words[index])
        }
    }

    /// Changes a word's text (empty text hides the word).
    func editWord(_ word: CaptionWord, to text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned != word.text else { return }
        if cleaned.isEmpty {
            setWordHidden(word, true)
            return
        }
        updateWord(word, actionName: "Edit Word") { $0.text = cleaned }
    }

    /// Hides a word from the captions (or shows it again). Hidden words stay in the transcript.
    func setWordHidden(_ word: CaptionWord, _ hidden: Bool) {
        updateWord(word, actionName: hidden ? "Hide Word" : "Show Word") { $0.isHidden = hidden }
    }

    /// Hides or shows a word by its place in a transcript (the transcript list shows hidden words too).
    func setWordHidden(mediaID: UUID, wordID: UUID, _ hidden: Bool) {
        store.edit(hidden ? "Hide Word" : "Show Word") { state in
            guard let index = state.transcripts[mediaID]?.words.firstIndex(where: { $0.id == wordID }) else { return }
            state.transcripts[mediaID]!.words[index].isHidden = hidden
        }
    }

    /// Starts a new caption at this word.
    func splitCaption(at word: CaptionWord) {
        updateWord(word, actionName: "Split Caption") { w in
            w.startsCaption = true
            w.keepsWithPrevious = false
        }
    }

    /// Joins a caption to the one before it: all its words stay with the previous caption,
    /// whatever the grouping rules (pauses, length, word count) would do.
    func mergeWithPrevious(_ caption: Caption) {
        guard !caption.words.isEmpty else { return }
        store.edit("Merge Captions") { state in
            for word in caption.words {
                guard let i = state.transcripts[word.mediaID]?.words.firstIndex(where: { $0.id == word.wordID }) else { continue }
                state.transcripts[word.mediaID]!.words[i].startsCaption = false
                state.transcripts[word.mediaID]!.words[i].keepsWithPrevious = true
            }
        }
    }

    /// Replaces a caption's words with new text. The same number of words keeps every
    /// word's timing; a different number spreads the new words evenly over the same span
    /// (of the same recording), so the caption keeps its place.
    func editCaption(_ caption: Caption, to text: String) {
        let newWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard newWords != caption.words.map(\.text) else { return }
        let ids = caption.words.map(\.wordID)
        store.edit("Edit Caption") { state in
            if newWords.count == caption.words.count {
                for (word, newText) in zip(caption.words, newWords) {
                    guard let i = state.transcripts[word.mediaID]?.words.firstIndex(where: { $0.id == word.wordID }) else { continue }
                    state.transcripts[word.mediaID]!.words[i].text = newText
                }
                return
            }
            // Different word count: one recording's span, spread evenly.
            guard let mediaID = caption.words.first?.mediaID, var transcript = state.transcripts[mediaID] else { return }
            let mine = transcript.words.enumerated().filter { ids.contains($0.element.id) }
            guard let firstIndex = mine.first?.offset, let lastIndex = mine.last?.offset else { return }
            let start = transcript.words[firstIndex].start, end = transcript.words[lastIndex].end
            let leading = transcript.words[firstIndex]
            transcript.words.removeAll { ids.contains($0.id) }
            if !newWords.isEmpty {
                let step = (end - start) / Double(newWords.count)
                let replacements = newWords.enumerated().map { k, newText -> TranscriptWord in
                    var w = TranscriptWord(text: newText, start: start + step * Double(k), end: start + step * Double(k + 1))
                    if k == 0 {
                        w.startsCaption = leading.startsCaption
                        w.keepsWithPrevious = leading.keepsWithPrevious
                    }
                    return w
                }
                let at = transcript.words.firstIndex { $0.start >= start } ?? transcript.words.count
                transcript.words.insert(contentsOf: replacements, at: at)
            }
            state.transcripts[mediaID] = transcript
        }
    }

    /// The caption and word under the playhead (for highlighting and following playback).
    func captionPosition(in captions: [Caption], at time: Time) -> (caption: Caption, word: CaptionWord?)? {
        guard let caption = captions.last(where: { $0.start <= time }), time < caption.end else { return nil }
        return (caption, caption.word(at: time))
    }
}
