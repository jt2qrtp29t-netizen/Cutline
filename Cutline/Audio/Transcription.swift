import AVFoundation
import Foundation
import Speech

/// On-device speech recognition (Apple's Speech framework): a media item's sound to
/// words with their times. Nothing leaves the Mac. Results are kept on disk by the
/// file's identity and language, so a recording is never transcribed twice.
nonisolated enum Transcriber {
    enum Failure: LocalizedError {
        case unsupportedLanguage(String)
        case languageNotInstalled(String)
        case noAudio

        var errorDescription: String? {
            switch self {
            case let .unsupportedLanguage(name): "Speech recognition doesn't support \(name)."
            case let .languageNotInstalled(name): "The \(name) speech model isn't installed yet."
            case .noAudio: "This media has no sound to transcribe."
            }
        }
    }

    /// The language to use: `preferred` if supported, else the closest supported one.
    static func locale(preferring preferred: Locale = .current) async -> Locale? {
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) { return match }
        return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
    }

    static func module(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// Whether the language's model is on this Mac (otherwise `installLanguage` gets it from Apple).
    static func isInstalled(_ locale: Locale) async -> Bool {
        await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
    }

    /// Downloads and installs the language's speech model (through macOS), reporting progress.
    static func installLanguage(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module(for: locale)]) else { return }
        let watcher = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel() }
        try await request.downloadAndInstall()
        progress(1)
    }

    /// The cached words for a file, if it was transcribed before in this language.
    /// `identity` is the original media file (its modification time and size name the cache).
    static func cached(_ identity: URL, mediaID: UUID, locale: Locale) -> [TranscriptWord]? {
        guard let file = cacheFile(identity, mediaID: mediaID, locale: locale),
              let data = try? Data(contentsOf: file),
              let words = try? JSONDecoder().decode([TranscriptWord].self, from: data) else { return nil }
        DiskCache.touch(file)
        return words.map { var w = $0; w.id = UUID(); return w }
    }

    private static func cacheFile(_ url: URL, mediaID: UUID, locale: Locale) -> URL? {
        guard let stamp = DiskCache.stamp(for: url) else { return nil }
        return DiskCache.transcripts.folder.appendingPathComponent("\(mediaID.uuidString)-\(stamp)-\(locale.identifier).json")
    }

    /// Transcribes the sound in `url` (an audio file, e.g. the media's prepared sound),
    /// reporting progress (0…1) as recognition moves through it. Words come back in
    /// source seconds. `identity` (the original file) keys the disk cache.
    static func transcribe(_ url: URL, identity: URL? = nil, mediaID: UUID, locale: Locale,
                           progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [TranscriptWord] {
        let identity = identity ?? url
        if let cached = cached(identity, mediaID: mediaID, locale: locale) { return cached }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw Failure.noAudio }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let transcriber = module(for: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                words += Self.words(in: result.text)
                progress(min(1, result.range.end.seconds / max(duration, 0.001)))
            }
            return words
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            await analyzer.cancelAndFinishNow()
            if !(await isInstalled(locale)) { throw Failure.languageNotInstalled(locale.localizedName) }
            throw error
        }
        let words = try await collector.value.sorted { $0.start < $1.start }
        progress(1)
        if let cacheFile = cacheFile(identity, mediaID: mediaID, locale: locale), let data = try? JSONEncoder().encode(words) {
            try? FileManager.default.createDirectory(at: DiskCache.transcripts.folder, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return words
    }

    /// One word per timed run of the recognized text (punctuation stays with its word).
    static func words(in text: AttributedString) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            guard let range = run.audioTimeRange else {
                // Untimed text (rare): attach it to the previous word.
                if !words.isEmpty { words[words.count - 1].text += piece.first?.isPunctuation == true ? piece : " " + piece }
                continue
            }
            let confidence = run.transcriptionConfidence
            // A run can hold several words when timing is shared: split them evenly.
            let parts = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            let step = range.duration.seconds / Double(max(parts.count, 1))
            for (k, part) in parts.enumerated() {
                let start = range.start.seconds + step * Double(k)
                words.append(TranscriptWord(text: part, start: start, end: start + step, confidence: confidence))
            }
        }
        return words
    }
}

nonisolated extension Locale {
    /// "English (United States)".
    var localizedName: String { Locale.current.localizedString(forIdentifier: identifier) ?? identifier }
}
