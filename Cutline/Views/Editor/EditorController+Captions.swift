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
