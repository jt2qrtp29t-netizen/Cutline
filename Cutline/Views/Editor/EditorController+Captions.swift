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
