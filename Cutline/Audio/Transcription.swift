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
        case notAllowed
        case noAudio

        var errorDescription: String? {
            switch self {
            case let .unsupportedLanguage(name): "Speech recognition doesn't support \(name)."
            case let .languageNotInstalled(name):
                "The \(name) speech model isn't on this Mac yet. Turn on Dictation for \(name) in System Settings → Keyboard, wait for it to download, then try again."
            case .notAllowed: "Cutline isn't allowed to use speech recognition. Allow it in System Settings → Privacy & Security → Speech Recognition."
            case .noAudio: "This media has no sound to transcribe."
            }
        }
    }

    /// The language to use: `preferred` if this Mac can recognize it on-device, else US English.
    static func locale(preferring preferred: Locale = .current) async -> Locale? {
        // The framework spells them "en-US"; the locale keeps Cutline's own spelling ("en_US"),
        // which names cached transcripts.
        let supported = SFSpeechRecognizer.supportedLocales()
        func isSupported(_ locale: Locale) -> Bool {
            supported.contains { $0.language.languageCode == locale.language.languageCode && $0.region == locale.region }
        }
        if isSupported(preferred) { return preferred }
        let english = Locale(identifier: "en_US")
        return isSupported(english) ? english : nil
    }

    /// Asks once for permission to use speech recognition (macOS remembers the answer).
    static func authorize() async throws {
        // Asked only when there's no answer yet: the reply comes back through the main
        // queue, which can keep it waiting for a long time while the app is busy.
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return }
        let status = await withCheckedContinuation { (done: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0) }
        }
        guard status == .authorized else { throw Failure.notAllowed }
    }

    private static let recognitionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "app.cutline.speech"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// A recognizer that works on this Mac only (nothing is sent to Apple).
    static func recognizer(for locale: Locale) throws -> SFSpeechRecognizer {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw Failure.unsupportedLanguage(locale.localizedName) }
        guard recognizer.supportsOnDeviceRecognition else { throw Failure.languageNotInstalled(locale.localizedName) }
        // Results arrive on this queue (the main queue otherwise, which can be busy for a long time).
        recognizer.queue = recognitionQueue
        return recognizer
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
        try await authorize()
        let recognizer = try recognizer(for: locale)
        let format = file.processingFormat
        let rate = format.sampleRate
        var words: [TranscriptWord] = []
        // Recognized a piece at a time (about a minute each), split where it's quietest
        // so a word is never cut in two.
        var position: AVAudioFramePosition = 0
        while position < file.length {
            try Task.checkCancellation()
            let piece = try Self.readPiece(of: file, from: position)
            let offset = Double(position) / rate
            words += try await Self.recognize(piece, with: recognizer).map {
                TranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset, confidence: $0.confidence)
            }
            position += AVAudioFramePosition(piece.frameLength)
            progress(min(1, Double(position) / Double(file.length)))
        }
        words.sort { $0.start < $1.start }
        progress(1)
        if let cacheFile = cacheFile(identity, mediaID: mediaID, locale: locale), let data = try? JSONEncoder().encode(words) {
            try? FileManager.default.createDirectory(at: DiskCache.transcripts.folder, withIntermediateDirectories: true)
            try? data.write(to: cacheFile, options: .atomic)
        }
        return words
    }

    /// Pieces aim for this long, ending at the quietest moment in their last stretch.
    static let pieceSeconds = 55.0
    static let searchSeconds = 12.0

    /// Reads the next piece from `position`: up to `pieceSeconds`, cut at the quietest
    /// 50 ms in its last `searchSeconds` (or the end of the file).
    static func readPiece(of file: AVAudioFile, from position: AVAudioFramePosition) throws -> AVAudioPCMBuffer {
        let rate = file.processingFormat.sampleRate
        let capacity = AVAudioFrameCount(min(Double(file.length - position), pieceSeconds * rate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { throw Failure.noAudio }
        file.framePosition = position
        try file.read(into: buffer, frameCount: capacity)
        guard position + AVAudioFramePosition(buffer.frameLength) < file.length,
              let samples = buffer.floatChannelData?[0] else { return buffer }
        let window = max(1, Int(0.05 * rate))
        let length = Int(buffer.frameLength)
        var quietest = length, lowest = Float.infinity
        var start = max(0, length - Int(searchSeconds * rate))
        while start + window <= length {
            var energy: Float = 0
            for i in start..<(start + window) { energy += samples[i] * samples[i] }
            if energy < lowest { lowest = energy; quietest = start + window / 2 }
            start += window
        }
        buffer.frameLength = AVAudioFrameCount(quietest)
        return buffer
    }

    /// The words in one piece of sound, timed from its start.
    static func recognize(_ piece: AVAudioPCMBuffer, with recognizer: SFSpeechRecognizer) async throws -> [TranscriptWord] {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.append(piece)
        request.endAudio()
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<[TranscriptWord], Error>) in
                let once = Once()
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        once.run { done.resume(returning: Self.words(in: result.bestTranscription)) }
                    } else if let error {
                        // "No speech detected" just means a quiet piece.
                        let nsError = error as NSError
                        if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 {
                            once.run { done.resume(returning: []) }
                        } else {
                            once.run { done.resume(throwing: error) }
                        }
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// One word per recognized segment (punctuation stays with its word).
    static func words(in transcription: SFTranscription) -> [TranscriptWord] {
        transcription.segments.compactMap { segment in
            let text = segment.substring.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptWord(text: text, start: segment.timestamp, end: segment.timestamp + segment.duration,
                                  confidence: Double(segment.confidence))
        }
    }

    private final class TaskBox: @unchecked Sendable {
        var task: SFSpeechRecognitionTask?
    }

    /// Runs its closure the first time only (the recognizer can call back more than once).
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            body()
        }
    }
}

nonisolated extension Locale {
    /// "English (United States)".
    var localizedName: String { Locale.current.localizedString(forIdentifier: identifier) ?? identifier }
}
